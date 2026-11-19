package config

import (
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Auth                                                Auth
	Env, Addr, DatabaseURL, RedisURL                    string
	DesktopSTUNURLs, DesktopTURNURLs, DesktopTURNSecret string
	DesktopReleaseOrigin                                string
	Registration                                        bool
	TrustedProxies, CloudflareProxies                   []netip.Prefix
}

func Load() (Config, error) {
	c := Config{
		Env: os.Getenv("APP_ENV"), Addr: os.Getenv("HTTP_ADDR"),
		DatabaseURL: os.Getenv("DATABASE_URL"), RedisURL: os.Getenv("REDIS_URL"),
		DesktopSTUNURLs:   os.Getenv("DESKTOP_STUN_URLS"),
		DesktopTURNURLs:   os.Getenv("DESKTOP_TURN_URLS"),
		DesktopTURNSecret: os.Getenv("DESKTOP_TURN_SECRET"),
	}
	if c.Env != "development" && c.Env != "test" && c.Env != "production" {
		return c, errors.New("APP_ENV 必须为 development、test 或 production")
	}
	if c.Addr == "" {
		c.Addr = ":8080"
	}
	if origin := os.Getenv("DESKTOP_RELEASE_ORIGIN"); origin != "" {
		u, err := url.Parse(origin)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil ||
			(u.EscapedPath() != "" && u.EscapedPath() != "/") || strings.ContainsAny(origin, "?#") {
			return c, errors.New("DESKTOP_RELEASE_ORIGIN 必须为 HTTPS 根地址")
		}
		c.DesktopReleaseOrigin = "https://" + u.Host
	}
	if c.DatabaseURL == "" || c.RedisURL == "" {
		return c, errors.New("必须配置独立的 DATABASE_URL 和 REDIS_URL")
	}
	db, err := url.Parse(c.DatabaseURL)
	if err != nil || (db.Scheme != "postgres" && db.Scheme != "postgresql") || db.Host == "" || db.Path == "" || db.Path == "/" {
		return c, errors.New("DATABASE_URL 必须指定独立 PostgreSQL 数据库")
	}
	if (c.DesktopTURNURLs == "") != (c.DesktopTURNSecret == "") || (c.DesktopTURNSecret != "" && len(c.DesktopTURNSecret) < 32) {
		return c, errors.New("DESKTOP_TURN_URLS 与至少 32 字节的 DESKTOP_TURN_SECRET 必须同时配置")
	}
	for _, group := range []struct {
		raw     string
		schemes []string
	}{
		{c.DesktopSTUNURLs, []string{"stun:", "stuns:"}},
		{c.DesktopTURNURLs, []string{"turn:", "turns:"}},
	} {
		for _, value := range strings.Split(group.raw, ",") {
			value = strings.TrimSpace(value)
			if value == "" {
				continue
			}
			valid := false
			for _, scheme := range group.schemes {
				if strings.HasPrefix(value, scheme) && len(value) > len(scheme) {
					valid = true
				}
			}
			if !valid || strings.ContainsAny(value, "\r\n @") {
				return c, errors.New("远程桌面 ICE 服务地址无效")
			}
		}
	}
	c.Registration, err = strconv.ParseBool(os.Getenv("ALLOW_REGISTRATION"))
	if err != nil {
		return c, errors.New("必须明确配置 ALLOW_REGISTRATION=true 或 false")
	}
	if c.Env == "production" && c.Registration {
		return c, errors.New("生产环境请关闭自助注册，使用 create-user 创建独立账号")
	}
	c.Auth, err = loadAuth(c.Env)
	if err != nil {
		return c, err
	}
	for _, group := range []struct {
		name   string
		target *[]netip.Prefix
	}{
		{"TRUSTED_PROXY_CIDRS", &c.TrustedProxies}, {"CLOUDFLARE_PROXY_CIDRS", &c.CloudflareProxies},
	} {
		for _, raw := range strings.Split(os.Getenv(group.name), ",") {
			if strings.TrimSpace(raw) == "" {
				continue
			}
			p, err := netip.ParsePrefix(strings.TrimSpace(raw))
			if err != nil || p.Bits() == 0 {
				return c, fmt.Errorf("%s 必须是明确的代理网段，不能为全网地址", group.name)
			}
			*group.target = append(*group.target, p)
		}
	}
	return c, nil
}
