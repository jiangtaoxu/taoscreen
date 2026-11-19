package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/coreos/go-oidc/v3/oidc"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"taoscreen.local/server/internal/config"
	"taoscreen.local/server/internal/database"
)

type Server struct {
	Config        config.Config
	DB            *pgxpool.Pool
	Redis         *redis.Client
	passwordSlots chan struct{}
	social        map[string]*socialProvider
	adminVerifier *oidc.IDTokenVerifier
}
type identity struct{ User, Device, Session string }
type contextKey string

const identityKey contextKey = "identity"
const requestKey contextKey = "request_id"

type APIError struct {
	Status  int    `json:"-"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details,omitempty"`
}

func (e *APIError) Error() string { return e.Message }
func problem(status int, code, msg string) *APIError {
	return &APIError{Status: status, Code: code, Message: msg}
}
func invalid(msg string) *APIError   { return problem(400, "invalid_request", msg) }
func owner(r *http.Request) identity { return r.Context().Value(identityKey).(identity) }

type endpoint func(http.ResponseWriter, *http.Request) error

func New(c config.Config, db *pgxpool.Pool, rc *redis.Client) *Server {
	s := &Server{Config: c, DB: db, Redis: rc, passwordSlots: make(chan struct{}, 2)}
	s.initSocialProviders()
	s.initAdminVerifier()
	return s
}
func (s *Server) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /download", s.wrap(false, false, s.downloadPage))
	m.HandleFunc("GET /download/{$}", s.wrap(false, false, func(w http.ResponseWriter, r *http.Request) error {
		http.Redirect(w, r, "/download", http.StatusMovedPermanently)
		return nil
	}))
	m.HandleFunc("GET /v1/desktop/updates/latest", s.wrap(false, false, s.desktopUpdate))
	m.HandleFunc("GET /health/live", s.wrap(false, false, func(w http.ResponseWriter, r *http.Request) error {
		return jsonReply(w, 200, map[string]string{"status": "ok"})
	}))
	m.HandleFunc("GET /health/ready", s.wrap(false, false, s.ready))
	m.HandleFunc("GET /v1/auth/providers", s.wrap(false, false, s.authProviders))
	m.HandleFunc("POST /v1/auth/oauth/{provider}/start", s.wrap(false, true, s.oauthStart))
	m.HandleFunc("GET /v1/auth/oauth/{provider}/authorize", s.wrap(false, true, s.oauthAuthorize))
	m.HandleFunc("GET /v1/auth/oauth/{provider}/callback", s.wrap(false, true, s.oauthCallback))
	m.HandleFunc("POST /v1/auth/oauth/{provider}/exchange", s.wrap(false, true, s.oauthExchange))
	m.HandleFunc("GET /v1/auth/identities", s.wrap(true, true, s.listIdentities))
	m.HandleFunc("POST /v1/auth/identities/{provider}/start", s.wrap(true, true, s.oauthLinkStart))
	m.HandleFunc("GET /admin", s.wrap(false, true, s.adminConsole))
	m.HandleFunc("GET /admin/{$}", s.wrap(false, true, s.adminConsole))
	m.HandleFunc("GET /{$}", s.wrap(false, true, s.adminConsole))
	m.HandleFunc("GET /admin/login", s.wrap(false, true, s.adminLogin))
	m.HandleFunc("POST /admin/login", s.wrap(false, true, s.adminLogin))
	m.HandleFunc("POST /admin/logout", s.wrap(false, true, s.adminLogout))
	m.HandleFunc("POST /v1/admin/users", s.wrap(false, true, s.withAdmin(s.adminCreateUser)))
	m.HandleFunc("GET /v1/admin/me", s.wrap(false, true, s.withAdmin(s.adminMe)))
	m.HandleFunc("GET /v1/admin/users", s.wrap(false, true, s.withAdmin(s.adminUsers)))
	m.HandleFunc("GET /v1/admin/users/{id}", s.wrap(false, true, s.withAdmin(s.adminUser)))
	m.HandleFunc("POST /v1/auth/register", s.wrap(false, true, s.register))
	m.HandleFunc("POST /v1/auth/login", s.wrap(false, true, s.login))
	m.HandleFunc("POST /v1/auth/refresh", s.wrap(false, true, s.refresh))
	m.HandleFunc("POST /v1/auth/logout", s.wrap(true, true, s.logout))
	m.HandleFunc("GET /v1/me", s.wrap(true, true, s.me))
	m.HandleFunc("GET /v1/sessions", s.wrap(true, true, s.sessions))
	m.HandleFunc("DELETE /v1/sessions/{id}", s.wrap(true, true, s.revoke))
	m.HandleFunc("GET /v1/desktop/config", s.wrap(true, true, s.desktopConfig))
	m.HandleFunc("GET /v1/desktop/peers", s.wrap(true, true, s.desktopPeers))
	m.HandleFunc("GET /v1/desktop/signal", s.wrap(true, true, s.desktopSignal))
	m.HandleFunc("GET /v1/ports/config", s.wrap(true, true, s.desktopConfig))
	m.HandleFunc("GET /v1/ports/peers", s.wrap(true, true, s.portsPeers))
	m.HandleFunc("GET /v1/ports/signal", s.wrap(true, true, s.portsSignal))
	return m
}

func (s *Server) wrap(auth, limited bool, h endpoint) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := uuid.NewString()
		r = r.WithContext(context.WithValue(r.Context(), requestKey, id))
		w.Header().Set("X-Request-ID", id)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		defer func() {
			if v := recover(); v != nil {
				slog.Error("请求异常", "request_id", id)
				s.fail(w, r, errors.New("内部错误"))
			}
		}()
		if limited {
			if e := s.limit(r, "ip:"+s.clientIP(r), 600); e != nil {
				s.fail(w, r, e)
				return
			}
		}
		if auth {
			i, e := s.authenticate(r)
			if e != nil {
				s.fail(w, r, e)
				return
			}
			r = r.WithContext(context.WithValue(r.Context(), identityKey, i))
			if limited {
				if e = s.limit(r, "user:"+i.User, 600); e != nil {
					s.fail(w, r, e)
					return
				}
			}
		}
		if !auth && limited {
			if e := s.limit(r, "auth:"+s.clientIP(r), 30); e != nil {
				s.fail(w, r, e)
				return
			}
		}
		if e := h(w, r); e != nil {
			s.fail(w, r, e)
		}
	}
}
func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	var e *APIError
	if !errors.As(err, &e) {
		slog.Error("请求依赖或内部错误", "request_id", r.Context().Value(requestKey), "error_type", fmt.Sprintf("%T", err))
		e = problem(503, "service_unavailable", "服务暂不可用，请保留本地内容后重试")
	}
	if e.Status == 429 {
		w.Header().Set("Retry-After", "60")
	}
	_ = jsonReply(w, e.Status, map[string]any{"error": map[string]any{"code": e.Code, "message": e.Message, "details": e.Details, "request_id": r.Context().Value(requestKey)}})
}
func jsonReply(w http.ResponseWriter, status int, v any) error {
	data, e := json.Marshal(v)
	if e != nil {
		return e
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, e = w.Write(append(data, '\n'))
	return e
}
func parseJSON(r *http.Request, v any, max int64) error {
	if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
		return problem(400, "invalid_content_type", "请求必须使用 application/json")
	}
	b, e := io.ReadAll(io.LimitReader(r.Body, max+1))
	if e != nil {
		return invalid("无法读取请求")
	}
	if int64(len(b)) > max {
		return problem(413, "request_too_large", "请求超过大小上限")
	}
	return strictJSON(b, v)
}
func strictJSON(b []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return invalid("JSON 字段或类型无效")
	}
	var trailing any
	if e := d.Decode(&trailing); e != io.EOF {
		return invalid("只允许一个 JSON 值")
	}
	return nil
}
func validID(v string) bool {
	u, e := uuid.Parse(v)
	return e == nil && u != uuid.Nil && u.String() == v
}
func digest(b []byte) string { x := sha256.Sum256(b); return hex.EncodeToString(x[:]) }

var limiter = redis.NewScript(`local n=redis.call('INCR',KEYS[1]);if n==1 then redis.call('EXPIRE',KEYS[1],60) end;return n`)

func (s *Server) limit(r *http.Request, key string, max int64) error {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	n, e := limiter.Run(ctx, s.Redis, []string{"taoscreen:limit:" + digest([]byte(key))}).Int64()
	if e != nil {
		return e
	}
	if n > max {
		return problem(429, "rate_limited", "请求过于频繁")
	}
	return nil
}
func (s *Server) clientIP(r *http.Request) string {
	host, _, e := net.SplitHostPort(r.RemoteAddr)
	if e != nil {
		return r.RemoteAddr
	}
	ip, e := netip.ParseAddr(host)
	if e != nil {
		return host
	}
	ip = ip.Unmap()
	trusted := func(a netip.Addr) bool {
		for _, p := range s.Config.TrustedProxies {
			if p.Contains(a) {
				return true
			}
		}
		return false
	}
	if !trusted(ip) {
		return ip.String()
	}
	list := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
	for n := len(list) - 1; n >= 0; n-- {
		candidate, e := netip.ParseAddr(strings.TrimSpace(list[n]))
		if e != nil {
			return ip.String()
		}
		ip = candidate.Unmap()
		if !trusted(ip) {
			// 只有可信反向代理记录的实际上一跳属于明确配置的 Cloudflare
			// 网段时，才接纳 CF-Connecting-IP。直连源站伪造此头无效。
			for _, prefix := range s.Config.CloudflareProxies {
				if prefix.Contains(ip) && len(r.Header.Values("CF-Connecting-IP")) == 1 {
					client, err := netip.ParseAddr(r.Header.Get("CF-Connecting-IP"))
					if err == nil && client.Zone() == "" {
						return client.Unmap().String()
					}
				}
			}
			break
		}
	}
	return ip.String()
}
func (s *Server) ready(w http.ResponseWriter, r *http.Request) error {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if e := database.Check(ctx, s.DB); e != nil {
		return e
	}
	if e := s.Redis.Ping(ctx).Err(); e != nil {
		return e
	}
	return jsonReply(w, 200, map[string]string{"status": "ready", "service": "taoscreen"})
}
