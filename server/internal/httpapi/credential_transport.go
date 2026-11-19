package httpapi

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// credentialTransport reports HTTPS, including TLS terminated by a configured reverse proxy.
func (s *Server) credentialTransport(r *http.Request) (bool, error) {
	if r.TLS != nil {
		return true, nil
	}
	peer, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip, err := netip.ParseAddr(peer); err == nil {
		for _, prefix := range s.Config.TrustedProxies {
			if proto := r.Header.Values("X-Forwarded-Proto"); prefix.Contains(ip.Unmap()) && len(proto) == 1 && proto[0] == "https" {
				return true, nil
			}
		}
	}
	if s.Config.Env == "production" {
		return false, problem(http.StatusForbidden, "https_required", "此登录方式需要 HTTPS")
	}
	host := r.Host
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	host = strings.TrimPrefix(strings.TrimSuffix(host, "]"), "[")
	ip, _ := netip.ParseAddr(host)
	if strings.EqualFold(host, "localhost") || ip.IsLoopback() {
		return false, nil
	}
	return false, problem(http.StatusForbidden, "https_required", "此登录方式需要 HTTPS")
}
