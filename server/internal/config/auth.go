package config

import (
	"encoding/base64"
	"errors"
	"net/mail"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
)

type OAuthClient struct{ ClientID, ClientSecret string }

func (c OAuthClient) Enabled() bool { return c.ClientID != "" }

type Auth struct {
	PublicURL                      string
	DesktopCallbackScheme          string
	PasswordLogin, SocialSignup    bool
	Google, GitHub                 OAuthClient
	AdminTeamDomain, AdminAudience string
	AdminEmails                    map[string]bool
	AdminMode                      string
	AdminTOTPDisabled              bool
	AdminOTPKey                    []byte
}

func (a Auth) AdminAccessEnabled() bool { return a.AdminMode == "cloudflare_access" }

var desktopCallbackScheme = regexp.MustCompile(`^[a-z][a-z0-9+.-]*$`)

func (a Auth) DesktopCallbackURL() string {
	if a.DesktopCallbackScheme == "" {
		return "taoscreen://auth/callback"
	}
	return a.DesktopCallbackScheme + "://auth/callback"
}

func loadAuth(env string) (Auth, error) {
	a := Auth{
		PublicURL:             strings.TrimRight(os.Getenv("AUTH_PUBLIC_URL"), "/"),
		DesktopCallbackScheme: os.Getenv("DESKTOP_OAUTH_CALLBACK_SCHEME"),
		Google:                OAuthClient{os.Getenv("GOOGLE_CLIENT_ID"), os.Getenv("GOOGLE_CLIENT_SECRET")},
		GitHub:                OAuthClient{os.Getenv("GITHUB_CLIENT_ID"), os.Getenv("GITHUB_CLIENT_SECRET")},
		AdminTeamDomain:       os.Getenv("ADMIN_ACCESS_TEAM_DOMAIN"), AdminAudience: os.Getenv("ADMIN_ACCESS_AUD"),
		AdminEmails: map[string]bool{}, AdminMode: os.Getenv("ADMIN_AUTH_MODE"),
	}
	if a.DesktopCallbackScheme != "" {
		if !desktopCallbackScheme.MatchString(a.DesktopCallbackScheme) {
			return a, errors.New("DESKTOP_OAUTH_CALLBACK_SCHEME 必须为小写应用 URL scheme，例如 taoscreen-local")
		}
		switch a.DesktopCallbackScheme {
		case "http", "https", "file", "data", "javascript", "mailto":
			return a, errors.New("DESKTOP_OAUTH_CALLBACK_SCHEME 必须为应用专用 URL scheme")
		}
	}
	for _, item := range []struct {
		name   string
		target *bool
	}{
		{"ALLOW_PASSWORD_LOGIN", &a.PasswordLogin}, {"ALLOW_SOCIAL_SIGNUP", &a.SocialSignup},
	} {
		raw := os.Getenv(item.name)
		if raw == "" {
			raw = "false"
		}
		value, err := strconv.ParseBool(raw)
		if err != nil {
			return a, errors.New(item.name + " 必须为 true 或 false")
		}
		*item.target = value
	}
	for _, client := range []OAuthClient{a.Google, a.GitHub} {
		if (client.ClientID == "") != (client.ClientSecret == "") {
			return a, errors.New("每个 OAuth 提供方必须同时配置 Client ID 和 Client Secret")
		}
		if strings.ContainsAny(client.ClientID, "\r\n\t ") {
			return a, errors.New("OAuth Client ID 无效")
		}
	}
	if a.PublicURL != "" {
		u, err := url.Parse(a.PublicURL)
		if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" ||
			!(u.Scheme == "https" || (env != "production" && u.Scheme == "http" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost"))) {
			return a, errors.New("AUTH_PUBLIC_URL 必须为服务端 HTTPS 根地址；非生产允许 localhost/127.0.0.1 HTTP")
		}
	}
	if (a.Google.Enabled() || a.GitHub.Enabled()) && a.PublicURL == "" {
		return a, errors.New("启用 Google/GitHub 必须配置 AUTH_PUBLIC_URL")
	}
	rawEmails := os.Getenv("ADMIN_ALLOWED_EMAILS")
	accessConfigured := a.AdminTeamDomain != "" || a.AdminAudience != "" || rawEmails != ""
	if a.AdminMode == "" {
		a.AdminMode = "disabled"
		if accessConfigured {
			a.AdminMode = "cloudflare_access"
		}
	}
	switch a.AdminMode {
	case "disabled":
	case "local":
		if accessConfigured {
			return a, errors.New("启用本地管理后台时请移除 Cloudflare Access 管理员配置")
		}
		switch os.Getenv("ADMIN_TOTP_ENABLED") {
		case "", "true":
			key, err := base64.StdEncoding.Strict().DecodeString(os.Getenv("ADMIN_TOTP_KEY"))
			if err != nil || len(key) != 32 {
				return a, errors.New("ADMIN_TOTP_KEY 必须是 32 字节随机密钥的 Base64 编码")
			}
			a.AdminOTPKey = key
		case "false":
			a.AdminTOTPDisabled = true
		default:
			return a, errors.New("ADMIN_TOTP_ENABLED 必须为 true 或 false")
		}
	case "cloudflare_access":
	default:
		return a, errors.New("ADMIN_AUTH_MODE 必须为 disabled、local 或 cloudflare_access")
	}
	if env == "production" && (a.PasswordLogin || a.AdminMode == "local") && a.PublicURL == "" {
		return a, errors.New("生产环境使用本地账号时必须配置 HTTPS 的 AUTH_PUBLIC_URL")
	}
	if a.AdminMode == "cloudflare_access" {
		u, err := url.Parse("https://" + a.AdminTeamDomain)
		if err != nil || u.Hostname() != a.AdminTeamDomain || !strings.HasSuffix(a.AdminTeamDomain, ".cloudflareaccess.com") ||
			u.Port() != "" || u.User != nil || u.Path != "" || a.AdminAudience == "" || strings.ContainsAny(a.AdminAudience, "\r\n\t ,") {
			return a, errors.New("请完整配置管理员专用 Cloudflare Access 团队域名、AUD 和邮箱白名单")
		}
		for _, value := range strings.Split(rawEmails, ",") {
			value = strings.ToLower(strings.TrimSpace(value))
			parsed, err := mail.ParseAddress(value)
			if err != nil || parsed.Address != value {
				return a, errors.New("ADMIN_ALLOWED_EMAILS 必须是明确的管理员邮箱列表")
			}
			a.AdminEmails[value] = true
		}
		if len(a.AdminEmails) == 0 {
			return a, errors.New("必须指定 ADMIN_ALLOWED_EMAILS")
		}
	}
	return a, nil
}
