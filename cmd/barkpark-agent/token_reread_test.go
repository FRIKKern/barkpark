package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// TestRun_FollowsTokenFileRewrittenMidCycle drives the real run() wiring: the
// control plane accepts token A for the report, then — as provisioning's
// supersede-mint does — rewrites agent.token to B and accepts only B. The
// command poll that follows in the SAME cycle must re-read the file and
// succeed. A read-once main 401s here and the --once cycle exits 1.
func TestRun_FollowsTokenFileRewrittenMidCycle(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.token")
	if err := os.WriteFile(path, []byte("token-A\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var (
		mu       sync.Mutex
		accepted = "token-A"
		polls    int
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path == "/v1/agent/commands" {
			polls++
		}
		if r.Header.Get("Authorization") != "Bearer "+accepted {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/v1/agent/report":
			// Supersede-mint: revoke A, rewrite the file to B.
			if err := os.WriteFile(path, []byte("token-B\n"), 0o600); err != nil {
				t.Error(err)
			}
			accepted = "token-B"
			w.WriteHeader(http.StatusOK)
		case "/v1/agent/commands":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte("[]"))
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()

	code := run([]string{
		"--control-url", srv.URL,
		"--token-file", path,
		"--once",
		"--checkout", dir,
		"--sites-dir", dir,
		"--consumer-roots", "none",
		"--backup-dir", "none",
		"--health-token-file", filepath.Join(dir, "absent.health.token"),
	})
	if code != 0 {
		t.Fatalf("run --once exit %d, want 0 — the agent did not follow the rewritten agent.token", code)
	}
	mu.Lock()
	defer mu.Unlock()
	if polls != 2 {
		t.Fatalf("command poll hit the server %d times, want 2 (the 401 + one replay with B)", polls)
	}
}
