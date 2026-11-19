package httpapi

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

func TestDesktopAuthorization(t *testing.T) {
	viewer, host, outsider := uuid.NewString(), uuid.NewString(), uuid.NewString()
	id := uuid.NewString()
	for _, tc := range []struct {
		kind, from, to  string
		accepted, valid bool
	}{
		{"accept", host, viewer, false, true}, {"reject", host, viewer, false, true},
		{"accept", viewer, host, false, false}, {"accept", host, viewer, true, false},
		{"offer", viewer, host, false, false}, {"answer", host, viewer, false, false},
		{"candidate", viewer, host, false, false},
		{"resume", viewer, host, false, false}, {"resume", viewer, host, true, true},
		{"resume", host, viewer, true, true}, {"resume", outsider, host, true, false},
		{"keepalive", viewer, host, false, false}, {"keepalive", host, viewer, false, false},
		{"keepalive", viewer, host, true, true}, {"keepalive", host, viewer, true, true},
		{"keepalive", outsider, host, true, false}, {"keepalive", viewer, outsider, true, false},
		{"resumed", host, viewer, true, false}, {"session_revoked", host, viewer, true, false},
		{"offer", viewer, host, true, true}, {"answer", host, viewer, true, true},
		{"offer", host, viewer, true, false}, {"answer", viewer, host, true, false},
		{"candidate", host, viewer, true, true}, {"candidate", viewer, host, true, true},
		{"end", viewer, host, false, true}, {"end", host, viewer, true, true},
		{"end", outsider, host, true, false}, {"candidate", viewer, outsider, true, false},
		{"unknown", host, viewer, true, false},
	} {
		t.Run(tc.kind+tc.from+tc.to, func(t *testing.T) {
			m := desktopMessage{Type: tc.kind, ID: id, To: tc.to}
			err := validateDesktopMessage(m, tc.from, &desktopSession{Viewer: viewer, Host: host, Accepted: tc.accepted})
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v, error=%v", tc.valid, err)
			}
		})
	}
	for _, m := range []desktopMessage{
		{Type: "invite", ID: "invalid", To: host},
		{Type: "invite", ID: id, To: viewer},
		{Type: "invite", ID: id, To: host, Payload: json.RawMessage(strings.Repeat("x", 61*1024))},
	} {
		if validateDesktopMessage(m, viewer, nil) == nil {
			t.Fatal("malformed invitation accepted")
		}
	}
}

func TestPeerHeartbeatRequiresPongBeforeRenewingLease(t *testing.T) {
	for _, tc := range []struct {
		name            string
		pong, failRenew bool
	}{
		{"healthy", true, false}, {"half_open", false, false}, {"lease_lost", true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			type result struct {
				err     error
				renewed bool
			}
			results := make(chan result, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := websocket.Accept(w, r, nil)
				if err != nil {
					results <- result{err: err}
					return
				}
				defer conn.CloseNow()
				renewed := false
				err = peerHeartbeat(conn.CloseRead(r.Context()), conn, 200*time.Millisecond, func(context.Context) error {
					renewed = true
					if tc.failRenew {
						return errors.New("lease lost")
					}
					return nil
				})
				results <- result{err, renewed}
			}))
			defer server.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			client, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer client.CloseNow()
			if tc.pong {
				client.CloseRead(ctx)
			}
			select {
			case result := <-results:
				if result.renewed != tc.pong || (result.err == nil) != (tc.pong && !tc.failRenew) {
					t.Fatalf("renewed=%v error=%v", result.renewed, result.err)
				}
			case <-ctx.Done():
				t.Fatal("heartbeat did not finish")
			}
		})
	}
}

func TestTURNTemporaryCredentials(t *testing.T) {
	secret := "test-only-secret-at-least-32-bytes"
	expiry := time.Unix(2000000000, 0)
	username, password := turnCredentials(secret, "device-id", expiry)
	if username != "2000000000:device-id" {
		t.Fatal("invalid expiry / identity")
	}
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	decoded, err := base64.StdEncoding.DecodeString(password)
	if err != nil || !hmac.Equal(decoded, mac.Sum(nil)) {
		t.Fatal("coturn credential verification failed")
	}
	_, other := turnCredentials(secret, "other-device", expiry)
	if password == other || password == secret {
		t.Fatal("credential not scoped")
	}
}
