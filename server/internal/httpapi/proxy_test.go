package httpapi

import (
	"net/http/httptest"
	"net/netip"
	"testing"

	"taoscreen.local/server/internal/config"
)

func TestClientIPProxyTrust(t *testing.T) {
	s := &Server{Config: config.Config{
		TrustedProxies:    []netip.Prefix{netip.MustParsePrefix("10.0.1.7/32")},
		CloudflareProxies: []netip.Prefix{netip.MustParsePrefix("173.245.48.0/20")},
	}}
	for _, tc := range []struct {
		name, remote, forwarded, cloudflare, want string
	}{
		{"代理记录真实来源", "10.0.1.7:1234", "198.51.100.1", "", "198.51.100.1"},
		{"Cloudflare真实来源", "10.0.1.7:1234", "173.245.48.1", "198.51.100.2", "198.51.100.2"},
		{"CloudflareIPv6客户端", "10.0.1.7:1234", "173.245.48.1", "2001:db8::2", "2001:db8::2"},
		{"源站直连伪造头", "198.51.100.3:1234", "173.245.48.1", "198.51.100.2", "198.51.100.3"},
		{"非Cloudflare来源伪造头", "10.0.1.7:1234", "198.51.100.3", "198.51.100.2", "198.51.100.3"},
		{"伪造链左端Cloudflare", "10.0.1.7:1234", "173.245.48.1, 198.51.100.3", "198.51.100.2", "198.51.100.3"},
		{"无Cloudflare客户端头", "10.0.1.7:1234", "173.245.48.1", "", "173.245.48.1"},
		{"无效Cloudflare客户端头", "10.0.1.7:1234", "173.245.48.1", "198.51.100.2, 198.51.100.3", "173.245.48.1"},
		{"无可信来源链", "10.0.1.7:1234", "", "198.51.100.2", "10.0.1.7"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "/", nil)
			r.RemoteAddr = tc.remote
			r.Header.Set("X-Forwarded-For", tc.forwarded)
			r.Header.Set("CF-Connecting-IP", tc.cloudflare)
			if got := s.clientIP(r); got != tc.want {
				t.Fatalf("clientIP = %q, want %q", got, tc.want)
			}
		})
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.1.7:1234"
	r.Header.Set("X-Forwarded-For", "173.245.48.1")
	r.Header.Add("CF-Connecting-IP", "198.51.100.1")
	r.Header.Add("CF-Connecting-IP", "198.51.100.2")
	if got := s.clientIP(r); got != "173.245.48.1" {
		t.Fatalf("重复头被错误信任：%s", got)
	}
	s.Config.CloudflareProxies = nil
	r.Header.Set("CF-Connecting-IP", "198.51.100.1")
	if got := s.clientIP(r); got != "173.245.48.1" {
		t.Fatalf("未启用 Cloudflare 时改变了行为：%s", got)
	}
}
