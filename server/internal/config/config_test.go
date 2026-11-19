package config

import (
	"encoding/base64"
	"testing"
)

func baseline(t *testing.T) {
	t.Helper()
	for _, key := range []string{"DESKTOP_STUN_URLS", "DESKTOP_TURN_URLS", "DESKTOP_TURN_SECRET", "DESKTOP_RELEASE_ORIGIN", "DESKTOP_OAUTH_CALLBACK_SCHEME", "TRUSTED_PROXY_CIDRS", "CLOUDFLARE_PROXY_CIDRS", "ALLOW_PASSWORD_LOGIN", "ALLOW_SOCIAL_SIGNUP", "AUTH_PUBLIC_URL", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "ADMIN_ACCESS_TEAM_DOMAIN", "ADMIN_ACCESS_AUD", "ADMIN_ALLOWED_EMAILS", "ADMIN_AUTH_MODE", "ADMIN_TOTP_ENABLED", "ADMIN_TOTP_KEY"} {
		t.Setenv(key, "")
	}
	t.Setenv("APP_ENV", "test")
	t.Setenv("DATABASE_URL", "postgres://taoscreen:test@localhost/taoscreen_test")
	t.Setenv("REDIS_URL", "redis://localhost:6379/0")
	t.Setenv("ALLOW_REGISTRATION", "true")
}

func TestAuthRequiresCompleteProvidersAndDedicatedAdminConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name   string
		values map[string]string
		valid  bool
	}{
		{"partial_google", map[string]string{"GOOGLE_CLIENT_ID": "test"}, false},
		{"missing_callback_origin", map[string]string{"GOOGLE_CLIENT_ID": "test", "GOOGLE_CLIENT_SECRET": "secret"}, false},
		{"public_http_rejected", map[string]string{"AUTH_PUBLIC_URL": "http://example.test"}, false},
		{"unexpected_path", map[string]string{"AUTH_PUBLIC_URL": "https://example.test/other"}, false},
		{"google_ready", map[string]string{"AUTH_PUBLIC_URL": "https://taoscreen.example.test", "GOOGLE_CLIENT_ID": "test", "GOOGLE_CLIENT_SECRET": "secret"}, true},
		{"admin_missing_email", map[string]string{"ADMIN_ACCESS_TEAM_DOMAIN": "team.cloudflareaccess.com", "ADMIN_ACCESS_AUD": "admin-aud"}, false},
		{"admin_invalid_issuer", map[string]string{"ADMIN_ACCESS_TEAM_DOMAIN": "team.cloudflareaccess.com.evil.test", "ADMIN_ACCESS_AUD": "aud", "ADMIN_ALLOWED_EMAILS": "admin@example.test"}, false},
		{"admin_ready", map[string]string{"ADMIN_ACCESS_TEAM_DOMAIN": "team.cloudflareaccess.com", "ADMIN_ACCESS_AUD": "admin-aud", "ADMIN_ALLOWED_EMAILS": "admin@example.test"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			baseline(t)
			for k, v := range tc.values {
				t.Setenv(k, v)
			}
			_, err := Load()
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v, error=%v", tc.valid, err)
			}
		})
	}
	baseline(t)
	t.Setenv("APP_ENV", "production")
	t.Setenv("ALLOW_REGISTRATION", "false")
	t.Setenv("ALLOW_PASSWORD_LOGIN", "true")
	if _, err := Load(); err == nil {
		t.Fatal("生产环境密码登录必须有 HTTPS 地址")
	}
	t.Setenv("AUTH_PUBLIC_URL", "https://taoscreen.example.test")
	if c, err := Load(); err != nil || !c.Auth.PasswordLogin {
		t.Fatalf("生产环境本地登录未启用：%v", err)
	}
	t.Setenv("ADMIN_AUTH_MODE", "local")
	t.Setenv("ADMIN_TOTP_KEY", "invalid")
	if _, err := Load(); err == nil {
		t.Fatal("本地模式不应接受无效的加密密钥")
	}
	t.Setenv("ADMIN_TOTP_KEY", base64.StdEncoding.EncodeToString(make([]byte, 32)))
	if c, err := Load(); err != nil || c.Auth.AdminMode != "local" || c.Auth.AdminAccessEnabled() || c.Auth.AdminTOTPDisabled {
		t.Fatalf("本地管理模式未正确加载：%v", err)
	}
}

func TestLocalAdminTOTPConfiguration(t *testing.T) {
	baseline(t)
	t.Setenv("ADMIN_AUTH_MODE", "local")
	t.Setenv("ADMIN_TOTP_ENABLED", "false")
	if c, err := Load(); err != nil || !c.Auth.AdminTOTPDisabled || len(c.Auth.AdminOTPKey) != 0 {
		t.Fatalf("关闭动态码时应允许不配置加密密钥：%v", err)
	}
	for _, value := range []string{"true", "typo"} {
		t.Setenv("ADMIN_TOTP_ENABLED", value)
		if _, err := Load(); err == nil {
			t.Fatalf("不应接受无密钥或无效开关配置：%s", value)
		}
	}
}

func TestStandaloneConfiguration(t *testing.T) {
	baseline(t)
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.DesktopReleaseOrigin != "" || c.Auth.DesktopCallbackURL() != "taoscreen://auth/callback" {
		t.Fatal("独立实例默认关闭发布源并兼容原客户端回调")
	}
	t.Setenv("DESKTOP_RELEASE_ORIGIN", "https://releases.example.test:8443/")
	t.Setenv("DESKTOP_OAUTH_CALLBACK_SCHEME", "taoscreen-local")
	c, err = Load()
	if err != nil || c.DesktopReleaseOrigin != "https://releases.example.test:8443" || c.Auth.DesktopCallbackURL() != "taoscreen-local://auth/callback" {
		t.Fatalf("自建发布源或回调配置无效：%v", err)
	}
	for _, tc := range []struct{ key, value string }{
		{"DATABASE_URL", ""}, {"DATABASE_URL", "postgres://localhost/"},
		{"ALLOW_REGISTRATION", ""}, {"DESKTOP_TURN_URLS", "turn:turn.example.test:3478"},
		{"DESKTOP_STUN_URLS", "https://example.test"}, {"TRUSTED_PROXY_CIDRS", "0.0.0.0/0"},
		{"DESKTOP_RELEASE_ORIGIN", "http://releases.example.test"}, {"DESKTOP_RELEASE_ORIGIN", "https://releases.example.test/releases"},
		{"DESKTOP_RELEASE_ORIGIN", "https://user:pass@releases.example.test"}, {"DESKTOP_RELEASE_ORIGIN", "https://releases.example.test?"},
		{"DESKTOP_OAUTH_CALLBACK_SCHEME", "https"}, {"DESKTOP_OAUTH_CALLBACK_SCHEME", "taoscreen://auth/callback"},
	} {
		t.Run(tc.key+tc.value, func(t *testing.T) {
			baseline(t)
			t.Setenv(tc.key, tc.value)
			if _, err := Load(); err == nil {
				t.Fatal("无效配置被接受")
			}
		})
	}
}

func TestProductionRegistrationAndTURN(t *testing.T) {
	baseline(t)
	t.Setenv("APP_ENV", "production")
	if _, err := Load(); err == nil {
		t.Fatal("生产环境不能开放自助注册")
	}
	t.Setenv("ALLOW_REGISTRATION", "false")
	t.Setenv("DESKTOP_TURN_URLS", "turn:turn.example.test:3478,turns:turn.example.test:5349")
	t.Setenv("DESKTOP_TURN_SECRET", "unit-test-secret-at-least-32-bytes")
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
}
