package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// THE CLAIM AND PULSE DOORS CARRY THE SESSION KEY (task-9af836a40731b63a).
// `bp task claim` / `bp task pulse` send X-Barkpark-Session through
// buildManifestRequest, and the server stamps claim.session + session_origin
// (claim) or claim.session (pulse) from it. The TUI, the board and the cmux
// hook claim and pulse through apiclient.TaskClaimN / TaskPulse instead, which
// sent no key — so those rows carried no session_origin. These tests drive the
// REAL client construction of each surface and require the key to equal the
// manifest path's sessionKey(), with the session-DOC header absent (the server
// auto-logs only close and publish).

type leaseRecorder struct {
	mu      sync.Mutex
	headers map[string][]http.Header // "claim" / "pulse" -> headers
}

func (r *leaseRecorder) server(t *testing.T) *httptest.Server {
	t.Helper()
	r.headers = map[string][]http.Header{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		for _, door := range []string{"claim", "pulse"} {
			if req.Method == http.MethodPost && strings.HasSuffix(req.URL.Path, "/"+door) {
				r.mu.Lock()
				r.headers[door] = append(r.headers[door], req.Header.Clone())
				r.mu.Unlock()
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":2}}}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func claimAndPulse(t *testing.T, c *apiclient.Client) {
	t.Helper()
	if _, _, _, err := c.TaskClaimN("task-9af836a40731b63a", "lead-cli"); err != nil {
		t.Fatalf("claim: %v", err)
	}
	if _, _, err := c.TaskPulse("task-9af836a40731b63a", "lead-cli", "now"); err != nil {
		t.Fatalf("pulse: %v", err)
	}
}

func assertKeyNotDoc(t *testing.T, what string, rec *leaseRecorder, doors ...string) {
	t.Helper()
	rec.mu.Lock()
	defer rec.mu.Unlock()
	for _, door := range doors {
		hs := rec.headers[door]
		if len(hs) != 1 {
			t.Fatalf("%s: recorded %d %s requests, want 1", what, len(hs), door)
		}
		h := hs[0]
		if got := h.Get("X-Barkpark-Session"); got == "" || got != sessionKey() {
			t.Errorf("%s %s: X-Barkpark-Session = %q, want the manifest path's session key %q", what, door, got, sessionKey())
		}
		if v, ok := h["X-Barkpark-Session-Doc"]; ok {
			t.Errorf("%s %s: X-Barkpark-Session-Doc = %q; only close and publish carry it", what, door, v)
		}
	}
}

// The TUI's client (ResolvedAPIConfig) — a session IS bound, so the doc header
// being absent is the scope rule, not an unbound session.
func TestTUIClaimAndPulseCarrySessionKey(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-2026-09-24-tui")
	rec := &leaseRecorder{}
	cfg := ResolvedAPIConfig()
	cfg.BaseURL = rec.server(t).URL
	claimAndPulse(t, apiclient.New(cfg))
	assertKeyNotDoc(t, "tui", rec, "claim", "pulse")
}

// The cmux hook's client: SessionStart claims, PreToolUse pulses.
func TestHookClaimAndPulseCarrySessionKey(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-2026-09-24-hook")
	rec := &leaseRecorder{}
	ctx := ambientCtx()
	ctx.Server = rec.server(t).URL
	claimAndPulse(t, newHookClient(globals{}, ctx))
	assertKeyNotDoc(t, "hook", rec, "claim", "pulse")
}

// `bp task next <worker> --frontier` claims through TaskClaimResources on a
// client it builds itself; bare `bp task next` sends the key through the
// manifest path, so the frontier variant must too.
func TestNextFrontierClaimCarriesSessionKey(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-2026-09-24-next")
	captured := map[string]*capturedClaim{}
	srv := nextFrontierServer(t, map[string]claimReply{
		"task-a": {body: `{"ok":true,"doc":{"claim":{"epoch":7}}}`},
	}, captured)
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := dispatchCtx(srv.URL)
	ctx.AmbientCredentialsOK = true
	if code := runTaskNextFrontierArgs(w, ctx, []string{"worker-1", "--frontier"}); code != exitOK {
		t.Fatalf("exit = %d\nstderr=%s", code, se.String())
	}
	c := captured["task-a"]
	if c == nil {
		t.Fatal("no claim recorded for task-a")
	}
	if c.session == "" || c.session != sessionKey() {
		t.Errorf("next --frontier claim: X-Barkpark-Session = %q, want %q", c.session, sessionKey())
	}
	if c.sessionDocSent {
		t.Error("next --frontier claim: X-Barkpark-Session-Doc sent; only close and publish carry it")
	}
}
