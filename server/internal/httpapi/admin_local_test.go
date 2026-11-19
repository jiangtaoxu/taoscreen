package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/pquerna/otp/totp"
	"taoscreen.local/server/internal/config"
)

func TestAdminCredentialTransport(t *testing.T) {
	s := &Server{Config: config.Config{Env: "production", TrustedProxies: []netip.Prefix{netip.MustParsePrefix("192.0.2.10/32")}}}
	for _, tc := range []struct {
		peer, proto string
		want        bool
	}{
		{"192.0.2.10:1234", "https", true},
		{"192.0.2.10:1234", "http", false},
		{"192.0.2.10:1234", "https, http", false},
		{"192.0.2.11:1234", "https", false},
	} {
		r := httptest.NewRequest(http.MethodPost, "http://example.test/admin/login", nil)
		r.RemoteAddr = tc.peer
		r.Header.Set("X-Forwarded-Proto", tc.proto)
		secure, err := s.credentialTransport(r)
		if secure != tc.want || (err == nil) != tc.want {
			t.Fatalf("peer=%s proto=%s secure=%t err=%v", tc.peer, tc.proto, secure, err)
		}
	}
}

func TestAdminLocalLoginAndCreateUser(t *testing.T) {
	fixture := integrationSocial(t)
	s := New(config.Config{Env: "production", Auth: config.Auth{
		AdminMode: "local", AdminOTPKey: []byte("test-local-admin-key-is-32-bytes"), PasswordLogin: true,
	}}, fixture.db, fixture.s.Redis)
	handler := s.Handler()
	testPeer := uuid.NewString()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.RemoteAddr = "local-admin-" + testPeer + ":1234"
		handler.ServeHTTP(w, r)
	}))
	defer server.Close()
	client := server.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	adminEmail := "admin-" + uuid.NewString() + "@example.test"
	userEmail := "user-" + uuid.NewString() + "@example.test"
	const adminPassword = "admin-local-test-only-123!"
	const userPassword = "user-local-test-only-456!"
	key, err := NewAdminAuthenticator(adminEmail)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if remaining := adminTOTPStep - now.Unix()%adminTOTPStep; remaining <= 2 {
		time.Sleep(time.Duration(remaining) * time.Second)
		now = time.Now()
	}
	enrollmentCode, err := totp.GenerateCode(key.Secret(), now.Add(-adminTOTPStep*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	recovery, err := s.ProvisionAdmin(context.Background(), adminEmail, adminPassword, enrollmentCode, key, false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = s.DB.Exec(context.Background(), "DELETE FROM local_admins WHERE email=$1", adminEmail) })
	if len(recovery) != 8 {
		t.Fatal("未生成一次性恢复码")
	}

	request := func(method, path, contentType, body, origin, token string, cookie *http.Cookie, want int) (*http.Response, []byte) {
		t.Helper()
		req, err := http.NewRequest(method, server.URL+path, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		if contentType != "" {
			req.Header.Set("Content-Type", contentType)
		}
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		data, err := io.ReadAll(resp.Body)
		if err != nil || resp.StatusCode != want {
			t.Fatalf("%s %s: status=%d want=%d err=%v", method, path, resp.StatusCode, want, err)
		}
		return resp, data
	}
	login := func(code, origin string, status int) *http.Response {
		t.Helper()
		form := url.Values{"email": {adminEmail}, "password": {adminPassword}, "code": {code}}
		resp, _ := request("POST", "/admin/login", "application/x-www-form-urlencoded", form.Encode(), origin, "", nil, status)
		return resp
	}
	readCookie := func(resp *http.Response) *http.Cookie {
		t.Helper()
		cookies := resp.Cookies()
		if len(cookies) != 1 || cookies[0].Name != "__Host-taoscreen-admin" ||
			!cookies[0].Secure || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode || cookies[0].Path != "/" {
			t.Fatal("管理员 Cookie 缺失安全属性")
		}
		return cookies[0]
	}

	redirect, _ := request("GET", "/admin", "", "", "", "", nil, 303)
	if redirect.Header.Get("Location") != "/admin/login" {
		t.Fatal("管理页面未跳转至本地登录")
	}
	page, body := request("GET", "/admin/login", "", "", "", "", nil, 200)
	if !strings.Contains(string(body), "动态码或恢复码") || strings.Contains(string(body), "{{") ||
		!strings.Contains(page.Header.Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatal("后台登录页面或安全响应头缺失")
	}
	code, err := totp.GenerateCode(key.Secret(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	login(code, "https://other.example.test", 403)
	cookie := readCookie(login(code, server.URL, 303))
	login(code, server.URL, 401)
	recoveryCookie := readCookie(login(strings.ToLower(recovery[0]), server.URL, 303))
	login(recovery[0], server.URL, 401)

	_, body = request("GET", "/v1/admin/me", "", "", "", "", cookie, 200)
	if !strings.Contains(string(body), `"authentication":"local"`) {
		t.Fatal("管理员会话未被识别")
	}
	createBody, _ := json.Marshal(map[string]string{"email": userEmail, "password": userPassword})
	request("POST", "/v1/admin/users", "application/json", string(createBody), "https://other.example.test", "", cookie, 403)
	request("POST", "/v1/auth/register", "application/json", string(createBody), "", "", nil, 403)
	request("POST", "/v1/admin/users", "application/json", string(createBody), server.URL, "", cookie, 201)
	request("POST", "/v1/admin/users", "application/json", string(createBody), server.URL, "", cookie, 409)
	_, body = request("GET", "/v1/auth/providers", "", "", "", "", nil, 200)
	if !strings.Contains(string(body), `"password_login":true`) {
		t.Fatal("服务端未公布密码登录能力")
	}
	loginBody, _ := json.Marshal(map[string]string{"email": " " + strings.ToUpper(userEmail) + " ", "password": userPassword,
		"device_id": uuid.NewString(), "device_name": "Mac"})
	_, body = request("POST", "/v1/auth/login", "application/json", string(loginBody), "", "", nil, 200)
	var credentials struct {
		Email string `json:"email"`
		Token string `json:"access_token"`
	}
	if err = json.Unmarshal(body, &credentials); err != nil || credentials.Email != userEmail || credentials.Token == "" {
		t.Fatal("缺少普通用户凭据或规范化后的邮箱")
	}
	request("GET", "/v1/admin/me", "", "", "", credentials.Token, nil, 401)
	request("GET", "/v1/me", "", "", "", "", cookie, 401)
	request("POST", "/admin/logout", "", "", server.URL, "", cookie, 303)
	request("GET", "/v1/admin/me", "", "", "", "", cookie, 401)
	request("GET", "/v1/admin/me", "", "", "", "", recoveryCookie, 200)

	newKey, err := NewAdminAuthenticator(adminEmail)
	if err != nil {
		t.Fatal(err)
	}
	newCode, err := totp.GenerateCode(newKey.Secret(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.ProvisionAdmin(context.Background(), adminEmail, adminPassword, newCode, newKey, true); err != nil {
		t.Fatal(err)
	}
	request("GET", "/v1/admin/me", "", "", "", "", recoveryCookie, 401)
	login(recovery[1], server.URL, 401)
}
