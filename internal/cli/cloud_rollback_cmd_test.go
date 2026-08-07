package cli

// cloud_rollback_cmd_test.go proves `bp cloud rollback` against a fake control
// plane: a 202 renders the started-verdict (short target sha + the pin + the D19
// schema-forward law), the request is a Bearer-authed POST to the rollback route
// (no vacuous green — path, method AND the Authorization header are asserted),
// `-o json` re-emits the CP envelope BYTES verbatim, and every typed refusal maps
// to a human sentence AND the charter's exit ladder (409-family → 6, 404 → 4,
// 5xx → 8, auth → 3). Both control-plane error shapes — the nested
// {"error":{"code"}} the relay emits and the flat {"error":"not_found"} its team
// guard emits — are covered.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The started (202) envelope shape the CP relay returns on success: a target sha
// (40-hex) and the release it atomically pinned the box at (charter W6 D16).
const rollbackStartedEnvelope = `{"status":"started","target_sha":"abcdef0123456789abcdef0123456789abcdef01","pinned_release":"1.4.2"}`

// newRollbackServer stands up a fake control plane answering the rollback route
// with the given status + body, seeds a cloud login pointed at it, and records the
// method/path/auth header it saw — so a test can prove the Bearer token is sent
// (the assertion the shared cloudclient fakeCP notably omits).
func newRollbackServer(t *testing.T, status int, body string) (gotMethod, gotPath, gotAuth *string) {
	t.Helper()
	var m, p, a string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m, p, a = r.Method, r.URL.Path, r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &m, &p, &a
}

// runRollback drives runCloudRollback with an in-memory writer at the chosen
// output shape, returning stdout, stderr, exit.
func runRollback(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudRollback(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// TestRunCloudRollbackStarted: a 202 renders the started verdict, the 12-hex short
// target sha, the pin, and the schema-forward law — and the request is a
// Bearer-authed POST to the rollback route (a UUID instance needs no fleet resolve).
func TestRunCloudRollbackStarted(t *testing.T) {
	method, path, auth := newRollbackServer(t, 202, rollbackStartedEnvelope)

	stdout, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if *method != "POST" || *path != "/v1/barkparks/"+testInstanceID+"/rollback" {
		t.Fatalf("hit %s %s, want POST /v1/barkparks/%s/rollback", *method, *path, testInstanceID)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", *auth)
	}
	if !strings.Contains(stdout, "instance rollback started") {
		t.Fatalf("missing started verdict:\n%s", stdout)
	}
	// The target sha is clamped to 12 hex — the short form appears, the full 40-hex
	// does not.
	if !strings.Contains(stdout, "abcdef012345") {
		t.Fatalf("missing short target sha:\n%s", stdout)
	}
	if strings.Contains(stdout, "abcdef0123456789abcdef") {
		t.Fatalf("target sha must be clamped to 12 hex, not the full 40:\n%s", stdout)
	}
	if !strings.Contains(stdout, "pinned at 1.4.2") {
		t.Fatalf("missing the pin line (charter D16):\n%s", stdout)
	}
	if !strings.Contains(stdout, "schema stays forward") {
		t.Fatalf("missing the D19 schema-forward law:\n%s", stdout)
	}
}

// TestRunCloudRollbackJSONPassthrough: `-o json` emits the control-plane envelope
// BYTES verbatim (the envelope IS the contract) and exits 0.
func TestRunCloudRollbackJSONPassthrough(t *testing.T) {
	newRollbackServer(t, 202, rollbackStartedEnvelope)
	stdout, _, code := runRollback(t, "json", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if stdout != rollbackStartedEnvelope+"\n" {
		t.Fatalf("json output must be the envelope verbatim:\n got: %q\nwant: %q", stdout, rollbackStartedEnvelope+"\n")
	}
}

// TestRunCloudRollbackNoPreviousSlot: the 409 no_previous_slot refusal (nested
// error shape) maps to the honest deny sentence — never a flip to garbage — with
// exit conflict.
func TestRunCloudRollbackNoPreviousSlot(t *testing.T) {
	newRollbackServer(t, 409, `{"error":{"code":"no_previous_slot"}}`)
	stdout, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d (conflict)", code, exitConflict)
	}
	if !strings.Contains(stderr, "bp:") || !strings.Contains(stderr, "no previous slot") {
		t.Fatalf("want a bp:-prefixed no-previous-slot sentence:\n%s", stderr)
	}
	if !strings.Contains(stderr, "Nothing was flipped") {
		t.Fatalf("a deny path must say nothing was flipped:\n%s", stderr)
	}
	if strings.TrimSpace(stdout) != "" {
		t.Fatalf("a refusal must keep stdout clean on the human path:\n%s", stdout)
	}
}

// TestRunCloudRollbackAlreadyRunning: the 409 already_running refusal maps to
// exit conflict with the one-run-at-a-time sentence.
func TestRunCloudRollbackAlreadyRunning(t *testing.T) {
	newRollbackServer(t, 409, `{"error":{"code":"already_running"}}`)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d (conflict)", code, exitConflict)
	}
	if !strings.Contains(stderr, "already running") {
		t.Fatalf("want the already-running sentence:\n%s", stderr)
	}
}

// TestRunCloudRollbackNotSupported: the 409 not_supported refusal (a box that
// predates the slot machinery) maps to exit conflict and says nothing was flipped.
func TestRunCloudRollbackNotSupported(t *testing.T) {
	newRollbackServer(t, 409, `{"error":{"code":"not_supported"}}`)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d (conflict)", code, exitConflict)
	}
	if !strings.Contains(stderr, "predates the blue/green slot machinery") {
		t.Fatalf("want the not-supported sentence:\n%s", stderr)
	}
}

// TestRunCloudRollbackNotFound: the team-scoped 404 (flat error shape, no
// existence leak) maps to the no-such-instance sentence, exit not_found.
func TestRunCloudRollbackNotFound(t *testing.T) {
	newRollbackServer(t, 404, `{"error":"not_found"}`)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (not_found)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no such instance") {
		t.Fatalf("want the no-such-instance sentence:\n%s", stderr)
	}
}

// TestRunCloudRollbackNoAdminToken: the pre-feature-row 404 (nested shape) gets
// its own actionable re-provision sentence, still exit not_found.
func TestRunCloudRollbackNoAdminToken(t *testing.T) {
	newRollbackServer(t, 404, `{"error":{"code":"no_admin_token","detail":"captured at provision time"}}`)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no stored admin token") || !strings.Contains(stderr, "re-provision") {
		t.Fatalf("want the admin-token sentence with its fix hint:\n%s", stderr)
	}
}

// TestRunCloudRollbackInstanceUnreachable: the 502 instance_unreachable relay maps
// to exit server (8) and says nothing was flipped.
func TestRunCloudRollbackInstanceUnreachable(t *testing.T) {
	newRollbackServer(t, 502, `{"error":{"code":"instance_unreachable"}}`)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitServer {
		t.Fatalf("exit = %d, want %d (server)", code, exitServer)
	}
	if !strings.Contains(stderr, "never answered") || !strings.Contains(stderr, "nothing was flipped") {
		t.Fatalf("want the unreachable sentence:\n%s", stderr)
	}
}

// TestRunCloudRollbackDecryptFailed: the 500 decrypt_failed relay is a 5xx — it
// maps to exit server (8) by status family even though it is not a 502.
func TestRunCloudRollbackDecryptFailed(t *testing.T) {
	newRollbackServer(t, 500, `{"error":{"code":"decrypt_failed"}}`)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitServer {
		t.Fatalf("exit = %d, want %d (server)", code, exitServer)
	}
	if !strings.Contains(stderr, "could not decrypt") {
		t.Fatalf("want the decrypt-failed sentence:\n%s", stderr)
	}
}

// TestRunCloudRollbackNoToken: without a Cloud session the command is an auth
// error with a `bp login` hint and makes no network call.
func TestRunCloudRollbackNoToken(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("expected a login hint on stderr:\n%s", stderr)
	}
}

// TestRunCloudRollbackUsage: zero or extra positionals (and unknown flags) are
// usage errors, exit 2.
func TestRunCloudRollbackUsage(t *testing.T) {
	withTempConfigHome(t)
	if _, _, code := runRollback(t, "table"); code != exitUsage {
		t.Fatalf("no-arg exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runRollback(t, "table", "a", "b"); code != exitUsage {
		t.Fatalf("two-arg exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runRollback(t, "table", "--bogus", "x"); code != exitUsage {
		t.Fatalf("unknown-flag exit = %d, want %d", code, exitUsage)
	}
}

// TestRunCloudRollbackHelp: -h anywhere prints usage naming the command (and its
// distinction from the site-deployment promote) and exits 0 without a network call.
func TestRunCloudRollbackHelp(t *testing.T) {
	withTempConfigHome(t)
	stdout, _, code := runRollback(t, "table", "-h")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "bp cloud rollback") {
		t.Fatalf("help must name the command:\n%s", stdout)
	}
	if !strings.Contains(stdout, "NOT the") {
		t.Fatalf("help must distinguish instance rollback from the site-deployment promote:\n%s", stdout)
	}
}

// TestRunCloudRollbackStartedNoTargetSHA: a leaner 202 that omits target_sha still
// renders a coherent started verdict (no invented version) and exits 0 — the
// pointer fields decode to nil, never a fabricated empty string.
func TestRunCloudRollbackStartedNoTargetSHA(t *testing.T) {
	newRollbackServer(t, 202, `{"status":"started"}`)
	stdout, _, code := runRollback(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "resetting to its previous slot") {
		t.Fatalf("want the no-sha started wording:\n%s", stdout)
	}
	// Verify the started envelope decoded (json parity re-emits it verbatim).
	var env struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal([]byte(`{"status":"started"}`), &env); err != nil || env.Status != "started" {
		t.Fatalf("started envelope sanity: %v", err)
	}
}

// TestRunCloudRollbackForbiddenNoTeam is the STATUS-FLIP guard (cch-w40-s4).
// POST /v1/barkparks/:id/rollback is gated by require_primary_team_admin/1, which
// today refuses a teamless caller with 422 {"error":"no_team"} and after #9956
// refuses it with 403 {"error":"forbidden","reason":"no_team","scope":"team"}.
// A status-only ladder turns that server-side re-classification into a DIFFERENT
// user experience — exit 3 ("your credential is bad") and the bare word
// "forbidden" — for a login whose credential is fine and whose fix is one
// command. The narration and the exit must key on the CAUSE the server named, so
// both sides of the flip say the same thing.
func TestRunCloudRollbackForbiddenNoTeam(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"pre-flip 422", 422, `{"error":"no_team"}`},
		{"post-flip 403", 403, `{"error":"forbidden","reason":"no_team","scope":"team"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newRollbackServer(t, tc.status, tc.body)
			_, stderr, code := runRollback(t, "table", testInstanceID)
			if code != exitGeneric {
				t.Fatalf("exit = %d, want %d (the cause, not the status, decides)\nstderr:\n%s", code, exitGeneric, stderr)
			}
			if !strings.Contains(stderr, "no active team") || !strings.Contains(stderr, "bp team use") {
				t.Fatalf("want the no_team narration + its fix hint:\n%s", stderr)
			}
			if !strings.Contains(stderr, "Nothing was flipped") {
				t.Fatalf("a deny path must say nothing was flipped:\n%s", stderr)
			}
		})
	}
}

// TestRunCloudRollbackForbiddenRoleKeepsAuthExit: the guard above must not swallow
// a REAL authority refusal — a 403 whose cause is a missing role stays exit 3 and
// never offers the `bp team use` fix, which would not help.
func TestRunCloudRollbackForbiddenRoleKeepsAuthExit(t *testing.T) {
	newRollbackServer(t, 403, `{"error":"forbidden","reason":"role","required":"team_admin","scope":"team"}`)
	_, stderr, code := runRollback(t, "table", testInstanceID)
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)\nstderr:\n%s", code, exitAuth, stderr)
	}
	if strings.Contains(stderr, "bp team use") {
		t.Fatalf("a role refusal must not be narrated as a missing team:\n%s", stderr)
	}
}
