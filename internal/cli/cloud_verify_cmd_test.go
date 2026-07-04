package cli

// cloud_verify_cmd_test.go proves `bp cloud verify` against a fake control
// plane: the probe-name/label vocabulary is held to the committed
// verify_probes.json fixture (the D53 one-fixture-many-asserters tripwire —
// a probe rename reds Go and Elixir together), the table renders all three
// outcome shapes (all-pass, one-fail, unreachable) honestly, `-o json` is the
// envelope BYTES verbatim, the 409/404 refusals map to human sentences through
// the unified error seam, and the exit code is a real gate (0 only on a full
// pass).

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// verifyProbesCLIFixturePath is the shared probe-vocabulary fixture — the SAME
// file the Elixir executor (BarkparkCloud.Verify.probes/0) and the Go
// provisioner gate (internal/provisioner/verify_fixture_test.go) assert
// against, read relative to internal/cli/ exactly like attention_order.json.
var verifyProbesCLIFixturePath = filepath.Join("..", "..", "cloud", "priv", "static", "__fixtures__", "verify_probes.json")

// TestVerifyProbeVocabularyMatchesFixture holds the CLI's probe order + human
// labels to the committed fixture: same names, same order, same labels. A
// probe rename or relabel on either side reds here — this runtime can never
// drift from the executors it renders for.
func TestVerifyProbeVocabularyMatchesFixture(t *testing.T) {
	raw, err := os.ReadFile(verifyProbesCLIFixturePath)
	if err != nil {
		t.Fatalf("read verify_probes.json fixture: %v", err)
	}
	var fx struct {
		Probes []struct {
			Name     string `json:"name"`
			Label    string `json:"label"`
			PassRule string `json:"pass_rule"`
		} `json:"probes"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode verify_probes.json: %v", err)
	}
	if len(fx.Probes) != len(verifyProbeOrder) {
		t.Fatalf("fixture has %d probes, CLI order has %d", len(fx.Probes), len(verifyProbeOrder))
	}
	if len(fx.Probes) != len(verifyProbeLabels) {
		t.Fatalf("fixture has %d probes, CLI labels map has %d", len(fx.Probes), len(verifyProbeLabels))
	}
	for i, p := range fx.Probes {
		if p.Name != verifyProbeOrder[i] {
			t.Errorf("probe %d: fixture %q, CLI order %q", i, p.Name, verifyProbeOrder[i])
		}
		if got := verifyProbeLabels[p.Name]; got != p.Label {
			t.Errorf("%s: CLI label %q, fixture label %q", p.Name, got, p.Label)
		}
		if got := verifyProbeLabel(p.Name); got != p.Label {
			t.Errorf("%s: verifyProbeLabel = %q, fixture label %q", p.Name, got, p.Label)
		}
	}
}

// The three committed envelope shapes, mirroring the Elixir executor's result
// byte-shape (status is a number or null; evidence is its exact wording).
const verifyAllPassEnvelope = `{"ok":true,"reachable":true,"verified_at":"2026-07-04T10:00:00Z","probes":[` +
	`{"name":"verify.api","ok":true,"reachable":true,"status":200,"latency_ms":41,"evidence":"GET /v1/capabilities → 200 (API up)"},` +
	`{"name":"verify.login","ok":true,"reachable":true,"status":401,"latency_ms":63,"evidence":"POST /v1/auth/login → 401 (auth stack answered; bad creds rejected)"},` +
	`{"name":"verify.studio","ok":true,"reachable":true,"status":200,"latency_ms":118,"evidence":"GET /studio → 200 (renders)"}]}`

const verifyOneFailEnvelope = `{"ok":false,"reachable":true,"verified_at":"2026-07-04T10:00:00Z","probes":[` +
	`{"name":"verify.api","ok":true,"reachable":true,"status":200,"latency_ms":41,"evidence":"GET /v1/capabilities → 200 (API up)"},` +
	`{"name":"verify.login","ok":true,"reachable":true,"status":422,"latency_ms":63,"evidence":"POST /v1/auth/login → 422 (auth stack answered; bad creds rejected)"},` +
	`{"name":"verify.studio","ok":false,"reachable":true,"status":502,"latency_ms":97,"evidence":"502 — upstream connect error"}]}`

const verifyUnreachableEnvelope = `{"ok":false,"reachable":false,"verified_at":"2026-07-04T10:00:00Z","probes":[` +
	`{"name":"verify.api","ok":false,"reachable":false,"status":null,"latency_ms":5003,"evidence":"instance unreachable"},` +
	`{"name":"verify.login","ok":false,"reachable":false,"status":null,"latency_ms":5001,"evidence":"instance unreachable"},` +
	`{"name":"verify.studio","ok":false,"reachable":false,"status":null,"latency_ms":5002,"evidence":"instance unreachable"}]}`

// newVerifyServer stands up a fake control plane answering the verify route
// with the given status + body, seeds a cloud login pointed at it, and records
// the method/path/auth it saw.
func newVerifyServer(t *testing.T, status int, body string) (gotMethod, gotPath, gotAuth *string) {
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

// runVerify drives runCloudVerify with an in-memory writer at the chosen
// output shape + color, returning stdout, stderr, exit.
func runVerify(t *testing.T, output string, color bool, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = color
	code := runCloudVerify(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// TestRunCloudVerifyAllPass: a full pass renders the verdict + one labelled
// row per probe and exits 0 — and the request is a Bearer-authed POST to the
// verify route (a UUID instance needs no fleet-list resolve).
func TestRunCloudVerifyAllPass(t *testing.T) {
	method, path, auth := newVerifyServer(t, 200, verifyAllPassEnvelope)

	stdout, stderr, code := runVerify(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if *method != "POST" || *path != "/v1/barkparks/"+testInstanceID+"/verify" {
		t.Fatalf("hit %s %s, want POST /v1/barkparks/%s/verify", *method, *path, testInstanceID)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", *auth)
	}
	if !strings.Contains(stdout, "Golden path verified — 3 of 3 probes passed") {
		t.Fatalf("missing pass verdict:\n%s", stdout)
	}
	for _, label := range []string{"API answers", "Login responds", "Studio renders"} {
		if !strings.Contains(stdout, label) {
			t.Fatalf("missing probe label %q:\n%s", label, stdout)
		}
	}
	// The login probe's 401 is a PASS (the #957 guard) — its row must say ok.
	if !strings.Contains(stdout, "401") {
		t.Fatalf("login probe HTTP status missing:\n%s", stdout)
	}
	if strings.Contains(stdout, "failed") {
		t.Fatalf("a full pass must paint no failed cell:\n%s", stdout)
	}
}

// TestRunCloudVerifyOneFail: a red probe renders the honest count verdict,
// its evidence line, and a non-zero exit.
func TestRunCloudVerifyOneFail(t *testing.T) {
	newVerifyServer(t, 200, verifyOneFailEnvelope)

	stdout, _, code := runVerify(t, "table", false, testInstanceID)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d (a failed verification is a failed check)", code, exitGeneric)
	}
	if !strings.Contains(stdout, "1 of 3 probes failed") {
		t.Fatalf("missing fail verdict:\n%s", stdout)
	}
	if !strings.Contains(stdout, "502 — upstream connect error") {
		t.Fatalf("the failing probe's evidence must be visible:\n%s", stdout)
	}
}

// TestRunCloudVerifyUnreachable: an unreachable box is a completed FAILED
// verification — the table renders (null HTTP as an em dash), the unreachable
// note appears, exit is non-zero, and NOTHING is reported as a CLI error.
func TestRunCloudVerifyUnreachable(t *testing.T) {
	newVerifyServer(t, 200, verifyUnreachableEnvelope)

	stdout, stderr, code := runVerify(t, "table", false, testInstanceID)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	if !strings.Contains(stdout, "3 of 3 probes failed") {
		t.Fatalf("missing fail verdict:\n%s", stdout)
	}
	if !strings.Contains(stdout, "the instance never answered") {
		t.Fatalf("missing the honest unreachable note:\n%s", stdout)
	}
	if !strings.Contains(stdout, "—") {
		t.Fatalf("a null probe status must render as an em dash:\n%s", stdout)
	}
	if strings.Contains(stderr, "bp:") {
		t.Fatalf("unreachable is a RESULT, not a transport error — stderr must carry no bp: line:\n%s", stderr)
	}
}

// TestRunCloudVerifyJSONPassthrough: `-o json` emits the control-plane
// envelope BYTES verbatim (the envelope IS the contract) and the exit still
// follows the verdict.
func TestRunCloudVerifyJSONPassthrough(t *testing.T) {
	newVerifyServer(t, 200, verifyAllPassEnvelope)
	stdout, _, code := runVerify(t, "json", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if stdout != verifyAllPassEnvelope+"\n" {
		t.Fatalf("json output must be the envelope verbatim:\n got: %q\nwant: %q", stdout, verifyAllPassEnvelope+"\n")
	}
}

// TestRunCloudVerifyJSONFailExit: json mode on a failed verification still
// exits non-zero — machine consumers gate on the exit code too.
func TestRunCloudVerifyJSONFailExit(t *testing.T) {
	newVerifyServer(t, 200, verifyUnreachableEnvelope)
	stdout, _, code := runVerify(t, "json", false, testInstanceID)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	if stdout != verifyUnreachableEnvelope+"\n" {
		t.Fatalf("json output must be the envelope verbatim:\n%s", stdout)
	}
}

// TestRunCloudVerifyNotLive: the 409 not_live refusal maps to one human
// sentence through the unified `bp:` seam (exit conflict), and to the
// {ok:false,error:{code}} envelope under -o json.
func TestRunCloudVerifyNotLive(t *testing.T) {
	newVerifyServer(t, 409, `{"error":"not_live"}`)

	stdout, stderr, code := runVerify(t, "table", false, testInstanceID)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d (conflict)", code, exitConflict)
	}
	if !strings.Contains(stderr, "bp:") || !strings.Contains(stderr, "not live") {
		t.Fatalf("want a bp:-prefixed not-live sentence on stderr:\n%s", stderr)
	}
	if strings.TrimSpace(stdout) != "" {
		t.Fatalf("a refusal must keep stdout clean on the human path:\n%s", stdout)
	}

	// json parity: the same refusal is a parseable {ok:false,error:{…}}.
	newVerifyServer(t, 409, `{"error":"not_live"}`)
	jout, _, jcode := runVerify(t, "json", false, testInstanceID)
	if jcode != exitConflict {
		t.Fatalf("json exit = %d, want %d", jcode, exitConflict)
	}
	var env struct {
		OK  bool `json:"ok"`
		Err struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(jout), &env); err != nil {
		t.Fatalf("decode json refusal: %v\n%s", err, jout)
	}
	if env.OK || env.Err.Code != "not_live" {
		t.Fatalf("json refusal = %+v, want ok:false code:not_live", env)
	}
}

// TestRunCloudVerifyNotFound: the team-scoped 404 maps to the no-existence-leak
// sentence, exit not_found.
func TestRunCloudVerifyNotFound(t *testing.T) {
	newVerifyServer(t, 404, `{"error":"not_found"}`)
	_, stderr, code := runVerify(t, "table", false, testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (not_found)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no such instance") {
		t.Fatalf("want the no-such-instance sentence:\n%s", stderr)
	}
}

// TestRunCloudVerifyNoAdminToken: the pre-feature-row 404 gets its own
// actionable sentence (re-provision), not a generic not-found.
func TestRunCloudVerifyNoAdminToken(t *testing.T) {
	newVerifyServer(t, 404, `{"error":"no_admin_token","detail":"No admin token is stored for this instance yet."}`)
	_, stderr, code := runVerify(t, "table", false, testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no stored admin token") || !strings.Contains(stderr, "re-provision") {
		t.Fatalf("want the admin-token sentence with its fix hint:\n%s", stderr)
	}
}

// TestRunCloudVerifyNoToken: without a Cloud session the command is an auth
// error with a `bp login` hint and makes no network call.
func TestRunCloudVerifyNoToken(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runVerify(t, "table", false, testInstanceID)
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("expected a login hint on stderr:\n%s", stderr)
	}
}

// TestRunCloudVerifyUsage: zero or extra positionals (and unknown flags) are
// usage errors, exit 2.
func TestRunCloudVerifyUsage(t *testing.T) {
	withTempConfigHome(t)
	if _, _, code := runVerify(t, "table", false); code != exitUsage {
		t.Fatalf("no-arg exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runVerify(t, "table", false, "a", "b"); code != exitUsage {
		t.Fatalf("two-arg exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runVerify(t, "table", false, "--bogus", "x"); code != exitUsage {
		t.Fatalf("unknown-flag exit = %d, want %d", code, exitUsage)
	}
}

// TestRunCloudVerifyColorRoles: with color on, a passing STATUS cell paints
// green and a failing one red — the same statusRole seam as every other table
// (D12) — while the colorless run of the same envelope carries no ANSI at all.
func TestRunCloudVerifyColorRoles(t *testing.T) {
	newVerifyServer(t, 200, verifyOneFailEnvelope)
	colored, _, _ := runVerify(t, "table", true, testInstanceID)
	if !strings.Contains(colored, "\033[32m") {
		t.Fatalf("want a green (ok) cell in colored output:\n%q", colored)
	}
	if !strings.Contains(colored, "\033[31m") {
		t.Fatalf("want a red (failed) cell in colored output:\n%q", colored)
	}

	newVerifyServer(t, 200, verifyOneFailEnvelope)
	plain, _, _ := runVerify(t, "table", false, testInstanceID)
	if strings.Contains(plain, "\033[") {
		t.Fatalf("colorless output must carry no ANSI:\n%q", plain)
	}
}

// TestRunCloudVerifyHelp: -h anywhere prints usage and exits 0 without a
// network call or a config requirement.
func TestRunCloudVerifyHelp(t *testing.T) {
	withTempConfigHome(t)
	stdout, _, code := runVerify(t, "table", false, "-h")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "bp cloud verify") {
		t.Fatalf("help must name the command:\n%s", stdout)
	}
}
