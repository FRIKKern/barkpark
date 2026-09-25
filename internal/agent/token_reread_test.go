package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/tokensource"
)

// supersedeCP accepts exactly one agent bearer at a time (a supersede-mint
// revokes the old one), counts every report POST, and answers an empty
// command queue to an authorised poll.
type supersedeCP struct {
	mu       sync.Mutex
	accepted string
	reports  atomic.Int64
}

func (c *supersedeCP) accept(tok string) { c.mu.Lock(); c.accepted = tok; c.mu.Unlock() }

func (c *supersedeCP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == reportPath {
		c.reports.Add(1)
	}
	c.mu.Lock()
	ok := r.Header.Get("Authorization") == "Bearer "+c.accepted
	c.mu.Unlock()
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.URL.Path == commandsPath {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("[]"))
		return
	}
	w.WriteHeader(http.StatusOK)
}

func writeAgentToken(t *testing.T, path, tok string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// Provisioning supersede-mints agent.token under a LIVE agent. The agent —
// same process, no restart — must follow the rewritten --token-file, and must
// not hot-loop while the file still holds the revoked token.
func TestSupersedeMint_AgentFollowsRewrittenTokenFile(t *testing.T) {
	cp := &supersedeCP{}
	cp.accept("token-A")
	srv := httptest.NewServer(cp)
	defer srv.Close()

	path := filepath.Join(t.TempDir(), "agent.token")
	writeAgentToken(t, path, "token-A")
	src, err := tokensource.FromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	a := &Agent{ControlURL: srv.URL, HTTPClient: srv.Client(), TokenSource: src, Runner: &fakeRunner{}}

	// 1. Healthy on A.
	if err := a.RunOnce(context.Background()); err != nil {
		t.Fatalf("cycle on token A: %v", err)
	}

	// 2. The control plane revokes A; the file is not rewritten yet. Each
	//    cycle fails with exactly ONE report attempt — bounded, not a loop.
	cp.accept("token-B")
	for i := 0; i < 3; i++ {
		before := cp.reports.Load()
		if err := a.RunOnce(context.Background()); err == nil {
			t.Fatalf("cycle %d with revoked token and unchanged file: want a 401 error, got nil", i)
		}
		if n := cp.reports.Load() - before; n != 1 {
			t.Fatalf("cycle %d made %d report attempts on an unchanged file, want 1 (no retry)", i, n)
		}
	}

	// 3. Provisioning rewrites agent.token to B. The very next cycle recovers.
	writeAgentToken(t, path, "token-B")
	before := cp.reports.Load()
	if err := a.RunOnce(context.Background()); err != nil {
		t.Fatalf("cycle after agent.token rewrite: %v — the agent is stranded until restart", err)
	}
	if n := cp.reports.Load() - before; n != 2 {
		t.Fatalf("recovery made %d report attempts, want 2 (the 401 + one replay)", n)
	}

	// 4. Steady state on B: one report per cycle.
	before = cp.reports.Load()
	if err := a.RunOnce(context.Background()); err != nil {
		t.Fatalf("steady-state cycle on B: %v", err)
	}
	if n := cp.reports.Load() - before; n != 1 {
		t.Fatalf("steady-state cycle made %d report attempts, want 1", n)
	}
}
