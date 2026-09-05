package cli

// cloud_update_cmd_test.go proves `bp cloud update <instance>` against a fake
// control plane, and pins the ONE command shape the console prints.
//
// The three outcomes the route defines each get a capture: ACCEPTED (202
// {ok,status} — the verdict quotes the SERVER's state, never a canned success),
// ALREADY IN PROGRESS (409 already_running), and PINNED (409 pinned +
// pinned_release — the sentence names the pin, offers --force for this one run and
// `autoupdate unpin` for good). --force is proved on the WIRE (the request body),
// not merely in the copy.
//
// The shape pin is the point of the row: the console renders
// cliChipHtml("bp cloud update " + instance) and there was no such verb. So a test
// here asserts the CLI's own usage constant is byte-equal to "bp cloud update
// <instance>" AND that `bp cloud update` actually dispatches — a chip is only
// honest if BOTH halves hold.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The accepted (202) envelope the CP relay returns when the run starts.
const selfUpdateAcceptedEnvelope = `{"ok":true,"status":"updating"}`

// newSelfUpdateServer stands up a fake control plane answering the self-update
// route with the given status + body, seeds a cloud login pointed at it, and
// records the method/path/auth/body it saw — so a test can prove the Bearer token
// AND the --force field actually reached the wire.
func newSelfUpdateServer(t *testing.T, status int, body string) (gotMethod, gotPath, gotAuth, gotBody *string) {
	t.Helper()
	var m, p, a, b string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		m, p, a, b = r.Method, r.URL.Path, r.Header.Get("Authorization"), string(raw)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &m, &p, &a, &b
}

// runUpdate drives runCloudUpdate with an in-memory writer at the chosen output
// shape, returning stdout, stderr, exit.
func runUpdate(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudUpdate(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// ---------------------------------------------------------------------------
// c2 — ONE command shape, pinned on the CLI side.
//
// The console prints this exact string as a copy-pasteable chip
// (cloud/priv/static/app.js: cliChipHtml("bp cloud update " + instance), asserted
// by cloud/priv/static/__app.test.mjs with /bp cloud update abc/). If either side
// moves, an operator copies a command that does not exist — which is the defect
// this row exists to delete. The console half is pinned in its own suite; this is
// the CLI half.
// ---------------------------------------------------------------------------

// TestCloudUpdateCommandShapeIsExact: the usage constant is BYTE-EQUAL to the chip
// text. Not "contains", not normalized — byte-equal, because the chip is copied
// verbatim into a shell.
func TestCloudUpdateCommandShapeIsExact(t *testing.T) {
	const chip = "bp cloud update <instance>"
	if cloudUpdateUsage != chip {
		t.Fatalf("command shape drifted from the console chip:\n  cli:     %q\n  console: %q", cloudUpdateUsage, chip)
	}
}

// TestCloudUpdateHelpPrintsTheExactShape: the help text a reader lands on after
// copy-pasting the chip shows the same command shape back to them.
func TestCloudUpdateHelpPrintsTheExactShape(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	if code := runCloudUpdate(w, globals{}, []string{"-h"}); code != exitOK {
		t.Fatalf("help exit = %d, want 0", code)
	}
	if !strings.Contains(sout.String(), "bp cloud update <instance>") {
		t.Fatalf("help does not print the exact command shape:\n%s", sout.String())
	}
}

// TestCloudUpdateIsDispatched: `bp cloud update …` must REACH runCloudUpdate. This
// is the arm that reds if the dispatch case is removed — a verb with perfect help
// and no route is exactly the lying chip, one layer down. The probe is a
// logged-out run: it exits exitAuth with the update command's own auth sentence,
// which the "unknown cloud command" usage error (exitUsage) cannot produce.
func TestCloudUpdateIsDispatched(t *testing.T) {
	withTempConfigHome(t)
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	code := runCloud(w, globals{}, []string{"update", "some-instance"})
	if code == exitUsage {
		t.Fatalf("`bp cloud update` is not dispatched (usage error):\nstdout:\n%s\nstderr:\n%s", sout.String(), serr.String())
	}
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (the update verb's own logged-out refusal)\nstderr:\n%s", code, exitAuth, serr.String())
	}
	if !strings.Contains(serr.String(), "update an instance") {
		t.Fatalf("dispatched to the wrong verb — stderr does not name the update refusal:\n%s", serr.String())
	}
}

// TestCloudHelpListsUpdate: `bp cloud -h` must OFFER the verb, or the only way to
// discover it is the console chip that started this whole problem.
func TestCloudHelpListsUpdate(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	if code := runCloud(w, globals{help: true}, nil); code != exitOK {
		t.Fatalf("cloud help exit = %d", code)
	}
	if !strings.Contains(sout.String(), "bp cloud update -h") {
		t.Fatalf("`bp cloud -h` does not list the update verb:\n%s", sout.String())
	}
}

// ---------------------------------------------------------------------------
// c0/c1 — the three outcomes, each from the real response.
// ---------------------------------------------------------------------------

// TestRunCloudUpdateAccepted: a 202 renders a verdict built from the state the
// SERVER named, over a Bearer-authed POST to the self-update route — and the
// unforced request carries no force field.
func TestRunCloudUpdateAccepted(t *testing.T) {
	method, path, auth, body := newSelfUpdateServer(t, 202, selfUpdateAcceptedEnvelope)

	stdout, stderr, code := runUpdate(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if *method != "POST" || *path != "/v1/barkparks/"+testInstanceID+"/self-update" {
		t.Fatalf("hit %s %s, want POST /v1/barkparks/%s/self-update", *method, *path, testInstanceID)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", *auth)
	}
	if strings.Contains(*body, "force") {
		t.Fatalf("an unforced trigger must not send force, body = %q", *body)
	}
	if !strings.Contains(stdout, "self-update triggered") {
		t.Fatalf("missing the triggered verdict:\n%s", stdout)
	}
	// The state is QUOTED from the response — this is the "never a canned success"
	// clause made checkable.
	if !strings.Contains(stdout, `"updating"`) {
		t.Fatalf("the verdict does not quote the server's run state:\n%s", stdout)
	}
	if !strings.Contains(stdout, "async") {
		t.Fatalf("missing the honest async note:\n%s", stdout)
	}
}

// TestRunCloudUpdateNeverInventsAState: a 202 whose envelope names NO state must
// not grow one. The command says the request was accepted and that no state was
// reported — the honest half-answer, not a fabricated "updating".
func TestRunCloudUpdateNeverInventsAState(t *testing.T) {
	newSelfUpdateServer(t, 202, `{"ok":true}`)
	stdout, stderr, code := runUpdate(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if strings.Contains(stdout, "updating") {
		t.Fatalf("a stateless 202 must not produce a run state:\n%s", stdout)
	}
	if !strings.Contains(stdout, "reported no run state") {
		t.Fatalf("missing the honest no-state sentence:\n%s", stdout)
	}
}

// TestRunCloudUpdateAlreadyInProgress: the in-flight refusal is one plain sentence
// at the conflict exit, and it does NOT offer --force (which overrides a pin, not
// a run) — offering it here would send an operator to hammer a busy box.
func TestRunCloudUpdateAlreadyInProgress(t *testing.T) {
	newSelfUpdateServer(t, 409, `{"error":{"code":"already_running"}}`)

	stdout, stderr, code := runUpdate(t, "table", testInstanceID)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d (409 → conflict)\nstdout:\n%s\nstderr:\n%s", code, exitConflict, stdout, stderr)
	}
	if !strings.Contains(stderr, "already running") {
		t.Fatalf("missing the in-progress sentence:\n%s", stderr)
	}
	if !strings.Contains(stderr, "Nothing new was started") {
		t.Fatalf("a deny path must say nothing was started:\n%s", stderr)
	}
	if strings.Contains(stderr, "Re-run with --force") {
		t.Fatalf("--force must not be offered for a run in flight:\n%s", stderr)
	}
}

// TestRunCloudUpdatePinnedConflict: the 409 pinned refusal NAMES the pin, mirrors
// the console modal's explanation ("holds an instance at or above its current
// version; it does not roll back"), offers --force for this ONE run and unpin for
// good, and exits at the conflict code.
func TestRunCloudUpdatePinnedConflict(t *testing.T) {
	newSelfUpdateServer(t, 409, `{"error":{"code":"pinned","pinned_release":"1.4.2"}}`)

	stdout, stderr, code := runUpdate(t, "table", testInstanceID)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d (409 → conflict)\nstdout:\n%s\nstderr:\n%s", code, exitConflict, stdout, stderr)
	}
	if !strings.Contains(stderr, "pinned at 1.4.2") {
		t.Fatalf("the pin refusal must NAME the release holding the box:\n%s", stderr)
	}
	if !strings.Contains(stderr, "does not roll back") {
		t.Fatalf("missing the console modal's pin explanation:\n%s", stderr)
	}
	if !strings.Contains(stderr, "--force") {
		t.Fatalf("the pin refusal must offer the real override:\n%s", stderr)
	}
	if !strings.Contains(stderr, "autoupdate unpin") {
		t.Fatalf("the pin refusal must name the permanent remedy:\n%s", stderr)
	}
	if !strings.Contains(stderr, "Nothing was started") {
		t.Fatalf("a deny path must say nothing was started:\n%s", stderr)
	}
}

// TestRunCloudUpdateForceReachesTheWire: --force is a REAL server field, so it must
// arrive as {"force":true} in the request BODY. A flag that only changes CLI copy
// would be the same lie in a new place.
func TestRunCloudUpdateForceReachesTheWire(t *testing.T) {
	_, _, _, body := newSelfUpdateServer(t, 202, selfUpdateAcceptedEnvelope)

	stdout, stderr, code := runUpdate(t, "table", testInstanceID, "--force")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(*body, `"force":true`) {
		t.Fatalf("--force did not reach the wire, body = %q", *body)
	}
	if !strings.Contains(stdout, "for THIS run only") {
		t.Fatalf("a forced run must say the pin is still set:\n%s", stdout)
	}
}

// TestRunCloudUpdateForcedPinRefusalDoesNotSuggestForce: if a pin refusal arrives
// on an ALREADY forced call, the control plane did not honour the override —
// telling the operator to add the flag they just used is the classic dead-end.
func TestRunCloudUpdateForcedPinRefusalDoesNotSuggestForce(t *testing.T) {
	newSelfUpdateServer(t, 409, `{"error":{"code":"pinned","pinned_release":"1.4.2"}}`)

	_, stderr, code := runUpdate(t, "table", testInstanceID, "--force")
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d", code, exitConflict)
	}
	if !strings.Contains(stderr, "even with --force") {
		t.Fatalf("a forced pin refusal must say the override was not honoured:\n%s", stderr)
	}
	if strings.Contains(stderr, "Re-run with --force") {
		t.Fatalf("must not tell the operator to add the flag they already used:\n%s", stderr)
	}
}

// TestRunCloudUpdateJSONIsTheEnvelopeVerbatim: `-o json` re-emits the control
// plane's BYTES, so the CLI never becomes a second definition of the contract.
func TestRunCloudUpdateJSONIsTheEnvelopeVerbatim(t *testing.T) {
	newSelfUpdateServer(t, 202, selfUpdateAcceptedEnvelope)

	stdout, stderr, code := runUpdate(t, "json", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if strings.TrimSpace(stdout) != selfUpdateAcceptedEnvelope {
		t.Fatalf("-o json is not the envelope verbatim:\n got: %s\nwant: %s", stdout, selfUpdateAcceptedEnvelope)
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(stdout), &v); err != nil {
		t.Fatalf("-o json is not valid json: %v", err)
	}
}

// TestRunCloudUpdateNotEnabledExits8: the box without BARKPARK_SELF_UPDATE_APPLY=1
// gets the actionable env-var sentence at the 5xx exit.
func TestRunCloudUpdateNotEnabledExits8(t *testing.T) {
	newSelfUpdateServer(t, 503, `{"error":{"code":"not_enabled"}}`)

	_, stderr, code := runUpdate(t, "table", testInstanceID)
	if code != exitServer {
		t.Fatalf("exit = %d, want %d (5xx → server)", code, exitServer)
	}
	if !strings.Contains(stderr, "BARKPARK_SELF_UPDATE_APPLY=1") {
		t.Fatalf("missing the actionable env-var remedy:\n%s", stderr)
	}
}

// TestRunCloudUpdateNotSupportedExits4: a pre-feature box 404s, and 404 is the
// not-found exit — the shared ladder, not a second one.
func TestRunCloudUpdateNotSupportedExits4(t *testing.T) {
	newSelfUpdateServer(t, 404, `{"error":{"code":"not_supported"}}`)

	_, stderr, code := runUpdate(t, "table", testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (404 → not found)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "predates the self-update machinery") {
		t.Fatalf("missing the pre-feature sentence:\n%s", stderr)
	}
}

// TestRunCloudUpdateNoTeamStaysExit1: the authority gate's cause outranks the
// status family — a teamless login has a GOOD credential, so it must not exit 3
// and send a script off to re-authenticate.
func TestRunCloudUpdateNoTeamStaysExit1(t *testing.T) {
	newSelfUpdateServer(t, 403, `{"error":"forbidden","reason":"no_team","scope":"team"}`)

	_, stderr, code := runUpdate(t, "table", testInstanceID)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d (the CAUSE, not the status family)", code, exitGeneric)
	}
	if !strings.Contains(stderr, "bp team use") {
		t.Fatalf("missing the team fix:\n%s", stderr)
	}
}

// TestRunCloudUpdateRequiresLogin / usage arity: the two local refusals.
func TestRunCloudUpdateRefusesWithoutLoginAndOnBadArity(t *testing.T) {
	withTempConfigHome(t)
	if _, stderr, code := runUpdate(t, "table", testInstanceID); code != exitAuth || !strings.Contains(stderr, "bp login") {
		t.Fatalf("logged out: exit = %d, stderr = %q", code, stderr)
	}
	if _, stderr, code := runUpdate(t, "table"); code != exitUsage || !strings.Contains(stderr, cloudUpdateUsage) {
		t.Fatalf("no args: exit = %d, stderr = %q", code, stderr)
	}
	if _, _, code := runUpdate(t, "table", "a", "b"); code != exitUsage {
		t.Fatalf("two args: exit = %d, want usage", code)
	}
	if _, stderr, code := runUpdate(t, "table", testInstanceID, "--nope"); code != exitUsage || !strings.Contains(stderr, "--nope") {
		t.Fatalf("unknown flag: exit = %d, stderr = %q", code, stderr)
	}
}
