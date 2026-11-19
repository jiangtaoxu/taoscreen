package httpapi

import (
	"net/http/httptest"
	"taoscreen.local/server/internal/config"
	"testing"
)

func TestStandaloneRoutesExcludeOtherBerthModules(t *testing.T) {
	handler := New(config.Config{}, nil, nil).Handler()
	for _, path := range []string{"/v1/events", "/v1/sync/pull", "/v1/music/config", "/v1/mirror/config", "/v1/remote/config", "/v1/peers", "/v1/auth/access/start"} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest("GET", path, nil))
		if recorder.Code != 404 {
			t.Fatalf("%s 不应进入独立服务，实际 %d", path, recorder.Code)
		}
	}
}

func TestPasswordsRemainHashedAndValidated(t *testing.T) {
	if _, err := HashPassword("short"); err == nil {
		t.Fatal("不能接受短密码")
	}
	password := "taoscreen-unit-test-only-123!"
	hash, err := HashPassword(password)
	if err != nil {
		t.Fatal(err)
	}
	if hash == password || !checkPassword(password, hash) || checkPassword("wrong-password-123!", hash) {
		t.Fatal("独立密码校验失败")
	}
}
