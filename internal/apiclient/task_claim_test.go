package apiclient

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TaskClaim must return the claim's fencing epoch — the token TaskClose echoes
// back as observed_epoch. Epochs start at 1, so a malformed ok-envelope that
// carries no epoch (0) is NOT a real claim: proceeding with epoch 0 silently
// defeats the CAS-on-epoch fencing the whole bp task workflow depends on.
func TestTaskClaimRejectsMissingEpoch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/claim") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		// An ok envelope with an empty doc — no fencing epoch.
		_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	epoch, err := c.TaskClaim("task-7", "worker-a")
	if err == nil {
		t.Fatalf("expected an error for a claim with no fencing epoch, got nil (epoch=%d)", epoch)
	}
	if epoch != 0 {
		t.Errorf("epoch = %d, want 0 on failure", epoch)
	}
}

func TestTaskClaimReturnsEpoch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/claim") {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":2}}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	epoch, err := c.TaskClaim("task-7", "worker-a")
	if err != nil {
		t.Fatalf("TaskClaim: %v", err)
	}
	if epoch != 2 {
		t.Errorf("epoch = %d, want 2", epoch)
	}
}
