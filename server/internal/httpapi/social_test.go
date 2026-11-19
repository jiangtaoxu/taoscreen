package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	jose "github.com/go-jose/go-jose/v4"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"golang.org/x/oauth2"
	"taoscreen.local/server/internal/config"
	"taoscreen.local/server/internal/database"
)

type providerCode struct {
	challenge, nonce string
	identity         socialIdentity
}
type providerFixture struct {
	server     *httptest.Server
	signer     jose.Signer
	public     jose.JSONWebKey
	mu         sync.Mutex
	next       socialIdentity
	codes      map[string]providerCode
	tokens     map[string]socialIdentity
	wrongNonce bool
	githubID   int64
}

func fixtureProvider(t *testing.T) *providerFixture {
	t.Helper()
	key, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	signer, e := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key}, (&jose.SignerOptions{}).WithHeader("kid", "fixture"))
	if e != nil {
		t.Fatal(e)
	}
	f := &providerFixture{signer: signer, public: jose.JSONWebKey{Key: &key.PublicKey, KeyID: "fixture", Algorithm: "RS256", Use: "sig"}, codes: map[string]providerCode{}, tokens: map[string]socialIdentity{}, next: socialIdentity{Subject: uuid.NewString(), Email: "fixture-" + uuid.NewString() + "@example.test", Name: "Test user", Verified: true}}
	f.githubID = time.Now().UnixNano()
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}
func (f *providerFixture) sign(claims map[string]any) string {
	b, _ := json.Marshal(claims)
	signed, _ := f.signer.Sign(b)
	v, _ := signed.CompactSerialize()
	return v
}
func (f *providerFixture) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.URL.Path {
	case "/jwks":
		jsonReply(w, 200, jose.JSONWebKeySet{Keys: []jose.JSONWebKey{f.public}})
	case "/authorize":
		if r.URL.Query().Get("code_challenge_method") != "S256" {
			w.WriteHeader(400)
			return
		}
		code, _ := randomToken()
		f.codes[code] = providerCode{r.URL.Query().Get("code_challenge"), r.URL.Query().Get("nonce"), f.next}
		callback, _ := url.Parse(r.URL.Query().Get("redirect_uri"))
		query := callback.Query()
		query.Set("code", code)
		query.Set("state", r.URL.Query().Get("state"))
		callback.RawQuery = query.Encode()
		http.Redirect(w, r, callback.String(), 303)
	case "/token":
		r.ParseForm()
		code, ok := f.codes[r.Form.Get("code")]
		if !ok || code.challenge != pkceChallenge(r.Form.Get("code_verifier")) || r.Form.Get("client_id") != "fixture-client" || r.Form.Get("client_secret") != "fixture-secret" {
			jsonReply(w, 400, map[string]string{"error": "invalid_grant"})
			return
		}
		delete(f.codes, r.Form.Get("code"))
		access, _ := randomToken()
		f.tokens[access] = code.identity
		nonce := code.nonce
		if f.wrongNonce {
			nonce = "wrong"
		}
		id := f.sign(map[string]any{"iss": f.server.URL, "aud": "fixture-client", "sub": code.identity.Subject, "exp": time.Now().Add(time.Minute).Unix(), "iat": time.Now().Unix(), "nonce": nonce, "email": code.identity.Email, "email_verified": code.identity.Verified, "name": code.identity.Name})
		jsonReply(w, 200, map[string]any{"token_type": "Bearer", "access_token": access, "id_token": id, "expires_in": 60})
	case "/user":
		id, ok := f.tokens[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
		if !ok {
			w.WriteHeader(401)
			return
		}
		jsonReply(w, 200, map[string]any{"id": f.githubID, "login": id.Subject, "name": id.Name})
	case "/user/emails":
		id, ok := f.tokens[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
		if !ok {
			w.WriteHeader(401)
			return
		}
		jsonReply(w, 200, []map[string]any{{"email": id.Email, "primary": true, "verified": id.Verified}})
	default:
		w.WriteHeader(404)
	}
}
func (f *providerFixture) provider(name, callback string) *socialProvider {
	client := authHTTPClient()
	p := &socialProvider{oauth: oauth2.Config{ClientID: "fixture-client", ClientSecret: "fixture-secret", RedirectURL: callback,
		Endpoint: oauth2.Endpoint{AuthURL: f.server.URL + "/authorize", TokenURL: f.server.URL + "/token", AuthStyle: oauth2.AuthStyleInParams}, Scopes: []string{"openid", "email"}}, client: client, userURL: f.server.URL + "/user", emailsURL: f.server.URL + "/user/emails"}
	if name == "google" {
		p.verifier = oidc.NewVerifier(f.server.URL, oidc.NewRemoteKeySet(oidc.ClientContext(context.Background(), client), f.server.URL+"/jwks"), &oidc.Config{ClientID: "fixture-client"})
	}
	return p
}
func TestSocialProviderChecksNonceAndVerifiedEmail(t *testing.T) {
	f := fixtureProvider(t)
	for _, tc := range []struct {
		name                     string
		verified, nonce, success bool
	}{{"valid", true, false, true}, {"wrong_nonce", true, true, false}, {"unverified", false, false, false}} {
		t.Run(tc.name, func(t *testing.T) {
			verifier := oauth2.GenerateVerifier()
			nonce, _ := randomToken()
			code, _ := randomToken()
			f.next.Verified = tc.verified
			f.wrongNonce = tc.nonce
			f.codes[code] = providerCode{pkceChallenge(verifier), nonce, f.next}
			_, e := f.provider("google", "https://example.test/callback").exchange(context.Background(), code, verifier, nonce)
			if (e == nil) != tc.success {
				t.Fatalf("provider validation success=%v", e == nil)
			}
		})
	}
	if validOAuthSecret(strings.Repeat("A", 42) + "B") {
		t.Fatal("非规范 base64url 不能用作登录凭据")
	}
}
func TestAdminRejectsForgedOrWrongApplicationJWT(t *testing.T) {
	f := fixtureProvider(t)
	s := New(config.Config{Auth: config.Auth{AdminEmails: map[string]bool{"admin@example.test": true}}}, nil, nil)
	s.adminVerifier = oidc.NewVerifier(f.server.URL, oidc.NewRemoteKeySet(oidc.ClientContext(context.Background(), authHTTPClient()), f.server.URL+"/jwks"), &oidc.Config{ClientID: "admin-audience", SupportedSigningAlgs: []string{"RS256"}})
	for _, tc := range []struct {
		name, aud, email, typ, issuer string
		expired, forged               bool
		want                          bool
	}{
		{name: "valid", want: true}, {name: "wrong_audience", aud: "user-client"}, {name: "wrong_email", email: "user@example.test"},
		{name: "wrong_type", typ: "service"}, {name: "wrong_issuer", issuer: "https://other.example.test"}, {name: "expired", expired: true}, {name: "unsigned_header", forged: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			aud, email, typ, issuer := "admin-audience", "admin@example.test", "app", f.server.URL
			if tc.aud != "" {
				aud = tc.aud
			}
			if tc.email != "" {
				email = tc.email
			}
			if tc.typ != "" {
				typ = tc.typ
			}
			if tc.issuer != "" {
				issuer = tc.issuer
			}
			exp := time.Now().Add(time.Minute)
			if tc.expired {
				exp = time.Now().Add(-time.Minute)
			}
			token := f.sign(map[string]any{"iss": issuer, "aud": []string{aud}, "sub": "admin-subject", "email": email, "type": typ, "exp": exp.Unix(), "iat": time.Now().Add(-time.Minute).Unix()})
			request := httptest.NewRequest("GET", "/v1/admin/users", nil)
			if tc.forged {
				request.Header.Set("Cf-Access-Authenticated-User-Email", email)
				request.Header.Set("Authorization", "Bearer "+token)
			} else {
				request.Header.Set("Cf-Access-Jwt-Assertion", token)
			}
			_, e := s.verifyAdmin(request)
			if (e == nil) != tc.want {
				t.Fatalf("admin access accepted=%v", e == nil)
			}
		})
	}
}

type socialAPI struct {
	t        *testing.T
	s        *Server
	api      *httptest.Server
	provider *providerFixture
	db       *pgxpool.Pool
	client   *http.Client
}

func integrationSocial(t *testing.T) *socialAPI {
	t.Helper()
	dbURL := os.Getenv("TAOSCREEN_AUTH_TEST_DATABASE_URL")
	rcURL := os.Getenv("TAOSCREEN_AUTH_TEST_REDIS_URL")
	if dbURL == "" || rcURL == "" {
		t.Skip("设置独立测试数据库与 Redis，或执行 make auth-test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, e := database.Open(ctx, dbURL)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(db.Close)
	if e = database.Check(ctx, db); e != nil {
		t.Fatal(e)
	}
	opts, e := redis.ParseURL(rcURL)
	if e != nil {
		t.Fatal(e)
	}
	rc := redis.NewClient(opts)
	t.Cleanup(func() { rc.Close() })
	s := New(config.Config{Auth: config.Auth{SocialSignup: true, PasswordLogin: true, AdminEmails: map[string]bool{"admin@example.test": true}}, Registration: true}, db, rc)
	// 每个测试使用独立限流来源，保留正式限流实现；不清空任何 Redis 数据。
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.RemoteAddr = "test-" + t.Name() + ":1234"
		s.Handler().ServeHTTP(w, r)
	})
	api := httptest.NewServer(handler)
	t.Cleanup(api.Close)
	s.Config.Auth.PublicURL = api.URL
	f := fixtureProvider(t)
	s.social = map[string]*socialProvider{"google": f.provider("google", api.URL+"/v1/auth/oauth/google/callback"), "github": f.provider("github", api.URL+"/v1/auth/oauth/github/callback")}
	jar, _ := cookiejar.New(nil)
	client := authHTTPClient()
	client.Jar = jar
	s.adminVerifier = oidc.NewVerifier(f.server.URL, oidc.NewRemoteKeySet(oidc.ClientContext(context.Background(), authHTTPClient()), f.server.URL+"/jwks"), &oidc.Config{ClientID: "admin-audience", SupportedSigningAlgs: []string{"RS256"}})
	return &socialAPI{t, s, api, f, db, client}
}
func (a *socialAPI) request(method, path, token string, body any) (int, map[string]any) {
	a.t.Helper()
	var input io.Reader
	if body != nil {
		data, e := json.Marshal(body)
		if e != nil {
			a.t.Fatal(e)
		}
		input = bytes.NewReader(data)
	}
	request, e := http.NewRequest(method, a.api.URL+path, input)
	if e != nil {
		a.t.Fatal(e)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, e := a.client.Do(request)
	if e != nil {
		a.t.Fatal(e)
	}
	defer response.Body.Close()
	var result map[string]any
	json.NewDecoder(response.Body).Decode(&result)
	return response.StatusCode, result
}

type socialFlow struct{ provider, state, verifier, device, startURL, callback, code string }

func (a *socialAPI) start(provider, token, device string) *socialFlow {
	a.t.Helper()
	state, _ := randomToken()
	verifier := oauth2.GenerateVerifier()
	if device == "" {
		device = uuid.NewString()
	}
	path := "/v1/auth/oauth/" + provider + "/start"
	if token != "" {
		path = "/v1/auth/identities/" + provider + "/start"
	}
	status, b := a.request("POST", path, token, map[string]any{"state": state, "code_challenge": pkceChallenge(verifier), "device_id": device, "device_name": "OAuth integration"})
	if status != 201 {
		a.t.Fatalf("start status=%d code=%v", status, b["error"])
	}
	return &socialFlow{provider: provider, state: state, verifier: verifier, device: device, startURL: b["authorization_url"].(string)}
}
func (a *socialAPI) browser(flow *socialFlow) {
	a.t.Helper()
	response, e := a.client.Get(flow.startURL)
	if e != nil {
		a.t.Fatal(e)
	}
	response.Body.Close()
	if response.StatusCode != 303 {
		a.t.Fatalf("authorize status=%d", response.StatusCode)
	}
	response, e = a.client.Get(response.Header.Get("Location"))
	if e != nil {
		a.t.Fatal(e)
	}
	response.Body.Close()
	if response.StatusCode != 303 {
		a.t.Fatalf("provider authorize status=%d", response.StatusCode)
	}
	flow.callback = response.Header.Get("Location")
}
func (a *socialAPI) callback(flow *socialFlow) string {
	a.t.Helper()
	response, e := a.client.Get(flow.callback)
	if e != nil {
		a.t.Fatal(e)
	}
	defer response.Body.Close()
	if response.StatusCode != 303 {
		a.t.Fatalf("callback status=%d", response.StatusCode)
	}
	redirect, _ := url.Parse(response.Header.Get("Location"))
	if redirect.Scheme != "taoscreen" || redirect.Host != "auth" || redirect.Path != "/callback" || redirect.Query().Get("state") != flow.state {
		a.t.Fatal("invalid desktop callback")
	}
	if redirect.Query().Get("access_token") != "" || redirect.Query().Get("refresh_token") != "" {
		a.t.Fatal("URL must not contain session credentials")
	}
	flow.code = redirect.Query().Get("code")
	return redirect.Query().Get("error")
}
func (a *socialAPI) exchange(flow *socialFlow, token string) (int, map[string]any) {
	return a.request("POST", "/v1/auth/oauth/"+flow.provider+"/exchange", token, map[string]string{"state": flow.state, "code": flow.code, "code_verifier": flow.verifier})
}
func (a *socialAPI) login(provider string) (*socialFlow, map[string]any) {
	f := a.start(provider, "", "")
	a.browser(f)
	if failure := a.callback(f); failure != "" {
		a.t.Fatalf("callback failure=%s", failure)
	}
	status, b := a.exchange(f, "")
	if status != 200 {
		a.t.Fatalf("exchange status=%d error=%v", status, b["error"])
	}
	return f, b
}
func TestSocialRegistrationReplayLinkAndAdminIsolation(t *testing.T) {
	a := integrationSocial(t)
	flow, first := a.login("google")
	token := first["access_token"].(string)
	user := first["user_id"].(string)
	if status, _ := a.exchange(flow, ""); status != 401 {
		t.Fatal("exchange replay accepted")
	}
	link := a.start("github", token, flow.device)
	a.browser(link)
	if a.callback(link) != "" {
		t.Fatal("link callback failed")
	}
	if status, _ := a.exchange(link, ""); status != 401 {
		t.Fatal("binding without original session accepted")
	}
	if status, b := a.exchange(link, token); status != 200 || b["linked"] != true {
		t.Fatal("explicit account binding failed")
	}
	_, second := a.login("github")
	if second["user_id"] != user {
		t.Fatal("linked provider created another user")
	}
	if status, _ := a.request("GET", "/v1/admin/users", token, nil); status != 401 {
		t.Fatal("ordinary session entered admin API")
	}
	if status, b := a.request("GET", "/v1/auth/identities", token, nil); status != 200 || len(b["identities"].([]any)) != 2 {
		t.Fatal("linked identities missing")
	}
	// 已签名且匹配专用 AUD 的管理员 JWT 才能查询用户，且响应不能包含密码/会话令牌。
	admin := a.provider.sign(map[string]any{"iss": a.provider.server.URL, "aud": []string{"admin-audience"}, "sub": "admin", "email": "admin@example.test", "type": "app", "exp": time.Now().Add(time.Minute).Unix()})
	req, _ := http.NewRequest("GET", a.api.URL+"/v1/admin/users/"+user, nil)
	req.Header.Set("Cf-Access-Jwt-Assertion", admin)
	resp, e := a.client.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || !bytes.Contains(data, []byte("google")) || !bytes.Contains(data, []byte("github")) || bytes.Contains(data, []byte("password_hash")) || bytes.Contains(data, []byte("access_token")) {
		t.Fatal("admin registration detail invalid")
	}
}
func TestSocialDoesNotMergeEmailAndRejectsCSRF(t *testing.T) {
	a := integrationSocial(t)
	f, first := a.login("google")
	second := a.start("github", "", "")
	a.browser(second)
	a.callback(second)
	if status, _ := a.exchange(second, ""); status != 409 {
		t.Fatal("same email automatically merged")
	}
	pending := a.start("google", "", "")
	a.browser(pending)
	// 无浏览器绑定 cookie 的第三方请求不能消费合法回调。
	noCookies := authHTTPClient()
	resp, e := noCookies.Get(pending.callback)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatal("callback without cookie accepted")
	}
	if a.callback(pending) != "" {
		t.Fatal("legitimate callback should remain usable")
	}
	correct := pending.verifier
	pending.verifier = oauth2.GenerateVerifier()
	if status, _ := a.exchange(pending, ""); status != 401 {
		t.Fatal("wrong PKCE accepted")
	}
	pending.verifier = correct
	correctState := pending.state
	pending.state, _ = randomToken()
	if status, _ := a.exchange(pending, ""); status != 401 {
		t.Fatal("wrong state accepted")
	}
	pending.state = correctState
	if status, b := a.exchange(pending, ""); status != 200 || b["user_id"] != first["user_id"] {
		t.Fatal("failed attempts consumed legitimate exchange")
	}
	status, _ := a.request("POST", "/v1/auth/identities/github/start", first["access_token"].(string), map[string]string{"state": f.state, "code_challenge": pkceChallenge(f.verifier), "device_id": uuid.NewString(), "device_name": "wrong device"})
	if status != 400 {
		t.Fatal("link device identity not checked")
	}
}
func TestSocialExpiredTransactionsAndRevokedBinding(t *testing.T) {
	a := integrationSocial(t)
	f, first := a.login("google")
	token := first["access_token"].(string)
	pending := a.start("github", token, f.device)
	a.browser(pending)
	a.callback(pending)
	if status, _ := a.request("POST", "/v1/auth/logout", token, nil); status != 204 {
		t.Fatal("logout failed")
	}
	if status, _ := a.exchange(pending, token); status != 401 {
		t.Fatal("revoked original session bound identity")
	}
	expired := a.start("google", "", "")
	a.browser(expired)
	a.callback(expired)
	if _, e := a.db.Exec(context.Background(), "UPDATE auth_logins SET expires_at=now()-interval '1 second' WHERE code_hash=$1", digest([]byte(expired.code))); e != nil {
		t.Fatal(e)
	}
	if status, _ := a.exchange(expired, ""); status != 401 {
		t.Fatal("expired exchange accepted")
	}
}
