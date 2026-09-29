package cli

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// THE BOARD/TUI CLOSE DOOR CARRIES THE SESSION HEADERS
// (task-e4cbf4cd9f672c33). `bp task close` sends X-Barkpark-Session (the
// secret claim-session key) and, when a session is bound, X-Barkpark-Session-Doc
// through buildManifestRequest. The TUI (ResolvedAPIConfig), the board
// (runTasksBoard → taskboard.Run) and the cmux Stop hook (newHookClient) close
// through apiclient.TaskCloseN / TaskCloseRevN instead, which sent NEITHER — so
// the server stamped no claim.closed_session and never auto-logged the close to
// the bound session. These tests drive the REAL client construction each of
// those surfaces uses against a recording server.

type closeRecorder struct {
	mu      sync.Mutex
	headers []http.Header
}

func (r *closeRecorder) server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodPost && strings.HasSuffix(req.URL.Path, "/close") {
			r.mu.Lock()
			r.headers = append(r.headers, req.Header.Clone())
			r.mu.Unlock()
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func (r *closeRecorder) only(t *testing.T) http.Header {
	t.Helper()
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.headers) != 1 {
		t.Fatalf("recorded %d close requests, want 1", len(r.headers))
	}
	return r.headers[0]
}

// closeBothWays exercises TaskCloseN (TUI, cmux hook, board DoClose) and
// TaskCloseRevN (board DoCloseRev) — the two close methods on apiclient.
func closeBothWays(t *testing.T, cfg apiclient.Config) []http.Header {
	t.Helper()
	var out []http.Header
	for _, rev := range []bool{false, true} {
		rec := &closeRecorder{}
		s := rec.server(t)
		cfg.BaseURL = s.URL
		c := apiclient.New(cfg)
		var err error
		if rev {
			_, _, err = c.TaskCloseRevN("task-6e819f39fe3aa9e6", "lead-cli", 3, "rev-1")
		} else {
			_, _, err = c.TaskCloseN("task-6e819f39fe3aa9e6", "lead-cli", 3)
		}
		if err != nil {
			t.Fatalf("close (rev=%v): %v", rev, err)
		}
		out = append(out, rec.only(t))
	}
	return out
}

func assertCloseHeaders(t *testing.T, what string, hs []http.Header, wantDoc string) {
	t.Helper()
	for i, h := range hs {
		// The secret key is the SAME value the manifest path sends — not a
		// second mint, not a rename.
		if got := h.Get("X-Barkpark-Session"); got == "" || got != sessionKey() {
			t.Errorf("%s[%d]: X-Barkpark-Session = %q, want the unchanged session key %q", what, i, got, sessionKey())
		}
		got, present := h["X-Barkpark-Session-Doc"]
		switch {
		case wantDoc == "" && present:
			t.Errorf("%s[%d]: X-Barkpark-Session-Doc = %q with no session bound; want it absent", what, i, got)
		case wantDoc != "" && h.Get("X-Barkpark-Session-Doc") != wantDoc:
			t.Errorf("%s[%d]: X-Barkpark-Session-Doc = %q (present=%v), want %q", what, i, h.Get("X-Barkpark-Session-Doc"), present, wantDoc)
		}
	}
}

// The TUI's client: cmd/barkpark builds it from ResolvedAPIConfig.
func TestTUICloseCarriesSessionHeadersWhenBound(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-2026-09-24-tui")
	assertCloseHeaders(t, "tui", closeBothWays(t, ResolvedAPIConfig()), "session-2026-09-24-tui")
}

func TestTUICloseOmitsSessionDocWhenUnbound(t *testing.T) {
	isolateSessionBinding(t)
	assertCloseHeaders(t, "tui", closeBothWays(t, ResolvedAPIConfig()), "")
}

// The cmux Stop hook closes through newHookClient(g, ctx).
func TestHookCloseCarriesSessionHeadersWhenBound(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-2026-09-24-hook")
	rec := &closeRecorder{}
	srv := rec.server(t)
	ctx := ambientCtx()
	ctx.Server = srv.URL
	if _, _, err := newHookClient(globals{}, ctx).TaskCloseN("task-6e819f39fe3aa9e6", "lead-cli", 3); err != nil {
		t.Fatalf("close: %v", err)
	}
	assertCloseHeaders(t, "hook", []http.Header{rec.only(t)}, "session-2026-09-24-hook")
}

// The ambient rule carries over: a context NOT resolved for this process's
// operator (AmbientCredentialsOK false — the zero value, and what
// `bp mcp serve --http` sets) must not log into the env/config-bound session.
func TestHookCloseIgnoresAmbientBindingForNonLocalContext(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-of-the-serving-operator")
	rec := &closeRecorder{}
	srv := rec.server(t)
	ctx := closeCtx() // AmbientCredentialsOK false
	ctx.Server = srv.URL
	if _, _, err := newHookClient(globals{}, ctx).TaskCloseN("task-6e819f39fe3aa9e6", "lead-cli", 3); err != nil {
		t.Fatalf("close: %v", err)
	}
	assertCloseHeaders(t, "hook-remote", []http.Header{rec.only(t)}, "")
}

// The CLI and apiclient name the headers independently (apiclient cannot
// import this package); a rename on one side must red here, not on the wire.
func TestSessionHeaderNamesMatchApiclient(t *testing.T) {
	if sessionHeader != apiclient.SessionKeyHeader || sessionDocHeader != apiclient.SessionDocHeader {
		t.Fatalf("cli (%q, %q) != apiclient (%q, %q)", sessionHeader, sessionDocHeader,
			apiclient.SessionKeyHeader, apiclient.SessionDocHeader)
	}
}

// An explicit --session binds the hook's close even for a non-local context,
// exactly as it does for the manifest path.
func TestHookCloseExplicitSessionBindsForNonLocalContext(t *testing.T) {
	isolateSessionBinding(t)
	rec := &closeRecorder{}
	srv := rec.server(t)
	ctx := closeCtx()
	ctx.Server = srv.URL
	if _, _, err := newHookClient(globals{session: "explicit"}, ctx).TaskCloseN("task-6e819f39fe3aa9e6", "lead-cli", 3); err != nil {
		t.Fatalf("close: %v", err)
	}
	assertCloseHeaders(t, "hook-explicit", []http.Header{rec.only(t)}, "explicit")
}
