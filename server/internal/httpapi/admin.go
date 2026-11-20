package httpapi

import (
	"context"
	_ "embed"
	"errors"
	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/jackc/pgx/v5"
	"net/http"
	"strconv"
	"strings"
	"time"
)

//go:embed admin.html
var adminHTML string
var adminTemplate = webTemplate("admin", adminHTML)

const adminIdentityKey contextKey = "admin_identity"

type adminIdentity struct{ Subject, Email string }

func (s *Server) initAdminVerifier() {
	if !s.Config.Auth.AdminAccessEnabled() {
		return
	}
	issuer := "https://" + s.Config.Auth.AdminTeamDomain
	ctx := oidc.ClientContext(context.Background(), authHTTPClient())
	s.adminVerifier = oidc.NewVerifier(issuer, oidc.NewRemoteKeySet(ctx, issuer+"/cdn-cgi/access/certs"), &oidc.Config{ClientID: s.Config.Auth.AdminAudience, SupportedSigningAlgs: []string{"RS256"}})
}
func (s *Server) verifyAdmin(r *http.Request) (adminIdentity, error) {
	if s.Config.Auth.AdminMode == "local" {
		return s.verifyLocalAdmin(r)
	}
	var identity adminIdentity
	if s.adminVerifier == nil {
		return identity, problem(503, "admin_not_configured", "管理员 Cloudflare Access 尚未配置")
	}
	values := r.Header.Values("Cf-Access-Jwt-Assertion")
	if len(values) != 1 || len(values[0]) == 0 || len(values[0]) > 16*1024 {
		return identity, problem(401, "admin_unauthorized", "请通过 Cloudflare Access 登录管理员后台")
	}
	token, e := s.adminVerifier.Verify(r.Context(), values[0])
	if e != nil {
		return identity, problem(401, "admin_unauthorized", "管理员 Access 登录无效或已过期")
	}
	var claims struct {
		Email     string `json:"email"`
		Type      string `json:"type"`
		NotBefore int64  `json:"nbf"`
	}
	if e = token.Claims(&claims); e != nil || claims.Type != "app" || token.Subject == "" || claims.NotBefore > time.Now().Unix()+5 {
		return identity, problem(401, "admin_unauthorized", "管理员 Access 身份无效")
	}
	email := strings.ToLower(strings.TrimSpace(claims.Email))
	if !s.Config.Auth.AdminEmails[email] {
		return identity, problem(403, "admin_forbidden", "当前 Access 账号不在管理员白名单中")
	}
	return adminIdentity{token.Subject, email}, nil
}
func (s *Server) withAdmin(h endpoint) endpoint {
	return func(w http.ResponseWriter, r *http.Request) error {
		identity, e := s.verifyAdmin(r)
		if e != nil {
			return e
		}
		return h(w, r.WithContext(context.WithValue(r.Context(), adminIdentityKey, identity)))
	}
}
func (s *Server) adminConsole(w http.ResponseWriter, r *http.Request) error {
	_, err := s.verifyAdmin(r)
	var issue *APIError
	if s.Config.Auth.AdminMode == "local" && errors.As(err, &issue) && issue.Status == http.StatusUnauthorized {
		http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
		return nil
	}
	if err != nil {
		return err
	}
	return s.adminPage(w, r)
}

func (s *Server) adminPage(w http.ResponseWriter, r *http.Request) error {
	nonce, e := randomToken()
	if e != nil {
		return e
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'nonce-"+nonce+"'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	return adminTemplate.Execute(w, webPageData{Language: s.webLanguage(w, r), Nonce: nonce})
}
func (s *Server) adminMe(w http.ResponseWriter, r *http.Request) error {
	identity := r.Context().Value(adminIdentityKey).(adminIdentity)
	mode := "cloudflare_access"
	if s.Config.Auth.AdminMode == "local" {
		mode = "local"
	}
	return jsonReply(w, 200, map[string]any{"email": identity.Email, "authentication": mode, "read_only": !s.canCreateLocalUser()})
}

func (s *Server) canCreateLocalUser() bool {
	return s.Config.Auth.AdminMode == "local" && s.Config.Auth.PasswordLogin
}

func (s *Server) adminCreateUser(w http.ResponseWriter, r *http.Request) error {
	if !s.canCreateLocalUser() {
		return problem(http.StatusForbidden, "admin_read_only", "当前管理后台未启用本地账号创建")
	}
	var account struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := parseJSON(r, &account, 4096); err != nil {
		return err
	}
	release, err := s.passwordSlot()
	if err != nil {
		return err
	}
	defer release()
	id, err := s.CreateUser(r.Context(), account.Email, account.Password)
	if err != nil {
		return err
	}
	return jsonReply(w, http.StatusCreated, map[string]string{"user_id": id})
}

type adminUserSummary struct {
	ID        string     `json:"id"`
	Email     string     `json:"email"`
	Name      string     `json:"name"`
	Verified  bool       `json:"email_verified"`
	Provider  string     `json:"registration_provider"`
	Created   time.Time  `json:"created_at"`
	LastLogin *time.Time `json:"last_login_at"`
	Devices   int        `json:"device_count"`
	Sessions  int        `json:"active_sessions"`
}

const userSummaryColumns = `u.id::text,u.email,u.display_name,u.email_verified,u.registration_provider,u.created_at,u.last_login_at,
    (SELECT count(*) FROM devices d WHERE d.user_id=u.id),
    (SELECT count(*) FROM sessions s WHERE s.user_id=u.id AND s.revoked_at IS NULL AND s.expires_at>now())`

func scanUser(row pgx.Row) (adminUserSummary, error) {
	var u adminUserSummary
	e := row.Scan(&u.ID, &u.Email, &u.Name, &u.Verified, &u.Provider, &u.Created, &u.LastLogin, &u.Devices, &u.Sessions)
	return u, e
}
func (s *Server) adminUsers(w http.ResponseWriter, r *http.Request) error {
	limit, offset := 50, 0
	var e error
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, e = strconv.Atoi(raw)
		if e != nil || limit < 1 || limit > 100 {
			return invalid("limit 必须为 1–100")
		}
	}
	if raw := r.URL.Query().Get("offset"); raw != "" {
		offset, e = strconv.Atoi(raw)
		if e != nil || offset < 0 || offset > 1000000 {
			return invalid("offset 无效")
		}
	}
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if len(query) > 200 {
		return invalid("搜索内容过长")
	}
	filter := `($1='' OR strpos(lower(u.email),lower($1))>0 OR strpos(lower(u.display_name),lower($1))>0 OR u.id::text=$1)`
	var total int
	if e = s.DB.QueryRow(r.Context(), "SELECT count(*) FROM users u WHERE "+filter, query).Scan(&total); e != nil {
		return e
	}
	rows, e := s.DB.Query(r.Context(), "SELECT "+userSummaryColumns+" FROM users u WHERE "+filter+" ORDER BY u.created_at DESC,u.id LIMIT $2 OFFSET $3", query, limit, offset)
	if e != nil {
		return e
	}
	defer rows.Close()
	users := []adminUserSummary{}
	for rows.Next() {
		user, e := scanUser(rows)
		if e != nil {
			return e
		}
		users = append(users, user)
	}
	if e = rows.Err(); e != nil {
		return e
	}
	return jsonReply(w, 200, map[string]any{"users": users, "total": total, "limit": limit, "offset": offset})
}
func (s *Server) adminUser(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	if !validID(id) {
		return invalid("用户 ID 无效")
	}
	user, e := scanUser(s.DB.QueryRow(r.Context(), "SELECT "+userSummaryColumns+" FROM users u WHERE u.id=$1", id))
	if errors.Is(e, pgx.ErrNoRows) {
		return problem(404, "not_found", "用户不存在")
	}
	if e != nil {
		return e
	}
	rows, e := s.DB.Query(r.Context(), `SELECT provider,subject,email,email_verified,display_name,created_at,last_login_at FROM auth_identities WHERE user_id=$1 ORDER BY provider`, id)
	if e != nil {
		return e
	}
	defer rows.Close()
	identities := []map[string]any{}
	for rows.Next() {
		var provider, subject, email, name string
		var verified bool
		var created time.Time
		var last *time.Time
		if e = rows.Scan(&provider, &subject, &email, &verified, &name, &created, &last); e != nil {
			return e
		}
		identities = append(identities, map[string]any{"provider": provider, "subject": subject, "email": email, "email_verified": verified, "name": name, "created_at": created, "last_login_at": last})
	}
	if e = rows.Err(); e != nil {
		return e
	}
	return jsonReply(w, 200, map[string]any{"user": user, "identities": identities})
}
