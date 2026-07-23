package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A bytes.Buffer stdout is never a TTY, so `bp chat` must refuse to launch the
// full-screen program rather than scribble escape codes into a pipe.
func TestChatRequiresTTY(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runChat(w, globals{}, manifest.Context{Server: "http://localhost:4000"}, nil)
	if code != exitGeneric {
		t.Fatalf("exit code = %d, want %d (non-TTY)", code, exitGeneric)
	}
	if !strings.Contains(stderr.String(), "needs a terminal") {
		t.Fatalf("stderr missing the terminal-gate message: %q", stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("non-TTY run wrote to stdout: %q", stdout.String())
	}
}

// -h prints the help block before any TTY check.
func TestChatHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runChat(w, globals{help: true}, manifest.Context{}, nil)
	if code != exitOK {
		t.Fatalf("help exit code = %d, want %d", code, exitOK)
	}
	out := stdout.String()
	if !strings.Contains(out, "usage: bp chat") {
		t.Fatalf("help missing usage line: %q", out)
	}
	for _, want := range []string{"esc", "interrupt", "new session", "quit"} {
		if !strings.Contains(out, want) {
			t.Fatalf("help missing %q: %q", want, out)
		}
	}
}

// `ls` is the one accepted verb (herd charter D55h) — peeled BEFORE the
// stray-args reject and the TTY gate; any other positional is rejected, not
// silently ignored.
func TestChatRejectsArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runChat(w, globals{}, manifest.Context{}, []string{"resume"})
	if code != exitUsage {
		t.Fatalf("stray-arg exit code = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "takes no arguments") {
		t.Fatalf("stray-arg error should explain: %q", stderr.String())
	}

	// `ls` is ACCEPTED and non-TTY-safe: against a live server it exits 0 (the
	// roster prints), proving it routes AROUND both the reject and the TTY gate.
	srv := chatLsTestServer(t)
	defer srv.Close()
	stdout.Reset()
	stderr.Reset()
	w = newWriter(&stdout, &stderr)
	code = runChat(w, globals{}, manifest.Context{Server: srv.URL, Token: "tok"}, []string{"ls"})
	if code != exitOK {
		t.Fatalf("bp chat ls exit code = %d, want %d (stderr %q)", code, exitOK, stderr.String())
	}
	if !strings.Contains(stdout.String(), "blocked") || !strings.Contains(stdout.String(), "fix the auth bug") {
		t.Fatalf("ls must print the roster with states, got %q", stdout.String())
	}

	// an unknown ls flag still fails loudly
	stderr.Reset()
	code = runChat(w, globals{}, manifest.Context{Server: srv.URL}, []string{"ls", "--bogus"})
	if code != exitUsage {
		t.Fatalf("unknown ls flag exit code = %d, want %d", code, exitUsage)
	}

	// `--theme charple` is ACCEPTED: the flag is peeled BEFORE the stray-arg
	// reject, so it must NOT trip the "takes no arguments" gate. A non-TTY writer
	// then stops it at the terminal gate — proving the flag was consumed and the
	// run proceeded past the reject (not rejected as a stray positional).
	stdout.Reset()
	stderr.Reset()
	code = runChat(w, globals{}, manifest.Context{Server: srv.URL}, []string{"--theme", "charple"})
	if code != exitGeneric {
		t.Fatalf("`--theme charple` exit = %d, want %d (accepted, then TTY-gated)", code, exitGeneric)
	}
	if strings.Contains(stderr.String(), "takes no arguments") {
		t.Fatalf("`--theme charple` must NOT be rejected as a stray arg: %q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "needs a terminal") {
		t.Fatalf("`--theme charple` should reach the TTY gate, got %q", stderr.String())
	}

	// A bogus skin FALLS BACK to evergreen with a stderr notice (never an
	// error/crash and never a stray-arg reject) — it too proceeds to the TTY gate.
	stdout.Reset()
	stderr.Reset()
	code = runChat(w, globals{}, manifest.Context{Server: srv.URL}, []string{"--theme", "not-a-skin"})
	if code != exitGeneric {
		t.Fatalf("bogus `--theme` exit = %d, want %d (fallback, then TTY-gated)", code, exitGeneric)
	}
	if !strings.Contains(stderr.String(), "unknown --theme") || !strings.Contains(stderr.String(), "evergreen") {
		t.Fatalf("bogus `--theme` must print a fallback notice naming evergreen, got %q", stderr.String())
	}
	if strings.Contains(stderr.String(), "takes no arguments") {
		t.Fatalf("bogus `--theme` must fall back, NOT stray-arg reject: %q", stderr.String())
	}
}

// chatLsTestServer serves the widened sidebar wire (agent_state / cost) for
// the ls tests.
func chatLsTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/sessions" {
			http.NotFound(rw, r)
			return
		}
		rw.Header().Set("Content-Type", "application/json")
		_, _ = rw.Write([]byte(`{"sessions":[
			{"id":"11111111-1111-1111-1111-111111111111","title":"fix the auth bug",
			 "agent_state":"blocked","agent_state_at":"2026-07-18T11:55:00Z",
			 "message_count":4,"total_cost_usd":0.42},
			{"id":"22222222-2222-2222-2222-222222222222","title":"",
			 "agent_state":"idle","message_count":1}
		]}`))
	}))
}

// TestChatLsOneShotJSON proves -o json emits the raw sidebar rows (the machine
// seam scripts consume) instead of the human table.
func TestChatLsOneShotJSON(t *testing.T) {
	srv := chatLsTestServer(t)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.applyGlobals(globals{output: "json", outputSet: true})

	code := runChat(w, globals{output: "json", outputSet: true},
		manifest.Context{Server: srv.URL, Token: "tok"}, []string{"ls"})
	if code != exitOK {
		t.Fatalf("exit code = %d, want %d (stderr %q)", code, exitOK, stderr.String())
	}
	var payload struct {
		Sessions []map[string]any `json:"sessions"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("-o json must emit one parseable document, got %q: %v", stdout.String(), err)
	}
	if len(payload.Sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(payload.Sessions))
	}
	if payload.Sessions[0]["agent_state"] != "blocked" || payload.Sessions[0]["total_cost_usd"] != 0.42 {
		t.Fatalf("the widened fields must ride the JSON, got %+v", payload.Sessions[0])
	}
}

// TestFleetWatchLineFlipsOnly proves the --watch line law (D55h): one line per
// STATE flip carrying id + state (+ title when the frame has one); snapshots,
// heartbeats, and junk print nothing.
func TestFleetWatchLineFlipsOnly(t *testing.T) {
	line, ok := fleetWatchLine("state",
		[]byte(`{"session_id":"abc","agent_state":"blocked","ts":"2026-07-18T12:00:00Z","title":null}`))
	if !ok || line != "abc  blocked" {
		t.Fatalf("a null-title flip must print id+state, got %q ok=%v", line, ok)
	}
	line, ok = fleetWatchLine("state",
		[]byte(`{"session_id":"abc","agent_state":"working","title":"fix auth"}`))
	if !ok || line != "abc  working  fix auth" {
		t.Fatalf("a titled flip must carry the title, got %q ok=%v", line, ok)
	}
	for name, ev := range map[string][2]string{
		"snapshot":  {"snapshot", `{"sessions":[]}`},
		"heartbeat": {"heartbeat", `{"session_id":"abc","ts":"2026-07-18T12:00:00Z"}`},
		"junk":      {"state", `{not json`},
	} {
		if _, ok := fleetWatchLine(ev[0], []byte(ev[1])); ok {
			t.Fatalf("%s must print nothing", name)
		}
	}
}
