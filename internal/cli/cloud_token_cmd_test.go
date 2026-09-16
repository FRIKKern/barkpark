package cli

// cloud_token_cmd_test.go proves `bp cloud token` against a fake control plane.
//
// THE CENTRAL ARM is CRED-2: the minted plaintext must not reach stdout, stderr,
// or the -o json envelope unless `--reveal` was passed. That claim is only worth
// anything with its QUIET CONTROL beside it — TestCloudTokenMintRevealPrints
// asserts the SAME assertion function DOES find the plaintext when `--reveal` is
// given. Without that control, a leak test would pass just as happily against a
// command that printed nothing at all, or against a fixture whose "plaintext"
// never reached the CLI.
//
// NO REAL CREDENTIAL APPEARS HERE. `fakeMintedToken` is a literal invented for
// this file; it is not a token shape any server ever issued and it authenticates
// nothing.

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

// fakeMintedToken is the FAKE plaintext the fake plane hands back. It carries
// the real prefix so the test exercises the real string shape, and a body that
// is obviously a fixture.
const fakeMintedToken = "bpc_pat_THIS-IS-A-TEST-FIXTURE-NOT-A-CREDENTIAL"

const fakeMintedPAT = `{"id":"pat-1","name":"ci-key","abilities":["write"],` +
	`"last_used_at":null,"expires_at":"2026-10-16T00:00:00Z","revoked_at":null,` +
	`"inserted_at":"2026-09-16T00:00:00Z"}`

// tokenPlane is a fake control plane for the three /v1/tokens routes. It records
// every request it saw, so a test can assert that a refusal happened with ZERO
// requests issued — the difference between "refused" and "refused after minting
// a live credential it then threw away".
type tokenPlane struct {
	seen   []string
	status int
	body   string
}

func newTokenPlane(t *testing.T, status int, body string) *tokenPlane {
	t.Helper()
	p := &tokenPlane{status: status, body: body}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.seen = append(p.seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(p.status)
		_, _ = w.Write([]byte(p.body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return p
}

// runToken drives runCloudToken with an in-memory writer.
func runToken(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = false
	code := runCloudToken(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// assertNoPlaintext is the leak assertion, used by BOTH the default-path test
// and its quiet control, so the two disagree only about the code under test.
func assertNoPlaintext(t *testing.T, where, s string) {
	t.Helper()
	if strings.Contains(s, fakeMintedToken) {
		t.Fatalf("the minted plaintext reached %s — CRED-2 says it must not without --reveal:\n%s", where, s)
	}
}

// TestCloudTokenMintWritesSinkAndPrintsNothingSecret is the CRED-2 arm: with
// --out, the credential lands in a 0600 file and NEITHER stream carries it.
// Revert the sink to a plain out.outf of the plaintext and this reds.
func TestCloudTokenMintWritesSinkAndPrintsNothingSecret(t *testing.T) {
	newTokenPlane(t, 201, `{"token":"`+fakeMintedToken+`","pat":`+fakeMintedPAT+`}`)
	dest := filepath.Join(t.TempDir(), "ci.token")

	stdout, stderr, code := runToken(t, "table", "mint", "--name", "ci-key", "--ability", "write", "--out", dest)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	assertNoPlaintext(t, "stdout", stdout)
	assertNoPlaintext(t, "stderr", stderr)

	raw, rerr := os.ReadFile(dest)
	if rerr != nil {
		t.Fatalf("read sink: %v", rerr)
	}
	if got := strings.TrimRight(string(raw), "\n"); got != fakeMintedToken {
		// Deliberately does NOT print `got` — an assertion about a credential
		// file must not become the thing that prints it.
		t.Fatalf("the sink does not hold the minted credential (%d bytes written)", len(raw))
	}
	st, serrr := os.Stat(dest)
	if serrr != nil {
		t.Fatalf("stat sink: %v", serrr)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("sink mode = %v, want 0600 — a world-readable credential file", st.Mode().Perm())
	}
	// The receipt must still be USEFUL: the row id is what you revoke with.
	if !strings.Contains(stdout, "pat-1") {
		t.Fatalf("the receipt omits the token id, so nothing can be revoked:\n%s", stdout)
	}
}

// TestCloudTokenMintRevealPrints is the QUIET CONTROL for the test above: the
// SAME assertion function, inverted, on the one path that is allowed to print.
// If this ever stops finding the plaintext, the leak test above is measuring
// nothing and both must be re-read.
func TestCloudTokenMintRevealPrints(t *testing.T) {
	newTokenPlane(t, 201, `{"token":"`+fakeMintedToken+`","pat":`+fakeMintedPAT+`}`)

	stdout, stderr, code := runToken(t, "table", "mint", "--name", "ci-key", "--reveal")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(stdout, fakeMintedToken) {
		t.Fatalf("--reveal printed no plaintext — the leak arm's assertion cannot distinguish anything")
	}
	if !strings.Contains(stderr, "warning:") {
		t.Fatalf("--reveal printed the credential with no warning about capture:\n%s", stderr)
	}
}

// TestCloudTokenMintNoSinkRefusesBeforeMinting: with neither --out nor --reveal
// the command refuses, and — the load-bearing half — the control plane saw ZERO
// requests. A refusal that fires AFTER the POST would have burned a live,
// unrecoverable credential.
func TestCloudTokenMintNoSinkRefusesBeforeMinting(t *testing.T) {
	plane := newTokenPlane(t, 201, `{"token":"`+fakeMintedToken+`","pat":`+fakeMintedPAT+`}`)

	stdout, stderr, code := runToken(t, "table", "mint", "--name", "ci-key")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\nstdout:\n%s\nstderr:\n%s", code, exitUsage, stdout, stderr)
	}
	if len(plane.seen) != 0 {
		t.Fatalf("the sink refusal issued %d request(s) (%v) — a credential was minted and discarded", len(plane.seen), plane.seen)
	}
	if !strings.Contains(stderr, "--out") || !strings.Contains(stderr, "--reveal") {
		t.Fatalf("the refusal does not name either sink:\n%s", stderr)
	}
}

// TestCloudTokenMintRefusesExistingOutPath: --out onto an existing file is
// refused without minting. Truncating it would destroy a credential that is
// still live while revoking nothing.
func TestCloudTokenMintRefusesExistingOutPath(t *testing.T) {
	plane := newTokenPlane(t, 201, `{"token":"`+fakeMintedToken+`","pat":`+fakeMintedPAT+`}`)
	dest := filepath.Join(t.TempDir(), "already-there")
	if werr := os.WriteFile(dest, []byte("an older credential\n"), 0o600); werr != nil {
		t.Fatalf("seed: %v", werr)
	}

	_, stderr, code := runToken(t, "table", "mint", "--name", "ci-key", "--out", dest)
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\nstderr:\n%s", code, exitUsage, stderr)
	}
	if len(plane.seen) != 0 {
		t.Fatalf("the existing-path refusal still minted: %v", plane.seen)
	}
	raw, _ := os.ReadFile(dest)
	if string(raw) != "an older credential\n" {
		t.Fatalf("the existing file was modified — refusing to overwrite is the point")
	}
}

// TestCloudTokenMintJSONOmitsToken: the -o json envelope carries the ROW and the
// sink path, never the secret. A script reading `bp cloud token mint -o json`
// into a log must not have logged a credential.
func TestCloudTokenMintJSONOmitsToken(t *testing.T) {
	newTokenPlane(t, 201, `{"token":"`+fakeMintedToken+`","pat":`+fakeMintedPAT+`}`)
	dest := filepath.Join(t.TempDir(), "ci.token")

	stdout, stderr, code := runToken(t, "json", "mint", "--name", "ci-key", "--out", dest)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	assertNoPlaintext(t, "the -o json envelope", stdout)
	var env map[string]any
	if uerr := json.Unmarshal([]byte(stdout), &env); uerr != nil {
		t.Fatalf("-o json is not parseable: %v\n%s", uerr, stdout)
	}
	if _, has := env["token"]; has {
		t.Fatalf("the -o json envelope carries a `token` key without --reveal")
	}
	if env["written_to"] != dest {
		t.Fatalf("written_to = %v, want %q", env["written_to"], dest)
	}
}

// TestCloudTokenMintRoleCapNamed is the CRED-3 arm: the control plane's 403
// (a plain member minting `write`) is reported as the ROLE CAP, not as a bare
// "forbidden", and exits 3. The cap itself stays the server's — the CLI issued
// the request and let the plane decide.
func TestCloudTokenMintRoleCapNamed(t *testing.T) {
	plane := newTokenPlane(t, 403, `{"error":"forbidden","required":"admin","scope":"team"}`)
	dest := filepath.Join(t.TempDir(), "ci.token")

	_, stderr, code := runToken(t, "table", "mint", "--name", "ci-key", "--ability", "write", "--out", dest)
	if code != exitAuth {
		t.Fatalf("exit = %d, want exitAuth=%d\nstderr:\n%s", code, exitAuth, stderr)
	}
	// The CLI must have ASKED — pre-empting the role client-side is exactly what
	// m0 rule C2 forbids, and a client-side refusal would show zero requests.
	if len(plane.seen) != 1 || plane.seen[0] != "POST /v1/tokens" {
		t.Fatalf("the CLI did not put the request to the control plane: %v", plane.seen)
	}
	for _, want := range []string{"owner/admin", "`read`", "`write`"} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("the role-cap refusal does not name %q:\n%s", want, stderr)
		}
	}
	// And it must NOT leave a zero-byte file posing as a credential.
	if _, serrr := os.Stat(dest); serrr == nil {
		t.Fatalf("a failed mint left %s behind — a script would read it as a token", dest)
	}
}

// TestCloudTokenMintSessionOnly401: a PAT bearer on a session-only route gets
// 401, and the refusal says WHY (a PAT can never mint a PAT) instead of the
// generic "session expired".
func TestCloudTokenMintSessionOnly401(t *testing.T) {
	newTokenPlane(t, 401, `{"error":"unauthorized"}`)
	dest := filepath.Join(t.TempDir(), "ci.token")

	_, stderr, code := runToken(t, "table", "mint", "--name", "ci-key", "--out", dest)
	if code != exitAuth {
		t.Fatalf("exit = %d, want exitAuth=%d\nstderr:\n%s", code, exitAuth, stderr)
	}
	if !strings.Contains(stderr, "session-only") {
		t.Fatalf("the 401 refusal does not explain the session-only firewall:\n%s", stderr)
	}
}

// TestCloudTokenMintOffMenuExpiryRefused is the CRED-4 arm: 45 days is not on
// the plane's menu and would be SILENTLY rewritten to the default validity, so
// the CLI refuses rather than hand back a window nobody asked for — and issues
// no request while doing it.
func TestCloudTokenMintOffMenuExpiryRefused(t *testing.T) {
	plane := newTokenPlane(t, 201, `{"token":"`+fakeMintedToken+`","pat":`+fakeMintedPAT+`}`)
	dest := filepath.Join(t.TempDir(), "ci.token")

	_, stderr, code := runToken(t, "table", "mint", "--name", "n", "--expires-days", "45", "--out", dest)
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\nstderr:\n%s", code, exitUsage, stderr)
	}
	if len(plane.seen) != 0 {
		t.Fatalf("the off-menu expiry still minted: %v", plane.seen)
	}
	if !strings.Contains(stderr, "365") {
		t.Fatalf("the refusal does not name the accepted menu:\n%s", stderr)
	}
}

// TestCloudTokenMintOnMenuExpiryIsSent is the quiet control for the arm above:
// an ON-menu value passes through and reaches the wire as the integer the caller
// typed. Without it, "refuses 45" would also pass on a command that refused
// every value.
func TestCloudTokenMintOnMenuExpiryIsSent(t *testing.T) {
	var body []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ = readAllBody(r)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(201)
		_, _ = w.Write([]byte(`{"token":"` + fakeMintedToken + `","pat":` + fakeMintedPAT + `}`))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	dest := filepath.Join(t.TempDir(), "ci.token")

	_, stderr, code := runToken(t, "table", "mint", "--name", "n", "--expires-days", "90", "--out", dest)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	var sent map[string]any
	if uerr := json.Unmarshal(body, &sent); uerr != nil {
		t.Fatalf("request body not JSON: %v (%s)", uerr, body)
	}
	if sent["expires_in_days"] != float64(90) {
		t.Fatalf("expires_in_days = %v, want 90 — the caller's window did not reach the wire", sent["expires_in_days"])
	}
	if abilities, _ := sent["abilities"].([]any); len(abilities) != 1 || abilities[0] != "read" {
		t.Fatalf("abilities = %v, want the documented [read] default", sent["abilities"])
	}
}

// TestCloudTokenMintNeverExpiresSendsZero: `--expires-days never` must send 0,
// the plane's "no expiry" instruction, and NOT omit the key (which means the
// default validity — the opposite of what was asked).
func TestCloudTokenMintNeverExpiresSendsZero(t *testing.T) {
	var body []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ = readAllBody(r)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(201)
		_, _ = w.Write([]byte(`{"token":"` + fakeMintedToken + `","pat":` + fakeMintedPAT + `}`))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runToken(t, "table", "mint", "--name", "n", "--expires-days", "never", "--reveal")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	var sent map[string]any
	_ = json.Unmarshal(body, &sent)
	v, has := sent["expires_in_days"]
	if !has || v != float64(0) {
		t.Fatalf("expires_in_days = %v (present=%v), want 0 — `never` must be explicit, not an omitted key", v, has)
	}
}

// TestCloudTokenMintUnknownAbilityRefused: a typo is caught before the network.
func TestCloudTokenMintUnknownAbilityRefused(t *testing.T) {
	plane := newTokenPlane(t, 201, `{"token":"x","pat":`+fakeMintedPAT+`}`)
	_, stderr, code := runToken(t, "table", "mint", "--name", "n", "--ability", "admin", "--reveal")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\nstderr:\n%s", code, exitUsage, stderr)
	}
	if len(plane.seen) != 0 {
		t.Fatalf("the typo still reached the plane: %v", plane.seen)
	}
	if !strings.Contains(stderr, "deploy") {
		t.Fatalf("the refusal does not name the vocabulary:\n%s", stderr)
	}
}

// TestCloudTokenListRenders: the inventory renders and — by construction — has
// no secret to show.
func TestCloudTokenListRenders(t *testing.T) {
	newTokenPlane(t, 200, `{"tokens":[`+fakeMintedPAT+`,`+
		`{"id":"pat-2","name":"old","abilities":["read"],"revoked_at":"2026-09-01T00:00:00Z"}]}`)

	stdout, stderr, code := runToken(t, "table", "ls")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	for _, want := range []string{"pat-1", "ci-key", "write", "pat-2", "revoked", "active"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the inventory omits %q:\n%s", want, stdout)
		}
	}
}

// TestCloudTokenListUnreadableIsNotEmpty: a `tokens` value that is not the
// contract's array must not render as "(no personal access tokens)" — that would
// read as "nothing to revoke" on an account full of live credentials.
func TestCloudTokenListUnreadableIsNotEmpty(t *testing.T) {
	newTokenPlane(t, 200, `{"tokens":{"pat-1":{}}}`)

	stdout, _, code := runToken(t, "table", "ls")
	if code == exitOK {
		t.Fatalf("an unreadable inventory exited 0:\n%s", stdout)
	}
	if strings.Contains(stdout, "(no personal access tokens)") {
		t.Fatalf("an unreadable inventory rendered as an empty one:\n%s", stdout)
	}
}

// TestCloudTokenRevoke: the happy path, and the no-existence-leak 404.
func TestCloudTokenRevoke(t *testing.T) {
	plane := newTokenPlane(t, 200, `{"ok":true}`)
	stdout, stderr, code := runToken(t, "table", "revoke", "pat-1")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if len(plane.seen) != 1 || plane.seen[0] != "DELETE /v1/tokens/pat-1" {
		t.Fatalf("revoke hit %v", plane.seen)
	}
	if !strings.Contains(stdout, "Revoked") {
		t.Fatalf("no revoke receipt:\n%s", stdout)
	}
}

func TestCloudTokenRevokeNotFound(t *testing.T) {
	newTokenPlane(t, 404, `{"error":"not_found"}`)
	_, stderr, code := runToken(t, "table", "revoke", "nope")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want exitNotFound=%d\nstderr:\n%s", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "not yours") {
		t.Fatalf("the 404 does not state the no-existence-leak meaning:\n%s", stderr)
	}
}

// TestCloudTokenNotLoggedIn: with no cloud credential at all, every verb refuses
// with exit 3 and points at `bp login` — and says why a PAT will not do.
func TestCloudTokenNotLoggedIn(t *testing.T) {
	withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, "")
	if err := SaveConfig(&Config{}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	for _, args := range [][]string{{"ls"}, {"revoke", "pat-1"}, {"mint", "--name", "n", "--reveal"}} {
		_, stderr, code := runToken(t, "table", args...)
		if code != exitAuth {
			t.Fatalf("%v: exit = %d, want exitAuth=%d\nstderr:\n%s", args, code, exitAuth, stderr)
		}
		if !strings.Contains(stderr, "bp login") {
			t.Fatalf("%v: refusal does not point at `bp login`:\n%s", args, stderr)
		}
	}
}

// TestCloudTokenUnknownVerb keeps the router honest.
func TestCloudTokenUnknownVerb(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runToken(t, "table", "rotate")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\nstderr:\n%s", code, exitUsage, stderr)
	}
}

// readAllBody reads a request body without importing io at every call site.
func readAllBody(r *http.Request) ([]byte, error) {
	defer r.Body.Close()
	var buf bytes.Buffer
	_, err := buf.ReadFrom(r.Body)
	return buf.Bytes(), err
}
