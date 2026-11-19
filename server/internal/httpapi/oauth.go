package httpapi

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/oauth2"
)

const oauthLifetime = 5 * time.Minute

type socialIdentity struct {
	Subject  string `json:"subject"`
	Email    string `json:"email"`
	Name     string `json:"name"`
	Verified bool   `json:"verified"`
}
type socialProvider struct {
	oauth              oauth2.Config
	verifier           *oidc.IDTokenVerifier
	client             *http.Client
	userURL, emailsURL string
}

func authHTTPClient() *http.Client {
	return &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func (s *Server) initSocialProviders() {
	s.social = map[string]*socialProvider{}
	client := authHTTPClient()
	c := s.Config.Auth
	if c.Google.Enabled() {
		ctx := oidc.ClientContext(context.Background(), client)
		s.social["google"] = &socialProvider{
			oauth: oauth2.Config{ClientID: c.Google.ClientID, ClientSecret: c.Google.ClientSecret,
				Endpoint:    oauth2.Endpoint{AuthURL: "https://accounts.google.com/o/oauth2/v2/auth", TokenURL: "https://oauth2.googleapis.com/token", AuthStyle: oauth2.AuthStyleInParams},
				RedirectURL: c.PublicURL + "/v1/auth/oauth/google/callback", Scopes: []string{"openid", "email", "profile"}},
			verifier: oidc.NewVerifier("https://accounts.google.com", oidc.NewRemoteKeySet(ctx, "https://www.googleapis.com/oauth2/v3/certs"), &oidc.Config{ClientID: c.Google.ClientID}), client: client,
		}
	}
	if c.GitHub.Enabled() {
		s.social["github"] = &socialProvider{oauth: oauth2.Config{ClientID: c.GitHub.ClientID, ClientSecret: c.GitHub.ClientSecret,
			Endpoint:    oauth2.Endpoint{AuthURL: "https://github.com/login/oauth/authorize", TokenURL: "https://github.com/login/oauth/access_token", AuthStyle: oauth2.AuthStyleInParams},
			RedirectURL: c.PublicURL + "/v1/auth/oauth/github/callback", Scopes: []string{"read:user", "user:email"}},
			client: client, userURL: "https://api.github.com/user", emailsURL: "https://api.github.com/user/emails"}
	}
}
func (s *Server) provider(r *http.Request) (*socialProvider, error) {
	p := s.social[r.PathValue("provider")]
	if p == nil {
		return nil, problem(503, "provider_unavailable", "此登录方式尚未配置，请联系管理员")
	}
	return p, nil
}
func validOAuthSecret(v string) bool {
	if len(v) != 43 {
		return false
	}
	b, e := base64.RawURLEncoding.DecodeString(v)
	return e == nil && len(b) == 32 && base64.RawURLEncoding.EncodeToString(b) == v
}
func pkceChallenge(verifier string) string {
	h := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(h[:])
}
func oauthInvalid() error {
	return problem(401, "invalid_oauth_transaction", "登录事务无效、已过期或已使用，请重新开始")
}
func (s *Server) authProviders(w http.ResponseWriter, r *http.Request) error {
	providers := []map[string]any{}
	for _, name := range []string{"google", "github"} {
		providers = append(providers, map[string]any{"id": name, "enabled": s.social[name] != nil})
	}
	return jsonReply(w, 200, map[string]any{"providers": providers, "social_signup": s.Config.Auth.SocialSignup, "password_login": s.Config.Auth.PasswordLogin})
}
func (s *Server) oauthStart(w http.ResponseWriter, r *http.Request) error {
	return s.startOAuth(w, r, false)
}
func (s *Server) oauthLinkStart(w http.ResponseWriter, r *http.Request) error {
	return s.startOAuth(w, r, true)
}
func (s *Server) startOAuth(w http.ResponseWriter, r *http.Request, link bool) error {
	if _, e := s.provider(r); e != nil {
		return e
	}
	var b struct {
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		State      string `json:"state"`
		Challenge  string `json:"code_challenge"`
	}
	if e := parseJSON(r, &b, 4096); e != nil {
		return e
	}
	if !(credentials{DeviceID: b.DeviceID, DeviceName: b.DeviceName}).validDevice() || !validOAuthSecret(b.State) || !validOAuthSecret(b.Challenge) {
		return invalid("设备信息、state 或 PKCE challenge 无效")
	}
	purpose := "login"
	var targetUser, targetSession any
	if link {
		me := owner(r)
		if b.DeviceID != me.Device {
			return invalid("绑定设备与当前登录不一致")
		}
		purpose = "link"
		targetUser = me.User
		targetSession = me.Session
	}
	ticket, e := randomToken()
	if e != nil {
		return e
	}
	verifier := oauth2.GenerateVerifier()
	nonce, e := randomToken()
	if e != nil {
		return e
	}
	if _, e = s.DB.Exec(r.Context(), "DELETE FROM auth_logins WHERE expires_at<now()"); e != nil {
		return e
	}
	_, e = s.DB.Exec(r.Context(), `INSERT INTO auth_logins(ticket_hash,provider,purpose,target_user,target_session,device_id,device_name,client_state,code_challenge,provider_verifier,nonce,expires_at)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`, digest([]byte(ticket)), r.PathValue("provider"), purpose, targetUser, targetSession, b.DeviceID, b.DeviceName, b.State, b.Challenge, verifier, nonce, time.Now().UTC().Add(oauthLifetime))
	if e != nil {
		return e
	}
	return jsonReply(w, 201, map[string]string{"authorization_url": s.Config.Auth.PublicURL + "/v1/auth/oauth/" + r.PathValue("provider") + "/authorize?ticket=" + url.QueryEscape(ticket)})
}
func oauthCookie(state, provider string) *http.Cookie {
	return &http.Cookie{Name: "taoscreen_oauth_" + digest([]byte(state))[:16], Path: "/v1/auth/oauth/" + provider + "/callback", HttpOnly: true, SameSite: http.SameSiteLaxMode}
}
func (s *Server) oauthAuthorize(w http.ResponseWriter, r *http.Request) error {
	p, e := s.provider(r)
	if e != nil {
		return e
	}
	ticket := r.URL.Query().Get("ticket")
	if !validOAuthSecret(ticket) {
		return oauthInvalid()
	}
	browser, e := randomToken()
	if e != nil {
		return e
	}
	var verifier, nonce string
	e = s.DB.QueryRow(r.Context(), `UPDATE auth_logins SET browser_hash=$1 WHERE ticket_hash=$2 AND provider=$3 AND browser_hash IS NULL AND NOT callback_used AND expires_at>now() RETURNING provider_verifier,nonce`, digest([]byte(browser)), digest([]byte(ticket)), r.PathValue("provider")).Scan(&verifier, &nonce)
	if errors.Is(e, pgx.ErrNoRows) {
		return oauthInvalid()
	}
	if e != nil {
		return e
	}
	cookie := oauthCookie(ticket, r.PathValue("provider"))
	cookie.Value = browser
	cookie.MaxAge = int(oauthLifetime.Seconds())
	cookie.Secure = strings.HasPrefix(s.Config.Auth.PublicURL, "https://")
	http.SetCookie(w, cookie)
	w.Header().Set("Referrer-Policy", "no-referrer")
	options := []oauth2.AuthCodeOption{oauth2.S256ChallengeOption(verifier)}
	if r.PathValue("provider") == "google" {
		options = append(options, oidc.Nonce(nonce))
	}
	http.Redirect(w, r, p.oauth.AuthCodeURL(ticket, options...), http.StatusSeeOther)
	return nil
}
func (p *socialProvider) exchange(ctx context.Context, code, verifier, nonce string) (socialIdentity, error) {
	var result socialIdentity
	ctx = context.WithValue(ctx, oauth2.HTTPClient, p.client)
	token, e := p.oauth.Exchange(ctx, code, oauth2.VerifierOption(verifier))
	if e != nil {
		return result, problem(401, "oauth_provider_failed", "第三方登录验证失败，请重新登录")
	}
	if p.verifier != nil {
		raw, ok := token.Extra("id_token").(string)
		if !ok {
			return result, oauthInvalid()
		}
		id, e := p.verifier.Verify(ctx, raw)
		if e != nil {
			return result, oauthInvalid()
		}
		if subtle.ConstantTimeCompare([]byte(id.Nonce), []byte(nonce)) != 1 {
			return result, oauthInvalid()
		}
		var claims struct {
			Email    string `json:"email"`
			Name     string `json:"name"`
			Verified bool   `json:"email_verified"`
		}
		if e = id.Claims(&claims); e != nil || !claims.Verified || id.Subject == "" {
			return result, problem(401, "email_not_verified", "第三方账号未提供已验证邮箱")
		}
		result = socialIdentity{Subject: id.Subject, Email: claims.Email, Name: claims.Name, Verified: claims.Verified}
	} else {
		var user struct {
			ID    int64  `json:"id"`
			Login string `json:"login"`
			Name  string `json:"name"`
		}
		if e = p.getJSON(ctx, p.userURL, token.AccessToken, &user); e != nil {
			return result, e
		}
		if user.ID <= 0 || user.Login == "" {
			return result, oauthInvalid()
		}
		var emails []struct {
			Email    string `json:"email"`
			Primary  bool   `json:"primary"`
			Verified bool   `json:"verified"`
		}
		if e = p.getJSON(ctx, p.emailsURL, token.AccessToken, &emails); e != nil {
			return result, e
		}
		for _, email := range emails {
			if email.Primary && email.Verified {
				result.Email = email.Email
				break
			}
		}
		if result.Email == "" {
			return result, problem(401, "email_not_verified", "请先在 GitHub 设置已验证的主邮箱，并允许读取邮箱")
		}
		name := user.Name
		if name == "" {
			name = user.Login
		}
		result.Subject = strconv.FormatInt(user.ID, 10)
		result.Name = name
		result.Verified = true
	}
	email, e := normalizeEmail(result.Email)
	if e != nil {
		return socialIdentity{}, problem(401, "email_not_verified", "第三方邮箱无效")
	}
	result.Email = email
	if len(result.Subject) > 512 || len(result.Name) > 512 {
		return socialIdentity{}, oauthInvalid()
	}
	return result, nil
}
func (p *socialProvider) getJSON(ctx context.Context, endpoint, token string, out any) error {
	request, e := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if e != nil {
		return e
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, e := p.client.Do(request)
	if e != nil {
		return problem(502, "oauth_provider_unavailable", "第三方服务暂不可用，请重试")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return problem(401, "oauth_provider_failed", "无法读取第三方身份，请重新授权")
	}
	data, e := io.ReadAll(io.LimitReader(resp.Body, 64*1024+1))
	if e != nil || len(data) > 64*1024 {
		return oauthInvalid()
	}
	if e = json.Unmarshal(data, out); e != nil {
		return oauthInvalid()
	}
	return nil
}
func (s *Server) oauthReturn(w http.ResponseWriter, r *http.Request, state, code, failure string) {
	query := url.Values{"state": {state}}
	if failure != "" {
		query.Set("error", failure)
	} else {
		query.Set("code", code)
	}
	w.Header().Set("Referrer-Policy", "no-referrer")
	http.Redirect(w, r, s.Config.Auth.DesktopCallbackURL()+"?"+query.Encode(), http.StatusSeeOther)
}
func (s *Server) oauthCallback(w http.ResponseWriter, r *http.Request) error {
	p, e := s.provider(r)
	if e != nil {
		return e
	}
	state := r.URL.Query().Get("state")
	if !validOAuthSecret(state) {
		return oauthInvalid()
	}
	cookie := oauthCookie(state, r.PathValue("provider"))
	found, e := r.Cookie(cookie.Name)
	if e != nil || !validOAuthSecret(found.Value) {
		return oauthInvalid()
	}
	var verifier, nonce, clientState string
	e = s.DB.QueryRow(r.Context(), `UPDATE auth_logins SET callback_used=true WHERE ticket_hash=$1 AND provider=$2 AND browser_hash=$3 AND NOT callback_used AND expires_at>now() RETURNING provider_verifier,nonce,client_state`, digest([]byte(state)), r.PathValue("provider"), digest([]byte(found.Value))).Scan(&verifier, &nonce, &clientState)
	if errors.Is(e, pgx.ErrNoRows) {
		return oauthInvalid()
	}
	if e != nil {
		return e
	}
	cookie.MaxAge = -1
	cookie.Secure = strings.HasPrefix(s.Config.Auth.PublicURL, "https://")
	http.SetCookie(w, cookie)
	if r.URL.Query().Get("error") != "" {
		s.oauthReturn(w, r, clientState, "", "access_denied")
		return nil
	}
	code := r.URL.Query().Get("code")
	if code == "" || len(code) > 4096 {
		s.oauthReturn(w, r, clientState, "", "authentication_failed")
		return nil
	}
	identity, e := p.exchange(r.Context(), code, verifier, nonce)
	if e != nil {
		s.oauthReturn(w, r, clientState, "", "authentication_failed")
		return nil
	}
	encoded, e := json.Marshal(identity)
	if e != nil {
		return e
	}
	exchange, e := randomToken()
	if e != nil {
		return e
	}
	tag, e := s.DB.Exec(r.Context(), `UPDATE auth_logins SET identity_data=$1,code_hash=$2,provider_verifier='',nonce='' WHERE ticket_hash=$3 AND expires_at>now()`, encoded, digest([]byte(exchange)), digest([]byte(state)))
	if e != nil {
		return e
	}
	if tag.RowsAffected() != 1 {
		return oauthInvalid()
	}
	s.oauthReturn(w, r, clientState, exchange, "")
	return nil
}
func (s *Server) oauthExchange(w http.ResponseWriter, r *http.Request) error {
	if _, e := s.provider(r); e != nil {
		return e
	}
	var b struct {
		Code     string `json:"code"`
		Verifier string `json:"code_verifier"`
		State    string `json:"state"`
	}
	if e := parseJSON(r, &b, 4096); e != nil {
		return e
	}
	if !validOAuthSecret(b.Code) || !validOAuthSecret(b.Verifier) || !validOAuthSecret(b.State) {
		return oauthInvalid()
	}
	tx, e := s.DB.Begin(r.Context())
	if e != nil {
		return e
	}
	defer tx.Rollback(r.Context())
	var purpose, device, name string
	var targetUser, targetSession *string
	var encoded []byte
	e = tx.QueryRow(r.Context(), `DELETE FROM auth_logins WHERE code_hash=$1 AND provider=$2 AND client_state=$3 AND code_challenge=$4 AND callback_used AND identity_data IS NOT NULL AND expires_at>now()
        RETURNING purpose,target_user::text,target_session::text,device_id::text,device_name,identity_data`, digest([]byte(b.Code)), r.PathValue("provider"), b.State, pkceChallenge(b.Verifier)).Scan(&purpose, &targetUser, &targetSession, &device, &name, &encoded)
	if errors.Is(e, pgx.ErrNoRows) {
		return oauthInvalid()
	}
	if e != nil {
		return e
	}
	var identity socialIdentity
	if e = json.Unmarshal(encoded, &identity); e != nil {
		return e
	}
	target := ""
	if purpose == "link" {
		me, e := s.authenticate(r)
		if e != nil {
			return e
		}
		if targetUser == nil || targetSession == nil || me.User != *targetUser || me.Session != *targetSession || me.Device != device {
			return oauthInvalid()
		}
		var active bool
		e = tx.QueryRow(r.Context(), `SELECT true FROM sessions WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL AND expires_at>now() FOR UPDATE`, me.Session, me.User).Scan(&active)
		if errors.Is(e, pgx.ErrNoRows) {
			return oauthInvalid()
		}
		if e != nil {
			return e
		}
		target = me.User
	}
	user, e := s.bindSocialIdentity(r.Context(), tx, r.PathValue("provider"), identity, target)
	if e != nil {
		return e
	}
	if purpose == "link" {
		if e = tx.Commit(r.Context()); e != nil {
			return e
		}
		return jsonReply(w, 200, map[string]any{"linked": true, "provider": r.PathValue("provider")})
	}
	tokens, e := startSession(r.Context(), tx, user, device, name)
	if e != nil {
		return e
	}
	var email string
	e = tx.QueryRow(r.Context(), "UPDATE users SET last_login_at=now() WHERE id=$1 RETURNING email", user).Scan(&email)
	if e != nil {
		return e
	}
	if _, e = tx.Exec(r.Context(), "UPDATE auth_identities SET last_login_at=now() WHERE provider=$1 AND subject=$2", r.PathValue("provider"), identity.Subject); e != nil {
		return e
	}
	tokens["email"] = email
	if e = tx.Commit(r.Context()); e != nil {
		return e
	}
	return jsonReply(w, 200, tokens)
}
func socialConflict() error {
	return problem(409, "identity_conflict", "此邮箱或登录方式已关联其他账号。请先使用原登录方式登录，再主动绑定；不会自动合并账号")
}
func (s *Server) bindSocialIdentity(ctx context.Context, tx pgx.Tx, provider string, id socialIdentity, target string) (string, error) {
	if !id.Verified || id.Subject == "" {
		return "", oauthInvalid()
	}
	// 同一外部身份串行处理，避免并发首次登录建立不同本地账号。
	if _, e := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", provider+":"+id.Subject); e != nil {
		return "", e
	}
	var user string
	e := tx.QueryRow(ctx, "SELECT user_id::text FROM auth_identities WHERE provider=$1 AND subject=$2", provider, id.Subject).Scan(&user)
	if e == nil {
		if target != "" && user != target {
			return "", socialConflict()
		}
		_, e = tx.Exec(ctx, "UPDATE auth_identities SET email=$1,display_name=$2,email_verified=true WHERE provider=$3 AND subject=$4", id.Email, id.Name, provider, id.Subject)
		return user, e
	}
	if !errors.Is(e, pgx.ErrNoRows) {
		return "", e
	}
	if target != "" {
		// 锁定目标账号，使同一用户绑定同一提供方的并发请求遵守唯一约束。
		if e = tx.QueryRow(ctx, "SELECT id::text FROM users WHERE id=$1 FOR UPDATE", target).Scan(&user); e != nil {
			return "", e
		}
	} else {
		if !s.Config.Auth.SocialSignup {
			return "", problem(403, "social_signup_disabled", "当前服务未开放第三方新用户注册")
		}
		user = uuid.NewString()
		_, e = tx.Exec(ctx, `INSERT INTO users(id,email,display_name,email_verified,registration_provider) VALUES($1,$2,$3,true,$4)`, user, id.Email, id.Name, provider)
		if e != nil {
			var pe *pgconn.PgError
			if errors.As(e, &pe) && pe.Code == "23505" {
				return "", socialConflict()
			}
			return "", e
		}
	}
	_, e = tx.Exec(ctx, `INSERT INTO auth_identities(provider,subject,user_id,email,email_verified,display_name) VALUES($1,$2,$3,$4,true,$5)`, provider, id.Subject, user, id.Email, id.Name)
	if e != nil {
		var pe *pgconn.PgError
		if errors.As(e, &pe) && pe.Code == "23505" {
			return "", socialConflict()
		}
	}
	return user, e
}
func (s *Server) listIdentities(w http.ResponseWriter, r *http.Request) error {
	rows, e := s.DB.Query(r.Context(), `SELECT provider,email,display_name,created_at FROM auth_identities WHERE user_id=$1 ORDER BY provider`, owner(r).User)
	if e != nil {
		return e
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var provider, email, name string
		var created time.Time
		if e = rows.Scan(&provider, &email, &name, &created); e != nil {
			return e
		}
		items = append(items, map[string]any{"provider": provider, "email": email, "name": name, "created_at": created})
	}
	if e = rows.Err(); e != nil {
		return e
	}
	return jsonReply(w, 200, map[string]any{"identities": items})
}
