package httpapi

import (
	"context"
	_ "embed"
	"errors"
	"html/template"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const adminSessionLifetime = 8 * time.Hour

//go:embed admin_login.html
var adminLoginHTML string
var adminLoginTemplate = template.Must(template.New("admin-login").Parse(adminLoginHTML))
var adminOriginProtection http.CrossOriginProtection

func adminCookie(secure bool) *http.Cookie {
	name := "taoscreen-admin-dev"
	if secure {
		name = "__Host-taoscreen-admin"
	}
	return &http.Cookie{Name: name, Path: "/", HttpOnly: true, Secure: secure, SameSite: http.SameSiteStrictMode}
}

func (s *Server) localAdminRequest(r *http.Request) (bool, error) {
	if s.Config.Auth.AdminMode != "local" {
		return false, problem(http.StatusNotFound, "not_found", "未启用本地管理后台")
	}
	if err := adminOriginProtection.Check(r); err != nil {
		return false, problem(http.StatusForbidden, "invalid_origin", "请从管理后台页面发起请求")
	}
	return s.credentialTransport(r)
}

func (s *Server) verifyLocalAdmin(r *http.Request) (adminIdentity, error) {
	secure, err := s.localAdminRequest(r)
	if err != nil {
		return adminIdentity{}, err
	}
	cookie, err := r.Cookie(adminCookie(secure).Name)
	if err != nil || len(cookie.Value) != 43 {
		return adminIdentity{}, problem(http.StatusUnauthorized, "admin_unauthorized", "请重新登录管理后台")
	}
	var id adminIdentity
	err = s.DB.QueryRow(r.Context(), `SELECT a.id::text,a.email FROM local_admin_sessions t
		JOIN local_admins a ON a.id=t.admin_id WHERE t.hash=$1 AND t.expires_at>now()`,
		digest([]byte(cookie.Value))).Scan(&id.Subject, &id.Email)
	if errors.Is(err, pgx.ErrNoRows) {
		err = problem(http.StatusUnauthorized, "admin_unauthorized", "请重新登录管理后台")
	}
	return id, err
}

func (s *Server) adminLogin(w http.ResponseWriter, r *http.Request) error {
	secure, err := s.localAdminRequest(r)
	if err != nil {
		return err
	}
	if r.Method == http.MethodGet {
		if _, err = s.verifyLocalAdmin(r); err == nil {
			http.Redirect(w, r, "/admin", http.StatusSeeOther)
			return nil
		}
		return renderAdminLogin(w, http.StatusOK, "")
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err = r.ParseForm(); err != nil {
		return renderAdminLogin(w, http.StatusBadRequest, "登录表单无效")
	}
	token, err := s.startLocalAdminSession(r, r.PostForm.Get("email"), r.PostForm.Get("password"), r.PostForm.Get("code"))
	var issue *APIError
	if errors.As(err, &issue) && issue.Status == http.StatusUnauthorized {
		return renderAdminLogin(w, issue.Status, issue.Message)
	}
	if err != nil {
		return err
	}
	cookie := adminCookie(secure)
	cookie.Value = token
	cookie.MaxAge = int(adminSessionLifetime.Seconds())
	http.SetCookie(w, cookie)
	http.Redirect(w, r, "/admin", http.StatusSeeOther)
	return nil
}

func renderAdminLogin(w http.ResponseWriter, status int, message string) error {
	nonce, err := randomToken()
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'nonce-"+nonce+"'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(status)
	return adminLoginTemplate.Execute(w, struct{ Nonce, Message string }{nonce, message})
}

func (s *Server) startLocalAdminSession(r *http.Request, email, password, code string) (string, error) {
	invalidLogin := problem(http.StatusUnauthorized, "invalid_credentials", "邮箱、密码或验证码有误，请重试")
	email, err := normalizeEmail(email)
	if err != nil || validatePassword(password) != nil {
		return "", invalidLogin
	}
	if err = s.limit(r, "admin-login-ip:"+s.clientIP(r), 10); err != nil {
		return "", err
	}
	if err = s.limit(r, "admin-login-account:"+email, 5); err != nil {
		return "", err
	}
	ctx := r.Context()
	var id, passwordHash string
	var secret []byte
	err = s.DB.QueryRow(ctx, "SELECT id::text,password_hash,totp_ciphertext FROM local_admins WHERE email=$1", email).
		Scan(&id, &passwordHash, &secret)
	if errors.Is(err, pgx.ErrNoRows) {
		passwordHash = dummyPasswordHash
	} else if err != nil {
		return "", err
	}
	release, err := s.passwordSlot()
	if err != nil {
		return "", err
	}
	valid := checkPassword(password, passwordHash)
	release()
	if !valid || id == "" {
		return "", invalidLogin
	}

	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	matched, err := s.consumeAdminCode(ctx, tx, id, email, passwordHash, secret, strings.TrimSpace(code))
	if err != nil {
		return "", err
	}
	if !matched {
		return "", invalidLogin
	}
	token, err := randomToken()
	if err != nil {
		return "", err
	}
	if _, err = tx.Exec(ctx, "DELETE FROM local_admin_sessions WHERE admin_id=$1 AND expires_at<=now()", id); err != nil {
		return "", err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO local_admin_sessions(hash,admin_id,expires_at) VALUES($1,$2,$3)",
		digest([]byte(token)), id, time.Now().Add(adminSessionLifetime)); err != nil {
		return "", err
	}
	return token, tx.Commit(ctx)
}

func (s *Server) consumeAdminCode(ctx context.Context, tx pgx.Tx, id, email, passwordHash string, secret []byte, code string) (bool, error) {
	if len(code) == 26 {
		// Serialize against a reset, and use deletion to consume the recovery code once.
		var exists bool
		err := tx.QueryRow(ctx, "SELECT true FROM local_admins WHERE id=$1 AND password_hash=$2 FOR UPDATE", id, passwordHash).Scan(&exists)
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		result, err := tx.Exec(ctx, "DELETE FROM local_admin_recovery_codes WHERE admin_id=$1 AND hash=$2", id, recoveryCodeHash(code))
		return result.RowsAffected() == 1, err
	}
	aead, err := s.adminOTPEncryption()
	if err != nil {
		return false, err
	}
	plain, err := aead.Open(nil, nil, secret, []byte(email))
	if err != nil {
		return false, err
	}
	step, valid := adminCodeStep(code, string(plain), time.Now())
	if !valid {
		return false, nil
	}
	result, err := tx.Exec(ctx, `UPDATE local_admins SET last_totp_step=$3
		WHERE id=$1 AND password_hash=$2 AND last_totp_step<$3`, id, passwordHash, step)
	return result.RowsAffected() == 1, err
}

func (s *Server) adminLogout(w http.ResponseWriter, r *http.Request) error {
	secure, err := s.localAdminRequest(r)
	if err != nil {
		return err
	}
	cookie := adminCookie(secure)
	if active, e := r.Cookie(cookie.Name); e == nil && len(active.Value) == 43 {
		if _, err = s.DB.Exec(r.Context(), "DELETE FROM local_admin_sessions WHERE hash=$1", digest([]byte(active.Value))); err != nil {
			return err
		}
	}
	cookie.MaxAge = -1
	http.SetCookie(w, cookie)
	http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
	return nil
}
