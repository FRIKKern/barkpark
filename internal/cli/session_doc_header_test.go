package cli

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE SESSION-DOC HEADER (task-9002f2b301329f1f, CLI half of
// task-bc34e83515bbd91f). The server appends a task-closed / paper-published
// event to the type:session doc a request names in X-Barkpark-Session-Doc
// (api/lib/barkpark_web/session_autolog.ex) — but only if bp SENDS it. These
// tests pin: bound → the two armed commands carry the slug AND the unchanged
// secret X-Barkpark-Session; unbound → the new header is absent; and every
// other command stays byte-identical.

const wantSessionDocHeader = "X-Barkpark-Session-Doc"

// isolateSessionBinding points every binding layer at an empty state: no env
// slug, and a config dir holding no config.json. The session KEY is pinned so
// X-Barkpark-Session is present and comparable (sessionKey is sync.Once, so the
// assertion compares against sessionKey() rather than a literal).
func isolateSessionBinding(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv("BARKPARK_SESSION", "")
	t.Setenv("BARKPARK_SESSION_KEY", "pinned-test-key")
	return dir
}

// ambientCtx is an operator-local context — the shape ResolveWithSources
// produces for a plain `bp …` run.
func ambientCtx() manifest.Context {
	ctx := closeCtx()
	ctx.AmbientCredentialsOK = true
	return ctx
}

func buildArmedRequests(t *testing.T, g globals, ctx manifest.Context) map[string]*manifestRequest {
	t.Helper()
	m, tree := loadTreeFrom(t, fullManifest)
	payload := filepath.Join(t.TempDir(), "paper.json")
	if err := os.WriteFile(payload, []byte(`{"slug":"p","title":"P","blocks":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := map[string]struct {
		noun, verb string
		tail       []string
	}{
		"task.close":       {"task", "close", []string{"task-6e819f39fe3aa9e6", "lead-cli", "3", "done", "shipped"}},
		"bulldocs.publish": {"bulldocs", "publish", []string{"p", "--file", payload}},
		// A control: an unarmed write. The server ignores the header there, and
		// bp must not send it — the header names a log target, not an identity.
		"task.ls": {"task", "ls", nil},
	}
	out := map[string]*manifestRequest{}
	for id, c := range cases {
		cmd, ok := tree.Lookup(c.noun, c.verb)
		if !ok {
			t.Fatalf("%s missing from full-manifest fixture", id)
		}
		req, derr := buildManifestRequest(g, ctx, m, *cmd, c.tail, false)
		if derr != nil {
			t.Fatalf("%s: build: %v", id, derr)
		}
		out[id] = req
	}
	return out
}

func assertSessionDoc(t *testing.T, reqs map[string]*manifestRequest, want string) {
	t.Helper()
	for _, id := range []string{"task.close", "bulldocs.publish"} {
		h := reqs[id].headers
		got, present := h[wantSessionDocHeader]
		if want == "" {
			if present {
				t.Errorf("%s: %s = %q with no session bound; want the header absent", id, wantSessionDocHeader, got)
			}
		} else if got != want {
			t.Errorf("%s: %s = %q (present=%v), want %q", id, wantSessionDocHeader, got, present, want)
		}
		// The secret claim-session key rides alongside, never replaced.
		if key := h["X-Barkpark-Session"]; key != sessionKey() || key == "" {
			t.Errorf("%s: X-Barkpark-Session = %q, want the unchanged session key %q", id, key, sessionKey())
		}
	}
	if got, present := reqs["task.ls"].headers[wantSessionDocHeader]; present {
		t.Errorf("task.ls: %s = %q — only the two server-armed doors may carry it", wantSessionDocHeader, got)
	}
}

func TestSessionDocHeaderFromEnv(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-2026-09-24-env")
	assertSessionDoc(t, buildArmedRequests(t, globals{}, ambientCtx()), "session-2026-09-24-env")
}

func TestSessionDocHeaderFromConfig(t *testing.T) {
	dir := isolateSessionBinding(t)
	if err := os.MkdirAll(filepath.Join(dir, "barkpark"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "barkpark", "config.json"),
		[]byte(`{"session":"session-2026-09-24-cfg"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	assertSessionDoc(t, buildArmedRequests(t, globals{}, ambientCtx()), "session-2026-09-24-cfg")
}

func TestSessionDocHeaderAbsentWhenUnbound(t *testing.T) {
	isolateSessionBinding(t)
	assertSessionDoc(t, buildArmedRequests(t, globals{}, ambientCtx()), "")
}

// --session is parsed as a global anywhere in argv and outranks the env layer.
func TestSessionDocHeaderFromFlagBeatsEnv(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-from-env")
	g, rest, err := parseGlobals([]string{"task", "close", "--session", "session-from-flag"})
	if err != nil {
		t.Fatalf("parseGlobals: %v", err)
	}
	if g.session != "session-from-flag" || len(rest) != 2 {
		t.Fatalf("parseGlobals: session=%q rest=%v, want the flag consumed as a global", g.session, rest)
	}
	assertSessionDoc(t, buildArmedRequests(t, g, ambientCtx()), "session-from-flag")
}

// The env/config layers are AMBIENT: a context not resolved for this process's
// operator (bp mcp serve --http clears AmbientCredentialsOK) must not log a
// remote peer's close into the serving operator's session. An explicit
// --session still binds.
func TestSessionDocHeaderIgnoresAmbientBindingForNonLocalContext(t *testing.T) {
	isolateSessionBinding(t)
	t.Setenv("BARKPARK_SESSION", "session-of-the-serving-operator")
	remote := closeCtx() // AmbientCredentialsOK false — the literal zero value
	assertSessionDoc(t, buildArmedRequests(t, globals{}, remote), "")
	assertSessionDoc(t, buildArmedRequests(t, globals{session: "explicit"}, remote), "explicit")
}
