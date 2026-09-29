package runtime

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

// supersedeCP is a control plane that accepts exactly one bearer at a time
// (a supersede-mint revokes the old one) and answers an empty queue (404) to
// an authorised claim.
type supersedeCP struct {
	mu       sync.Mutex
	accepted string
	claims   atomic.Int64
}

func (c *supersedeCP) accept(tok string) { c.mu.Lock(); c.accepted = tok; c.mu.Unlock() }

func (c *supersedeCP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == claimPath {
		c.claims.Add(1)
	}
	c.mu.Lock()
	ok := r.Header.Get("Authorization") == "Bearer "+c.accepted
	c.mu.Unlock()
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	http.NotFound(w, r) // empty queue
}

func writeAgentToken(t *testing.T, path, tok string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// jpf-bl-box-credential-hygiene criterion 1: provisioning supersede-mints
// agent.token under a LIVE daemon. The daemon — same process, no restart —
// must follow the rewritten --token-file, and must not hot-loop while the
// file still holds the revoked token.
func TestSupersedeMint_DaemonFollowsRewrittenTokenFile(t *testing.T) {
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
	d := &Executor{ControlURL: srv.URL, WorkerID: "agent-1", HTTPClient: srv.Client(), TokenSource: src, Runner: &fakeRunner{}, FS: newMapFS(), Ports: &fixedPorts{next: 7001}}

	// 1. Healthy on A.
	if _, err := d.RunOnce(context.Background(), State{}); err != nil {
		t.Fatalf("cycle on token A: %v", err)
	}

	// 2. The control plane revokes A; the file is not rewritten yet. Each
	//    cycle fails with exactly ONE claim attempt — bounded, not a loop.
	cp.accept("token-B")
	for i := 0; i < 3; i++ {
		before := cp.claims.Load()
		if _, err := d.RunOnce(context.Background(), State{}); err == nil {
			t.Fatalf("cycle %d with revoked token and unchanged file: want a 401 error, got nil", i)
		}
		if n := cp.claims.Load() - before; n != 1 {
			t.Fatalf("cycle %d made %d claim attempts on an unchanged file, want 1 (no retry)", i, n)
		}
	}

	// 3. Provisioning rewrites agent.token to B. The very next cycle recovers.
	writeAgentToken(t, path, "token-B")
	before := cp.claims.Load()
	if _, err := d.RunOnce(context.Background(), State{}); err != nil {
		t.Fatalf("cycle after agent.token rewrite: %v — the daemon is stranded until restart", err)
	}
	if n := cp.claims.Load() - before; n != 2 {
		t.Fatalf("recovery made %d claim attempts, want 2 (the 401 + one replay)", n)
	}

	// 4. Steady state on B: one claim per cycle.
	before = cp.claims.Load()
	if _, err := d.RunOnce(context.Background(), State{}); err != nil {
		t.Fatalf("steady-state cycle on B: %v", err)
	}
	if n := cp.claims.Load() - before; n != 1 {
		t.Fatalf("steady-state cycle made %d claim attempts, want 1", n)
	}
}
