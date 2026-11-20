package chathost

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestEnrollRefusalSaysWhatToDo: a refused enroll is the server's reason and
// sentence, not "chat host credential revoked" (which reads as a dead machine).
func TestEnrollRefusalSaysWhatToDo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"code":"invalid_enrollment","message":"A newer code replaced this one. Run enroll again with the newest code for this machine.","details":{"reason":"replaced"}}}`))
	}))
	defer srv.Close()

	client := &Client{BaseURL: srv.URL, AllowInsecureLoopback: true}
	_, err := client.Enroll(context.Background(), "old-code", []string{"/srv/bot"}, map[string]any{})

	var refused *EnrollRefusedError
	if !errors.As(err, &refused) {
		t.Fatalf("Enroll error = %v (%T); want *EnrollRefusedError", err, err)
	}
	if errors.Is(err, ErrRevoked) {
		t.Fatal("a refused code must not read as a revoked credential")
	}
	if refused.Reason != "replaced" || !strings.Contains(err.Error(), "newest code") {
		t.Fatalf("refusal = %+v, message %q", refused, err.Error())
	}
	if Transient(err) {
		t.Fatal("a refused code is final, not a retry")
	}
}

// TestEnrollRefusalFromAnOlderServer: no details, the old message: the host
// still says what to do.
func TestEnrollRefusalFromAnOlderServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"code":"invalid_enrollment","message":"enrollment token is invalid or expired"}}`))
	}))
	defer srv.Close()

	client := &Client{BaseURL: srv.URL, AllowInsecureLoopback: true}
	_, err := client.Enroll(context.Background(), "x", []string{"/srv/bot"}, map[string]any{})
	if err == nil || !strings.Contains(err.Error(), "ask the workspace owner for a new code") {
		t.Fatalf("err = %v", err)
	}
}
