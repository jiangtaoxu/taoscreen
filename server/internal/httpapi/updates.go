package httpapi

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var releaseHTTPClient = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}

var releaseVersion = regexp.MustCompile(`^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$`)
var releaseHash = regexp.MustCompile(`^[a-f0-9]{64}$`)

type desktopRelease struct {
	Version  string `json:"version"`
	Platform string `json:"platform"`
	Arch     string `json:"arch"`
	URL      string `json:"url"`
	SHA256   string `json:"sha256"`
	Size     int64  `json:"size"`
	Notes    string `json:"notes"`
}

func compareVersions(a, b string) int {
	aa, bb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < 3; i++ {
		x, _ := strconv.Atoi(aa[i])
		y, _ := strconv.Atoi(bb[i])
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
	}
	return 0
}
func (v desktopRelease) validate(arch, origin string) error {
	u, e := url.Parse(v.URL)
	if !releaseVersion.MatchString(v.Version) || v.Platform != "macos" || v.Arch != arch || !releaseHash.MatchString(v.SHA256) || v.Size <= 0 || v.Size > 2<<30 || len(v.Notes) > 16000 {
		return fmt.Errorf("发布信息字段无效")
	}
	if e != nil || u.Scheme+"://"+u.Host != origin || u.User != nil || strings.ContainsAny(v.URL, "?#") || u.EscapedPath() != "/macos/"+v.Version+"/TaoScreen-"+v.Version+"-"+arch+".dmg" {
		return fmt.Errorf("安装包地址无效")
	}
	return nil
}
func (s *Server) desktopUpdate(w http.ResponseWriter, r *http.Request) error {
	current, arch := r.URL.Query().Get("current"), r.URL.Query().Get("arch")
	if !releaseVersion.MatchString(current) || r.URL.Query().Get("platform") != "macos" || (arch != "arm64" && arch != "x86_64") {
		return invalid("必须指定 macos、arm64/x86_64 和三段版本号，每段 0–9999，不含前导零")
	}
	origin := s.Config.DesktopReleaseOrigin
	if origin == "" {
		return problem(404, "release_source_disabled", "此实例未配置桌面安装包发布源")
	}
	req, e := http.NewRequestWithContext(r.Context(), "GET", origin+"/taoscreen-macos-"+arch+".json", nil)
	if e != nil {
		return e
	}
	req.Header.Set("Cache-Control", "no-cache")
	client := releaseHTTPClient
	res, e := client.Do(req)
	if e != nil {
		return e
	}
	defer res.Body.Close()
	if res.StatusCode == 404 {
		return problem(404, "release_not_published", "尚未发布此架构的安装包")
	}
	if res.StatusCode != 200 {
		return fmt.Errorf("发布源返回 %d", res.StatusCode)
	}
	data, e := io.ReadAll(io.LimitReader(res.Body, 65537))
	if e != nil {
		return e
	}
	if len(data) > 65536 {
		return fmt.Errorf("发布信息过大")
	}
	var v desktopRelease
	if e = json.Unmarshal(data, &v); e != nil {
		return e
	}
	if e = v.validate(arch, origin); e != nil {
		return e
	}
	return jsonReply(w, 200, map[string]any{"update_available": compareVersions(v.Version, current) > 0, "release": v})
}
