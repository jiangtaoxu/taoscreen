package httpapi

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

func TestDownloadPagePublicAndIsolated(t *testing.T) {
	// 无账号、数据库和 Redis 也应能访问公开下载页。
	handler := (&Server{}).Handler()
	var previousNonce string
	for i := 0; i < 2; i++ {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/download", nil))
		if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "text/html; charset=utf-8" {
			t.Fatalf("公开下载页不可用：%d %s", w.Code, w.Body.String())
		}
		body := w.Body.String()
		if !strings.Contains(body, "下载 TaoScreen ·") || !strings.Contains(body, "TAOSCREEN FOR MAC") ||
			!strings.Contains(body, "下载 macOS 客户端") || strings.Contains(body, "{{nonce}}") {
			t.Fatal("下载页内容不完整")
		}
		match := regexp.MustCompile(`script-src 'nonce-([^']+)'`).FindStringSubmatch(w.Header().Get("Content-Security-Policy"))
		if len(match) != 2 || match[1] == previousNonce {
			t.Fatal("应为每次请求生成独立 CSP nonce")
		}
		previousNonce = match[1]
		if strings.Count(body, `nonce="`+match[1]+`"`) != 2 || w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("页面样式和脚本必须受 CSP 保护，且禁止缓存")
		}
	}
	for _, tc := range []struct {
		method, path string
		want         int
	}{
		{http.MethodHead, "/download", http.StatusOK},
		{http.MethodGet, "/download/", http.StatusMovedPermanently},
		{http.MethodGet, "/download/other", http.StatusNotFound},
		{http.MethodPost, "/download", http.StatusMethodNotAllowed},
		{http.MethodGet, "/v1/admin/me", http.StatusServiceUnavailable},
	} {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.want {
			t.Fatalf("%s %s：得到 %d，期望 %d", tc.method, tc.path, w.Code, tc.want)
		}
		if tc.path == "/download/" && w.Header().Get("Location") != "/download" {
			t.Fatal("带末尾斜杠的入口未跳转到下载页")
		}
	}
}

func TestDownloadPageLanguagePreference(t *testing.T) {
	handler := (&Server{}).Handler()
	get := func(path, acceptLanguage, locale string, cookie *http.Cookie) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Accept-Language", acceptLanguage)
		if cookie != nil {
			request.AddCookie(cookie)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		result := response.Header()
		if response.Code != http.StatusOK || result.Get("Content-Language") != locale ||
			!strings.Contains(response.Body.String(), `<html lang="`+locale+`">`) {
			t.Fatalf("下载页语言应为 %s，HTTP %d，Content-Language %s", locale, response.Code, result.Get("Content-Language"))
		}
		return response
	}

	get("/download", "fr-FR, zh-TW;q=0.8, en;q=0.7", "zh-Hans", nil)
	english := get("/download?lang=en", "zh-CN", "en", nil)
	if !strings.Contains(english.Body.String(), "Download for macOS") {
		t.Fatal("英文下载页未渲染英文文案")
	}
	prefs := english.Result().Cookies()
	if len(prefs) != 1 || prefs[0].Name != webLanguageCookie || prefs[0].Value != "en" {
		t.Fatal("手动选择英文后应保存语言")
	}
	get("/download", "zh-CN", "en", prefs[0])
	reset := get("/download?lang=system", "zh-TW", "zh-Hans", prefs[0]).Result().Cookies()
	if len(reset) != 1 || reset[0].MaxAge >= 0 {
		t.Fatal("恢复跟随系统时应清除语言选项")
	}
	get("/download", "ja-JP", "en", nil)
}
