package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net/http"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/argon2"
)

func normalizeEmail(email string) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	a, e := mail.ParseAddress(email)
	if e != nil || a.Address != email || len(email) > 254 || !strings.Contains(email, ".") {
		return "", invalid("邮箱地址无效")
	}
	return email, nil
}
func validatePassword(p string) error {
	if utf8.RuneCountInString(p) < 12 || len(p) > 256 {
		return invalid("密码必须至少 12 个字符，且不超过 256 字节")
	}
	return nil
}
func HashPassword(p string) (string, error) {
	if e := validatePassword(p); e != nil {
		return "", e
	}
	salt := make([]byte, 16)
	if _, e := rand.Read(salt); e != nil {
		return "", e
	}
	key := argon2.IDKey([]byte(p), salt, 3, 64*1024, 4, 32)
	return "$argon2id$v=19$m=65536,t=3,p=4$" + base64.RawStdEncoding.EncodeToString(salt) + "$" + base64.RawStdEncoding.EncodeToString(key), nil
}

const dummyPasswordHash = "$argon2id$v=19$m=65536,t=3,p=4$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

func checkPassword(p, encoded string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" || parts[2] != "v=19" || parts[3] != "m=65536,t=3,p=4" {
		return false
	}
	salt, e := base64.RawStdEncoding.DecodeString(parts[4])
	if e != nil || len(salt) != 16 {
		return false
	}
	want, e := base64.RawStdEncoding.DecodeString(parts[5])
	if e != nil || len(want) != 32 {
		return false
	}
	got := argon2.IDKey([]byte(p), salt, 3, 64*1024, 4, 32)
	return subtle.ConstantTimeCompare(got, want) == 1
}
func randomToken() (string, error) {
	b := make([]byte, 32)
	_, e := rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b), e
}
func (s *Server) passwordSlot() (func(), error) {
	select {
	case s.passwordSlots <- struct{}{}:
		return func() { <-s.passwordSlots }, nil
	default:
		return nil, problem(429, "auth_busy", "登录请求繁忙，请稍后重试")
	}
}

type credentials struct {
	Email      string `json:"email"`
	Password   string `json:"password"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
}

func (c credentials) validDevice() bool {
	return validID(c.DeviceID) && strings.TrimSpace(c.DeviceName) != "" && len(c.DeviceName) <= 120
}
func (s *Server) CreateUser(ctx context.Context, email, password string) (string, error) {
	email, e := normalizeEmail(email)
	if e != nil {
		return "", e
	}
	hash, e := HashPassword(password)
	if e != nil {
		return "", e
	}
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return "", e
	}
	defer tx.Rollback(ctx)
	id := uuid.NewString()
	if _, e = tx.Exec(ctx, "INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)", id, email, hash); e != nil {
		var pe *pgconn.PgError
		if errors.As(e, &pe) && pe.Code == "23505" {
			return "", problem(409, "email_unavailable", "该邮箱无法注册")
		}
		return "", e
	}
	return id, tx.Commit(ctx)
}
func (s *Server) register(w http.ResponseWriter, r *http.Request) error {
	if !s.Config.Auth.PasswordLogin {
		return problem(403, "password_login_disabled", "此服务未启用邮箱密码登录")
	}
	if !s.Config.Registration {
		return problem(403, "registration_disabled", "当前环境未开放自助注册")
	}
	if _, e := s.credentialTransport(r); e != nil {
		return e
	}
	var c struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if e := parseJSON(r, &c, 4096); e != nil {
		return e
	}
	done, e := s.passwordSlot()
	if e != nil {
		return e
	}
	defer done()
	id, e := s.CreateUser(r.Context(), c.Email, c.Password)
	if e != nil {
		return e
	}
	return jsonReply(w, 201, map[string]string{"user_id": id})
}
func (s *Server) login(w http.ResponseWriter, r *http.Request) error {
	if !s.Config.Auth.PasswordLogin {
		return problem(403, "password_login_disabled", "此服务未启用邮箱密码登录")
	}
	if _, e := s.credentialTransport(r); e != nil {
		return e
	}
	var c credentials
	if e := parseJSON(r, &c, 4096); e != nil {
		return e
	}
	email, e := normalizeEmail(c.Email)
	if e != nil {
		return e
	}
	if e = validatePassword(c.Password); e != nil {
		return e
	}
	if !c.validDevice() {
		return invalid("设备 ID 或名称无效")
	}
	if e = s.limit(r, "password-login:"+email, 10); e != nil {
		return e
	}
	done, e := s.passwordSlot()
	if e != nil {
		return e
	}
	defer done()
	var user string
	var hash *string
	e = s.DB.QueryRow(r.Context(), "SELECT id::text,password_hash FROM users WHERE email=$1", email).Scan(&user, &hash)
	if e != nil && !errors.Is(e, pgx.ErrNoRows) {
		return e
	}
	passwordHash := dummyPasswordHash
	if hash != nil {
		passwordHash = *hash
	}
	if !checkPassword(c.Password, passwordHash) || hash == nil || user == "" {
		return problem(401, "invalid_credentials", "邮箱或密码错误")
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		return e
	}
	defer tx.Rollback(r.Context())
	tokens, e := startSession(r.Context(), tx, user, c.DeviceID, c.DeviceName)
	if e != nil {
		return e
	}
	if _, e = tx.Exec(r.Context(), "UPDATE users SET last_login_at=now() WHERE id=$1", user); e != nil {
		return e
	}
	if e = tx.Commit(r.Context()); e != nil {
		return e
	}
	tokens["email"] = email
	return jsonReply(w, 200, tokens)
}

// startSession 为已验证的 TaoScreen 用户登记设备并创建 30 天会话。
func startSession(ctx context.Context, tx pgx.Tx, user, deviceID, deviceName string) (map[string]any, error) {
	return startSessionUntil(ctx, tx, user, deviceID, deviceName, time.Now().UTC().Add(30*24*time.Hour))
}

func startSessionUntil(ctx context.Context, tx pgx.Tx, user, deviceID, deviceName string, expires time.Time) (map[string]any, error) {
	if _, e := tx.Exec(ctx, "INSERT INTO devices(user_id,id,name) VALUES($1,$2,$3) ON CONFLICT(user_id,id) DO UPDATE SET name=EXCLUDED.name", user, deviceID, deviceName); e != nil {
		return nil, e
	}
	session := uuid.NewString()
	if _, e := tx.Exec(ctx, "INSERT INTO sessions(id,user_id,device_id,expires_at) VALUES($1,$2,$3,$4)", session, user, deviceID, expires); e != nil {
		return nil, e
	}
	tokens, e := issueTokens(ctx, tx, session, expires)
	if e != nil {
		return nil, e
	}
	tokens["user_id"] = user
	tokens["device_id"] = deviceID
	tokens["session_id"] = session
	return tokens, nil
}

func issueTokens(ctx context.Context, tx pgx.Tx, session string, expiry time.Time) (map[string]any, error) {
	access, e := randomToken()
	if e != nil {
		return nil, e
	}
	refresh, e := randomToken()
	if e != nil {
		return nil, e
	}
	accessExpiry := time.Now().UTC().Add(15 * time.Minute)
	if accessExpiry.After(expiry) {
		accessExpiry = expiry
	}
	_, e = tx.Exec(ctx, "INSERT INTO session_tokens(hash,session_id,kind,expires_at) VALUES($1,$2,'access',$3),($4,$2,'refresh',$5)", digest([]byte(access)), session, accessExpiry, digest([]byte(refresh)), expiry)
	return map[string]any{"access_token": access, "refresh_token": refresh, "token_type": "Bearer", "access_expires_at": accessExpiry, "refresh_expires_at": expiry}, e
}
func (s *Server) authenticate(r *http.Request) (identity, error) {
	var i identity
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == r.Header.Get("Authorization") || len(token) != 43 {
		return i, problem(401, "unauthorized", "请先登录")
	}
	e := s.DB.QueryRow(r.Context(), `SELECT s.user_id::text,s.device_id::text,s.id::text FROM sessions s JOIN session_tokens t ON t.session_id=s.id WHERE t.hash=$1 AND t.kind='access' AND t.expires_at>now() AND s.expires_at>now() AND s.revoked_at IS NULL`, digest([]byte(token))).Scan(&i.User, &i.Device, &i.Session)
	if errors.Is(e, pgx.ErrNoRows) {
		return i, problem(401, "unauthorized", "会话已失效")
	}
	return i, e
}
func (s *Server) refresh(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Token string `json:"refresh_token"`
	}
	if e := parseJSON(r, &b, 4096); e != nil {
		return e
	}
	if len(b.Token) != 43 {
		return problem(401, "unauthorized", "刷新凭证无效")
	}
	ctx := r.Context()
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var id string
	var expiry time.Time
	var used, revoked *time.Time
	e = tx.QueryRow(ctx, `SELECT s.id::text,s.expires_at,t.used_at,s.revoked_at FROM session_tokens t JOIN sessions s ON s.id=t.session_id WHERE t.hash=$1 AND t.kind='refresh' AND t.expires_at>now() AND s.expires_at>now() FOR UPDATE OF s,t`, digest([]byte(b.Token))).Scan(&id, &expiry, &used, &revoked)
	if errors.Is(e, pgx.ErrNoRows) {
		return problem(401, "unauthorized", "刷新凭证已失效")
	}
	if e != nil {
		return e
	}
	if used != nil {
		if _, e = tx.Exec(ctx, "UPDATE sessions SET revoked_at=now() WHERE id=$1", id); e != nil {
			return e
		}
		if e = tx.Commit(ctx); e != nil {
			return e
		}
		return problem(401, "refresh_replayed", "检测到旧刷新凭证重放，请重新登录")
	}
	if revoked != nil {
		return problem(401, "unauthorized", "会话已撤销")
	}
	if _, e = tx.Exec(ctx, "UPDATE session_tokens SET used_at=now() WHERE hash=$1", digest([]byte(b.Token))); e != nil {
		return e
	}
	tokens, e := issueTokens(ctx, tx, id, expiry)
	if e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	return jsonReply(w, 200, tokens)
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request) error {
	_, e := s.DB.Exec(r.Context(), "UPDATE sessions SET revoked_at=now() WHERE id=$1 AND user_id=$2", owner(r).Session, owner(r).User)
	if e != nil {
		return e
	}
	w.WriteHeader(204)
	return nil
}
func (s *Server) revoke(w http.ResponseWriter, r *http.Request) error {
	if !validID(r.PathValue("id")) {
		return invalid("会话 ID 无效")
	}
	tag, e := s.DB.Exec(r.Context(), "UPDATE sessions SET revoked_at=now() WHERE id=$1 AND user_id=$2", r.PathValue("id"), owner(r).User)
	if e != nil {
		return e
	}
	if tag.RowsAffected() == 0 {
		return problem(404, "not_found", "会话不存在")
	}
	// 被撤销的设备立即收到通知并断开实时连接，其他设备刷新通讯录。
	w.WriteHeader(204)
	return nil
}
func (s *Server) me(w http.ResponseWriter, r *http.Request) error {
	var email string
	e := s.DB.QueryRow(r.Context(), "SELECT email FROM users WHERE id=$1", owner(r).User).Scan(&email)
	if e != nil {
		return e
	}
	return jsonReply(w, 200, map[string]any{"id": owner(r).User, "email": email, "service": "taoscreen", "protocol_version": 1})
}
func (s *Server) sessions(w http.ResponseWriter, r *http.Request) error {
	rows, e := s.DB.Query(r.Context(), `SELECT s.id::text,s.device_id::text,d.name,s.created_at,s.expires_at,s.revoked_at FROM sessions s JOIN devices d ON d.user_id=s.user_id AND d.id=s.device_id WHERE s.user_id=$1 ORDER BY s.created_at DESC LIMIT 100`, owner(r).User)
	if e != nil {
		return e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, device, name string
		var created, expires time.Time
		var revoked *time.Time
		if e = rows.Scan(&id, &device, &name, &created, &expires, &revoked); e != nil {
			return e
		}
		out = append(out, map[string]any{"id": id, "device_id": device, "device_name": name, "created_at": created, "expires_at": expires, "revoked_at": revoked, "current": id == owner(r).Session})
	}
	if e = rows.Err(); e != nil {
		return e
	}
	return jsonReply(w, 200, map[string]any{"sessions": out})
}
