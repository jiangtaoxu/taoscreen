package httpapi

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"taoscreen.local/server/internal/config"
)

const releaseOrigin = "https://releases.example.test:8443"

func TestReleaseVersions(t *testing.T) {
	for _, v := range []string{"1.0.0", "1.0.1101", "9999.9999.9999"} {
		if !releaseVersion.MatchString(v) {
			t.Fatal(v)
		}
	}
	for _, v := range []string{"1.0.10000", "1.0", "1.0.01", "1.0.-1", "1.2.3.4"} {
		if releaseVersion.MatchString(v) {
			t.Fatal(v)
		}
	}
	if compareVersions("1.0.1101", "1.0.99") != 1 || compareVersions("2.0.0", "1.9999.9999") != 1 || compareVersions("1.0.0", "1.0.0") != 0 {
		t.Fatal("版本数值比较错误")
	}
}
func TestReleaseURLBoundary(t *testing.T) {
	v := desktopRelease{Version: "1.0.1", Platform: "macos", Arch: "arm64", URL: releaseOrigin + "/macos/1.0.1/TaoScreen-1.0.1-arm64.dmg", SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Size: 10}
	if e := v.validate("arm64", releaseOrigin); e != nil {
		t.Fatal(e)
	}
	v.URL = strings.Replace(v.URL, "/TaoScreen-", "/TaoDesk-", 1)
	if v.validate("arm64", releaseOrigin) == nil {
		t.Fatal("接纳了旧产品的安装包")
	}
	v.URL = "https://evil.example/TaoScreen.dmg"
	if v.validate("arm64", releaseOrigin) == nil {
		t.Fatal("接纳了外部安装包")
	}
	s := &Server{}
	r := httptest.NewRequest("GET", "/v1/desktop/updates/latest?platform=macos&arch=arm64&current=1.0.10000", nil)
	if e := s.desktopUpdate(httptest.NewRecorder(), r); e == nil {
		t.Fatal("接纳了无效版本")
	}
}

type releaseTransport func(*http.Request) (*http.Response, error)

func (f releaseTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestUpdateEndpoint(t *testing.T) {
	previous := releaseHTTPClient
	defer func() { releaseHTTPClient = previous }()
	valid := `{"version":"1.0.1101","platform":"macos","arch":"arm64","url":"` + releaseOrigin + `/macos/1.0.1101/TaoScreen-1.0.1101-arm64.dmg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":100,"notes":"测试发布"}`
	for _, tc := range []struct {
		current, body string
		status, want  int
		available     bool
	}{
		{"1.0.99", valid, 200, 200, true}, {"1.0.1101", valid, 200, 200, false}, {"2.0.0", valid, 200, 200, false},
		{"1.0.0", "", 404, 404, false}, {"1.0.0", `{}`, 200, 503, false}, {"1.0.0", strings.ReplaceAll(valid, releaseOrigin, "https://evil.example"), 200, 503, false},
	} {
		releaseHTTPClient = &http.Client{Transport: releaseTransport(func(r *http.Request) (*http.Response, error) {
			if r.URL.String() != releaseOrigin+"/taoscreen-macos-arm64.json" {
				t.Fatal(r.URL)
			}
			return &http.Response{StatusCode: tc.status, Body: io.NopCloser(strings.NewReader(tc.body)), Header: make(http.Header)}, nil
		})}
		w := httptest.NewRecorder()
		s := &Server{Config: config.Config{DesktopReleaseOrigin: releaseOrigin}}
		s.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/v1/desktop/updates/latest?platform=macos&arch=arm64&current="+tc.current, nil))
		if w.Code != tc.want {
			t.Fatalf("%s: %d %s", tc.current, w.Code, w.Body.String())
		}
		if w.Code == 200 {
			var result struct {
				Available bool `json:"update_available"`
			}
			if e := json.Unmarshal(w.Body.Bytes(), &result); e != nil {
				t.Fatal(e)
			}
			if result.Available != tc.available {
				t.Fatal(w.Body.String())
			}
		}
	}
}

func TestUpdateEndpointWithoutReleaseOrigin(t *testing.T) {
	previous := releaseHTTPClient
	defer func() { releaseHTTPClient = previous }()
	releaseHTTPClient = &http.Client{Transport: releaseTransport(func(r *http.Request) (*http.Response, error) {
		t.Fatalf("未配置发布源时发起了外部请求：%s", r.URL)
		return nil, nil
	})}
	w := httptest.NewRecorder()
	s := &Server{}
	s.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/v1/desktop/updates/latest?platform=macos&arch=arm64&current=1.0.0", nil))
	if w.Code != 404 || !strings.Contains(w.Body.String(), "release_source_disabled") {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
}
