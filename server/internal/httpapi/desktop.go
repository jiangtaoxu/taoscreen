package httpapi

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// 桌面信令只中转同账户双方的协商消息。画面和输入使用 WebRTC，不进入此接口。
type desktopMessage struct {
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"`
	To      string          `json:"to,omitempty"`
	From    string          `json:"from,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
}
type desktopSession struct {
	Viewer        string `json:"viewer"`
	Host          string `json:"host"`
	Accepted      bool   `json:"accepted"`
	ViewerSession string `json:"viewer_session,omitempty"`
	HostSession   string `json:"host_session,omitempty"`
}
type desktopICE struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

func desktopURLs(raw string) []string {
	out := []string{}
	for _, value := range strings.Split(raw, ",") {
		if value = strings.TrimSpace(value); value != "" {
			out = append(out, value)
		}
	}
	return out
}
func turnCredentials(secret, device string, expires time.Time) (string, string) {
	username := fmt.Sprintf("%d:%s", expires.Unix(), device)
	mac := hmac.New(sha1.New, []byte(secret)) // coturn REST credential scheme
	mac.Write([]byte(username))
	return username, base64.StdEncoding.EncodeToString(mac.Sum(nil))
}
func (s *Server) desktopConfig(w http.ResponseWriter, r *http.Request) error {
	servers := []desktopICE{}
	if urls := desktopURLs(s.Config.DesktopSTUNURLs); len(urls) > 0 {
		servers = append(servers, desktopICE{URLs: urls})
	}
	expires := time.Now().Add(2 * time.Hour)
	if urls := desktopURLs(s.Config.DesktopTURNURLs); len(urls) > 0 {
		username, credential := turnCredentials(s.Config.DesktopTURNSecret, owner(r).Device, expires)
		servers = append(servers, desktopICE{URLs: urls, Username: username, Credential: credential})
	}
	return jsonReply(w, 200, map[string]any{"ice_servers": servers, "expires_at": expires, "relay_available": s.Config.DesktopTURNURLs != ""})
}
func desktopOnline(user, device string) string {
	return peerOnline("desktop", user, device)
}
func desktopChannel(user, device string) string {
	return peerChannel("desktop", user, device)
}
func peerOnline(purpose, user, device string) string {
	return "taoscreen:" + purpose + ":online:" + user + ":" + device
}
func peerChannel(purpose, user, device string) string {
	return "taoscreen:" + purpose + ":signal:" + user + ":" + device
}
func peerSessionKey(purpose, user, id string) string {
	return "taoscreen:" + purpose + ":session:" + user + ":" + id
}
func (s *Server) desktopPeers(w http.ResponseWriter, r *http.Request) error {
	return s.peersForPurpose(w, r, "desktop")
}
func (s *Server) portsPeers(w http.ResponseWriter, r *http.Request) error {
	return s.peersForPurpose(w, r, "ports")
}
func (s *Server) peersForPurpose(w http.ResponseWriter, r *http.Request, purpose string) error {
	me := owner(r)
	rows, err := s.DB.Query(r.Context(), `SELECT d.id::text,d.name FROM devices d WHERE d.user_id=$1
        AND EXISTS(SELECT 1 FROM sessions s WHERE s.user_id=d.user_id AND s.device_id=d.id AND s.revoked_at IS NULL AND s.expires_at>now()) ORDER BY d.name`, me.User)
	if err != nil {
		return err
	}
	defer rows.Close()
	peers := []map[string]any{}
	for rows.Next() {
		var id, name string
		if err = rows.Scan(&id, &name); err != nil {
			return err
		}
		if id == me.Device {
			continue
		}
		online, e := s.Redis.Exists(r.Context(), peerOnline(purpose, me.User, id)).Result()
		if e != nil {
			return e
		}
		if online > 0 {
			peers = append(peers, map[string]any{"id": id, "name": name})
		}
	}
	if err = rows.Err(); err != nil {
		return err
	}
	return jsonReply(w, 200, map[string]any{"peers": peers})
}
func validateDesktopMessage(m desktopMessage, device string, session *desktopSession) error {
	if _, e := uuid.Parse(m.ID); e != nil {
		return invalid("会话 ID 无效")
	}
	if _, e := uuid.Parse(m.To); e != nil || m.To == device {
		return invalid("目标设备无效")
	}
	if len(m.Payload) > 60*1024 {
		return invalid("信令过大")
	}
	if m.Type == "invite" {
		return nil
	}
	if session == nil || !((device == session.Viewer && m.To == session.Host) || (device == session.Host && m.To == session.Viewer)) {
		return problem(403, "forbidden", "无权访问此连接会话")
	}
	switch m.Type {
	case "accept", "reject":
		if device != session.Host || session.Accepted {
			return invalid("会话不在等待接受状态")
		}
	case "offer":
		if device != session.Viewer || !session.Accepted {
			return invalid("会话尚未授权")
		}
	case "answer":
		if device != session.Host || !session.Accepted {
			return invalid("会话尚未授权")
		}
	case "candidate", "resume", "keepalive":
		if !session.Accepted {
			return invalid("会话尚未授权")
		}
	case "end":
	default:
		return invalid("未知信令类型")
	}
	return nil
}
func (s *Server) routeDesktop(ctx context.Context, me identity, m desktopMessage) error {
	return s.routePeerSession(ctx, me, m, "desktop")
}
func (s *Server) routePorts(ctx context.Context, me identity, m desktopMessage) error {
	return s.routePeerSession(ctx, me, m, "ports")
}
func (s *Server) routePeerSession(ctx context.Context, me identity, m desktopMessage, purpose string) error {
	if e := s.limitPeerSignals(ctx, me, purpose); e != nil {
		return e
	}
	// Swift UUID JSON uses uppercase; normalize before keys, ownership and routing.
	id, err := uuid.Parse(m.ID)
	if err != nil {
		return invalid("会话 ID 无效")
	}
	target, err := uuid.Parse(m.To)
	if err != nil {
		return invalid("目标设备无效")
	}
	m.ID, m.To = id.String(), target.String()
	if m.To == me.Device || len(m.Payload) > 60*1024 {
		return invalid("目标设备或信令无效")
	}
	key := peerSessionKey(purpose, me.User, m.ID)
	if m.Type == "invite" {
		exists, e := s.Redis.Exists(ctx, peerOnline(purpose, me.User, m.To)).Result()
		if e != nil {
			return e
		}
		if exists == 0 {
			return problem(409, "offline", "对方未开启此用途的在线服务")
		}
		raw, _ := json.Marshal(desktopSession{Viewer: me.Device, Host: m.To, ViewerSession: me.Session})
		ok, e := s.Redis.SetNX(ctx, key, raw, 60*time.Second).Result()
		if e != nil {
			return e
		}
		if !ok {
			return invalid("会话已存在")
		}
	} else {
		raw, e := s.Redis.Get(ctx, key).Result()
		if e != nil {
			if !errors.Is(e, redis.Nil) {
				return e
			}
			return problem(409, "expired", "连接会话已结束或过期")
		}
		var session desktopSession
		if json.Unmarshal([]byte(raw), &session) != nil {
			return invalid("会话无效")
		}
		if e = validateDesktopMessage(m, me.Device, &session); e != nil {
			return e
		}
		if (me.Device == session.Viewer && session.ViewerSession != "" && session.ViewerSession != me.Session) ||
			(me.Device == session.Host && session.HostSession != "" && session.HostSession != me.Session) {
			return problem(403, "session_changed", "连接会话的登录身份已改变，请重新请求授权")
		}
		if m.Type == "resume" {
			return s.resumePeerSession(ctx, me, m, key, raw, session, purpose)
		}
		if m.Type == "keepalive" {
			if err := s.desktopLoginsActive(ctx, session); err != nil {
				return err
			}
			// 仅续期仍存在的原授权。120 秒是失联记录的回收期限，不限制会话总时长。
			ok, err := s.Redis.Eval(ctx, `if redis.call('get',KEYS[1]) == ARGV[1] then return redis.call('expire',KEYS[1],120) end; return 0`, []string{key}, raw).Int()
			if err != nil {
				return err
			}
			if ok != 1 {
				return problem(409, "expired", "连接会话已结束或过期")
			}
			return nil
		}
		if m.Type == "accept" {
			session.Accepted = true
			session.HostSession = me.Session
			updated, _ := json.Marshal(session)
			// 兼容不发送 keepalive 的旧客户端；新版连接建立后改为持续续期。
			ok, err := s.Redis.Eval(ctx, `if redis.call('get',KEYS[1]) == ARGV[1] then redis.call('set',KEYS[1],ARGV[2],'EX',7200); return 1 end; return 0`, []string{key}, raw, updated).Int()
			if err != nil {
				return err
			}
			if ok != 1 {
				return invalid("会话状态已改变")
			}
		}
		if m.Type == "end" || m.Type == "reject" {
			if e = s.Redis.Del(ctx, key).Err(); e != nil {
				return e
			}
		}
	}
	m.From = me.Device // 绝不信任客户端填入的发送者。
	raw, _ := json.Marshal(m)
	return s.Redis.Publish(ctx, peerChannel(purpose, me.User, m.To), raw).Err()
}

func (s *Server) desktopLoginsActive(ctx context.Context, session desktopSession) error {
	if session.ViewerSession == "" || session.HostSession == "" {
		return problem(409, "resume_denied", "此连接会话不支持恢复或续期，请重新连接")
	}
	for _, login := range []string{session.ViewerSession, session.HostSession} {
		active, err := s.sessionActive(ctx, login)
		if err != nil {
			return err
		}
		if !active {
			return problem(403, "session_revoked", "连接会话的登录授权已失效")
		}
	}
	return nil
}

// 恢复只确认原授权，不能创建会话或换用同设备的另一登录。
func (s *Server) resumePeerSession(ctx context.Context, me identity, m desktopMessage, key, raw string, session desktopSession, purpose string) error {
	var payload struct {
		Token string `json:"resume_token"`
	}
	if json.Unmarshal(m.Payload, &payload) != nil {
		return invalid("恢复参数无效")
	}
	token, err := uuid.Parse(payload.Token)
	if err != nil {
		return invalid("恢复参数无效")
	}
	if err := s.desktopLoginsActive(ctx, session); err != nil {
		return err
	}
	data, _ := json.Marshal(map[string]string{"resume_token": token.String()})
	ack, _ := json.Marshal(desktopMessage{Type: "resumed", ID: m.ID, From: m.To, To: me.Device, Payload: data})
	// 授权检查期间 end/reject 可能已删除记录，不能再发成功确认。
	ok, err := s.Redis.Eval(ctx, `if redis.call('get',KEYS[1]) == ARGV[1] then redis.call('publish',KEYS[2],ARGV[2]); return 1 end; return 0`,
		[]string{key, peerChannel(purpose, me.User, me.Device)}, raw, ack).Int()
	if err != nil {
		return err
	}
	if ok != 1 {
		return problem(409, "expired", "连接会话已结束或过期")
	}
	return nil
}

// 独立于 HTTP 请求速率，限制长连接中的消息洪泛。
func (s *Server) limitPeerSignals(ctx context.Context, me identity, purpose string) error {
	key := fmt.Sprintf("taoscreen:%s:rate:%s:%s:%d", purpose, me.User, me.Device, time.Now().Unix()/60)
	count, e := s.Redis.Incr(ctx, key).Result()
	if e != nil {
		return e
	}
	if count == 1 {
		s.Redis.Expire(ctx, key, 2*time.Minute)
	}
	if count > 600 {
		return problem(429, "rate_limited", "信令过于频繁")
	}
	return nil
}
func (s *Server) desktopSignal(w http.ResponseWriter, r *http.Request) error {
	return s.peerSignal(w, r, "desktop", s.routeDesktop)
}

func (s *Server) portsSignal(w http.ResponseWriter, r *http.Request) error {
	return s.peerSignal(w, r, "ports", s.routePorts)
}

// 每种用途独立租约、频道和会话，断开桌面连接不影响端口转发。
func (s *Server) peerSignal(w http.ResponseWriter, r *http.Request, purpose string, route func(context.Context, identity, desktopMessage) error) error {
	me := owner(r)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	lease := uuid.NewString()
	key := "taoscreen:" + purpose + ":online:" + me.User + ":" + me.Device
	ok, err := s.Redis.SetNX(ctx, key, lease, presenceTTL).Result()
	if err != nil {
		return err
	}
	if !ok {
		slog.Info("信令连接占用", "purpose", purpose, "device", me.Device, "request_id", r.Context().Value(requestKey))
		w.Header().Set("Retry-After", "2")
		return problem(409, "already_connected", "此设备已有同用途连接，请等待旧连接释放或关闭重复实例")
	}
	defer func() {
		cleanup, done := context.WithTimeout(context.Background(), 2*time.Second)
		defer done()
		s.Redis.Eval(cleanup, `if redis.call('get',KEYS[1]) == ARGV[1] then return redis.call('del',KEYS[1]) end; return 0`, []string{key}, lease)
	}()
	sub := s.Redis.Subscribe(ctx, "taoscreen:"+purpose+":signal:"+me.User+":"+me.Device)
	defer sub.Close()
	if _, err = sub.Receive(ctx); err != nil {
		return err
	}

	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return nil
	}
	defer conn.CloseNow()
	started := time.Now()
	reason := "connection_closed"
	slog.Info("信令连接建立", "purpose", purpose, "connection", lease, "device", me.Device)
	defer func() {
		slog.Info("信令连接结束", "purpose", purpose, "connection", lease, "device", me.Device,
			"reason", reason, "duration_ms", time.Since(started).Milliseconds())
	}()
	conn.SetReadLimit(64 * 1024)
	write := func(m desktopMessage) error {
		wctx, done := context.WithTimeout(ctx, 10*time.Second)
		defer done()
		err := wsjson.Write(wctx, conn, m)
		if err != nil {
			reason = "write_failed"
		}
		return err
	}
	active := func() bool {
		check, done := context.WithTimeout(ctx, 5*time.Second)
		defer done()
		valid, err := s.sessionActive(check, me.Session)
		if err != nil {
			reason = "authentication_unavailable"
			return false
		}
		if !valid {
			_ = write(desktopMessage{Type: "session_revoked"})
			reason = "session_revoked"
			_ = conn.Close(closeSessionRevoked, "session revoked")
			return false
		}
		return true
	}
	hello := desktopMessage{Type: "hello", From: me.Device}
	if purpose == "desktop" {
		hello.Payload = json.RawMessage(`{"resume":true,"keepalive":true}`)
	} else if purpose == "ports" {
		hello.Payload = json.RawMessage(`{"resume":true,"keepalive":true,"independent":true}`)
	}
	if write(hello) != nil {
		return nil
	}
	input := make(chan desktopMessage, 16)
	readErrors := make(chan error, 1)
	go func() {
		defer cancel()
		for {
			var message desktopMessage
			if err := wsjson.Read(ctx, conn, &message); err != nil {
				readErrors <- err
				return
			}
			select {
			case input <- message:
			case <-ctx.Done():
				return
			}
		}
	}()
	tick := time.NewTicker(25 * time.Second)
	defer tick.Stop()
	messages := sub.Channel()
	for {
		select {
		case <-ctx.Done():
			select {
			case err := <-readErrors:
				reason = fmt.Sprintf("read_closed_%d", websocket.CloseStatus(err))
			default:
			}
			return nil
		case message := <-input:
			if !active() {
				return nil
			}
			if err = route(ctx, me, message); err != nil {
				code, messageText := "service_unavailable", "信令服务暂不可用，请稍后重试"
				var apiError *APIError
				if errors.As(err, &apiError) {
					code, messageText = apiError.Code, apiError.Message
				}
				payload, _ := json.Marshal(map[string]string{"code": code, "message": messageText})
				if write(desktopMessage{Type: "error", ID: message.ID, Payload: payload}) != nil {
					return nil
				}
			}
		case message, open := <-messages:
			if !open {
				reason = "subscription_closed"
				return nil
			}
			if !active() {
				return nil
			}
			var m desktopMessage
			if json.Unmarshal([]byte(message.Payload), &m) == nil && m.To == me.Device {
				if write(m) != nil {
					return nil
				}
			}
		case <-tick.C:
			if !active() {
				return nil
			}
			// 写成功只说明数据进入缓冲区。必须收到对端 Pong 才续租，防止半断开连接永久占位。
			err := peerHeartbeat(ctx, conn, 10*time.Second, func(ctx context.Context) error {
				alive, err := s.Redis.Eval(ctx, `if redis.call('get',KEYS[1]) == ARGV[1] then return redis.call('expire',KEYS[1],70) end; return 0`, []string{key}, lease).Int()
				if err != nil {
					return err
				}
				if alive != 1 {
					return errors.New("lease lost")
				}
				return nil
			})
			if err != nil {
				reason = "heartbeat_or_lease_failed"
				return nil
			}
			if write(desktopMessage{Type: "heartbeat"}) != nil {
				return nil
			}
		}
	}
}

func peerHeartbeat(ctx context.Context, conn *websocket.Conn, timeout time.Duration, renew func(context.Context) error) error {
	probe, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := conn.Ping(probe); err != nil {
		return err
	}
	return renew(probe)
}
