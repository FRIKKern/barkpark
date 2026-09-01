package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// seedCloudLogin writes a config under the test's temp config home carrying a
// Cloud token + a control-plane URL, so the authed Cloud commands (barkparks /
// provider / launch / go-live) resolve a client pointed at the fake server.
func seedCloudLogin(t *testing.T, cloudURL string) {
	t.Helper()
	cfg := &Config{
		CloudURL:   cloudURL,
		CloudToken: "sess-abc",
		CloudTeam:  "team-1",
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

// fleetHits records which auto-register routes a fake control plane saw, so the
// steal-guard / headless-frozen tests can assert what did (and did NOT) fire.
type fleetHits struct {
	barkparks      int
	barkparksQuery string
	credentials    int
	credentialTeam string
	capabilities   int
}

// newFleetControlPlane stands up ONE httptest server that plays BOTH the control
// plane (GET /v1/barkparks, GET /v1/barkparks/:id/credentials) AND the picked
// barkpark itself (GET /v1/capabilities for the connect probe), so a single-fleet
// auto-connect resolves end-to-end against it. fleetBody is called at request time
// with the server's OWN url so a test can point the single barkpark back at this
// server (making the connect probe land). credsToken is the admin token
// /credentials returns (url = the server itself); a blank token makes /credentials
// 404 with no_admin_token.
func newFleetControlPlane(t *testing.T, hits *fleetHits, fleetBody func(self string) string, credsToken string) *httptest.Server {
	t.Helper()
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/barkparks":
			hits.barkparks++
			hits.barkparksQuery = r.URL.RawQuery
			_, _ = io.WriteString(w, fleetBody(srv.URL))
		case strings.HasSuffix(r.URL.Path, "/credentials"):
			hits.credentials++
			hits.credentialTeam = r.Header.Get("X-Barkpark-Team")
			if credsToken == "" {
				w.WriteHeader(http.StatusNotFound)
				_, _ = io.WriteString(w, `{"error":"no_admin_token"}`)
				return
			}
			_, _ = io.WriteString(w, `{"admin_token":"`+credsToken+`","url":"`+srv.URL+`","host":""}`)
		case r.URL.Path == "/v1/capabilities":
			hits.capabilities++
			_, _ = io.WriteString(w, `{"auth_tier":"admin","server":{"name":"my-park","version":"1.0"}}`)
		case r.URL.Path == "/v1/meta":
			_, _ = io.WriteString(w, `{"serverTime":"2026-07-09T00:00:00Z","minApiVersion":"1","maxApiVersion":"1"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// staticFleet returns a fleetBody func that ignores the server URL and always
// yields body — for the steal-guard / multi / zero cases that never connect back.
func staticFleet(body string) func(string) string {
	return func(string) string { return body }
}

// ttyWriter builds an in-memory writer that PRETENDS stdout is a terminal (isTTY)
// so the auto-register tail (finishLoginConnect) engages, while still capturing
// bytes into buffers for assertions.
func ttyWriter(stdout, stderr *bytes.Buffer) *writer {
	w := newWriter(stdout, stderr)
	w.output = "table"
	w.isTTY = true
	return w
}

// TestFinishLoginConnectSingleAutoConnects: a one-barkpark fleet on a TTY
// auto-connects — credentials are fetched, the connect path persists the server,
// and "Connected to <name> — <url>" announces it before the connect summary.
func TestFinishLoginConnectSingleAutoConnects(t *testing.T) {
	withTempConfigHome(t)

	// ONE server plays control plane AND the picked barkpark: the single fleet
	// entry's URL is the server itself, so the connect probe (GET /v1/capabilities)
	// lands right back here. The fleet body is stamped after the server exists.
	var hits fleetHits
	srv := newFleetControlPlane(t, &hits, func(self string) string {
		return `{"barkparks":[{"id":"bp-1","name":"my-park","url":"` + self + `"}]}`
	}, "admin-secret")

	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)
	finishLoginConnect(out, cfg)

	if hits.barkparks == 0 {
		t.Fatalf("auto-register must list the fleet")
	}
	if hits.credentials == 0 {
		t.Fatalf("a single barkpark must have its credentials fetched")
	}
	if !bytes.Contains(stdout.Bytes(), []byte("Connected to my-park")) {
		t.Fatalf("missing the 'Connected to <name>' announcement:\n%s", stdout.String())
	}
	if !bytes.Contains(stdout.Bytes(), []byte("run 'bp'")) {
		t.Fatalf("missing the next-step 'run bp' hint:\n%s", stdout.String())
	}
	loaded, _ := LoadConfig()
	if normalizeServerURL(loaded.ActiveServer()) != normalizeServerURL(srv.URL) {
		t.Fatalf("connect must default bp at the barkpark; active = %q, want %q", loaded.ActiveServer(), srv.URL)
	}
	if e, ok := loaded.FindServer(srv.URL); !ok || e.Token != "admin-secret" {
		t.Fatalf("admin token must be saved as the server token; entry = %+v ok=%v", e, ok)
	}
}

func TestFinishLoginConnectSingleSecondaryTeamSendsCredentialTeam(t *testing.T) {
	withTempConfigHome(t)
	var hits fleetHits
	srv := newFleetControlPlane(t, &hits, func(self string) string {
		return `{"barkparks":[{"id":"bp-2","name":"docs","url":"` + self + `","team":{"id":"team-docs","name":"Docs","role":"admin"}}]}`
	}, "admin-secret")
	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-primary"}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	var stdout, stderr bytes.Buffer
	finishLoginConnect(ttyWriter(&stdout, &stderr), cfg)
	if hits.barkparksQuery != "scope=all" {
		t.Fatalf("fleet query = %q, want scope=all", hits.barkparksQuery)
	}
	if hits.credentials != 1 || hits.credentialTeam != "team-docs" {
		t.Fatalf("credential request count/team = %d/%q, want 1/team-docs", hits.credentials, hits.credentialTeam)
	}
}

// TestFinishLoginConnectDeskOfferWiredAfterAutoConnect: on a genuine both-streams
// terminal a successful single-barkpark auto-connect ends with the Enter-to-desk
// offer — a bare Enter propagates the ExitOpenDesk sentinel out of
// finishLoginConnect (main() turns it into runTUI in-process), and typing n
// declines to a plain exitOK with the reminder. This is the decision-23 wiring
// proof: offerOpenDesk is not a dead seam.
func TestFinishLoginConnectDeskOfferWiredAfterAutoConnect(t *testing.T) {
	cases := []struct {
		name  string
		stdin string
		want  int
	}{
		{"bare Enter opens the desk", "\n", ExitOpenDesk},
		{"n stays put", "n\n", exitOK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			forceDeviceTTY(t, true) // both streams a terminal → the offer fires

			var hits fleetHits
			srv := newFleetControlPlane(t, &hits, func(self string) string {
				return `{"barkparks":[{"id":"bp-1","name":"my-park","url":"` + self + `"}]}`
			}, "admin-secret")

			cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
			if err := SaveConfig(cfg); err != nil {
				t.Fatalf("SaveConfig: %v", err)
			}

			var stdout, stderr bytes.Buffer
			out := ttyWriter(&stdout, &stderr)

			var code int
			withStdin(t, tc.stdin, func() { code = finishLoginConnect(out, cfg) })

			if code != tc.want {
				t.Fatalf("finishLoginConnect = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, tc.want, stdout.String(), stderr.String())
			}
			if hits.credentials == 0 {
				t.Fatal("the auto-connect must have run before the offer")
			}
			if !bytes.Contains(stderr.Bytes(), []byte("open the desk")) {
				t.Fatalf("the desk offer should have prompted on stderr:\n%s", stderr.String())
			}
			if tc.want == exitOK && !bytes.Contains(stdout.Bytes(), []byte("Run 'bp'")) {
				t.Fatalf("declining should leave the 'Run bp' reminder:\n%s", stdout.String())
			}
		})
	}
}

// TestFinishLoginConnectStealGuardLeavesActiveServer: with bp already connected to
// a DIFFERENT saved server, a single-barkpark fleet does NOT silently re-point bp
// — it reports and leaves c.Server untouched, never fetching credentials.
func TestFinishLoginConnectStealGuardLeavesActiveServer(t *testing.T) {
	withTempConfigHome(t)

	var hits fleetHits
	oneFleet := `{"barkparks":[{"id":"bp-1","name":"my-park","url":"https://mypark.example.com"}]}`
	srv := newFleetControlPlane(t, &hits, staticFleet(oneFleet), "admin-secret")

	// Seed a DIFFERENT active saved server (the one bp is currently pointed at).
	seed := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	seed.RememberServer(ServerEntry{
		Name: "other", Server: "https://other.example.com", Token: "other-tok",
		Tier: "admin", LastConnected: "2026-06-06T00:00:00Z",
	})
	if err := SaveConfig(seed); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)

	finishLoginConnect(out, cfg)

	if hits.credentials != 0 {
		t.Fatalf("steal-guard must NOT fetch credentials on the different-server branch; got %d hits", hits.credentials)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("leaving that as is")) {
		t.Fatalf("steal-guard should report it left the active server alone:\n%s", stdout.String())
	}
	loaded, _ := LoadConfig()
	if normalizeServerURL(loaded.ActiveServer()) != normalizeServerURL("https://other.example.com") {
		t.Fatalf("c.Server must be UNTOUCHED on the report branch; active = %q", loaded.ActiveServer())
	}
	if e, ok := loaded.FindServer("https://other.example.com"); !ok || e.Token != "other-tok" {
		t.Fatalf("the active server's token must survive; entry=%+v ok=%v", e, ok)
	}
}

// TestFinishLoginConnectMultiNonTTYPrintsFleet: a many-barkpark fleet with stdin
// NOT a terminal never prompts — it prints the fleet plus a one-line connect
// command and connects nothing (no credentials fetched).
func TestFinishLoginConnectMultiNonTTYPrintsFleet(t *testing.T) {
	withTempConfigHome(t)
	forceDeviceTTY(t, false) // stdin is NOT a terminal → no interactive pick

	var hits fleetHits
	twoFleet := `{"barkparks":[{"id":"bp-1","name":"shared","url":"https://alpha.example.com","team":{"id":"team-1","name":"Primary","role":"owner"}},{"id":"bp-2","name":"shared","host":"beta.example.com","team":{"id":"team-2","name":"Docs","role":"admin"}}]}`
	srv := newFleetControlPlane(t, &hits, staticFleet(twoFleet), "admin-secret")

	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)

	finishLoginConnect(out, cfg)

	if hits.credentials != 0 {
		t.Fatalf("no interactive pick → no credentials fetch; got %d", hits.credentials)
	}
	for _, want := range []string{"shared · Primary", "shared · Docs", "https://alpha.example.com", "beta.example.com", "bp setup --target cloud"} {
		if !bytes.Contains(stdout.Bytes(), []byte(want)) {
			t.Fatalf("multi non-tty fleet listing missing %q:\n%s", want, stdout.String())
		}
	}
	loaded, _ := LoadConfig()
	if loaded.ActiveServer() != "" {
		t.Fatalf("nothing should be connected on the print-only path; active=%q", loaded.ActiveServer())
	}
}

// TestFinishLoginConnectZeroFleetGuidance: an empty fleet finishes logged-in with
// launch/deploy guidance (never a dead end, never a connect).
func TestFinishLoginConnectZeroFleetGuidance(t *testing.T) {
	withTempConfigHome(t)

	var hits fleetHits
	srv := newFleetControlPlane(t, &hits, staticFleet(`{"barkparks":[]}`), "admin-secret")

	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)

	finishLoginConnect(out, cfg)

	if hits.credentials != 0 {
		t.Fatalf("an empty fleet has nothing to fetch; got %d", hits.credentials)
	}
	for _, want := range []string{"don't have any Barkparks yet", "bp launch hetzner", "bp go-live"} {
		if !bytes.Contains(stdout.Bytes(), []byte(want)) {
			t.Fatalf("empty-fleet guidance missing %q:\n%s", want, stdout.String())
		}
	}
}

// TestFinishLoginConnectHeadlessFrozen: on the machine-output path (and on a
// non-tty) finishLoginConnect is a complete no-op — it never even lists the fleet,
// so the -o json contract carries no auto-register side effect.
func TestFinishLoginConnectHeadlessFrozen(t *testing.T) {
	withTempConfigHome(t)

	var hits fleetHits
	srv := newFleetControlPlane(t, &hits, staticFleet(`{"barkparks":[{"id":"bp-1","name":"my-park","url":"https://x"}]}`), "admin-secret")

	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}

	// (a) json output, even with isTTY true → frozen.
	var o1, e1 bytes.Buffer
	w1 := newWriter(&o1, &e1)
	w1.output = "json"
	w1.isTTY = true
	finishLoginConnect(w1, cfg)

	// (b) table output but NOT a tty (a pipe) → frozen.
	var o2, e2 bytes.Buffer
	w2 := newWriter(&o2, &e2)
	w2.output = "table"
	w2.isTTY = false
	finishLoginConnect(w2, cfg)

	if hits.barkparks != 0 {
		t.Fatalf("headless / non-tty must never auto-register; barkparks hit %d times", hits.barkparks)
	}
	if o1.Len() != 0 || o2.Len() != 0 {
		t.Fatalf("frozen path must print nothing on stdout; got %q / %q", o1.String(), o2.String())
	}
}

// TestFinishLoginConnectSameServerReconnects: when bp is ALREADY connected to the
// one barkpark, the steal-guard falls through (not a report) — it fetches a FRESH
// admin token and reconnects, announcing it. Proves the same-server branch.
func TestFinishLoginConnectSameServerReconnects(t *testing.T) {
	withTempConfigHome(t)

	var hits fleetHits
	srv := newFleetControlPlane(t, &hits, func(self string) string {
		return `{"barkparks":[{"id":"bp-1","name":"my-park","url":"` + self + `"}]}`
	}, "fresh-admin-token")

	// Pre-seed the SAME server as active but with a STALE token.
	seed := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	seed.RememberServer(ServerEntry{Name: "my-park", Server: srv.URL, Token: "stale-token", Tier: "admin", LastConnected: "2026-06-06T00:00:00Z"})
	if err := SaveConfig(seed); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)

	finishLoginConnect(out, cfg)

	if hits.credentials == 0 {
		t.Fatalf("same-server reconnect must fetch a fresh admin token")
	}
	if !bytes.Contains(stdout.Bytes(), []byte("Connected to my-park")) {
		t.Fatalf("same-server reconnect should announce + connect (not report):\n%s", stdout.String())
	}
	loaded, _ := LoadConfig()
	if e, ok := loaded.FindServer(srv.URL); !ok || e.Token != "fresh-admin-token" {
		t.Fatalf("reconnect must refresh the stored token to the fresh one; entry=%+v ok=%v", e, ok)
	}
}

// TestFinishLoginConnectFleetErrorWarns: a fleet-resolution failure AFTER a good
// login is a stderr warning, never a failure — finishLoginConnect prints nothing
// on stdout, warns on stderr, and mutates no config (the login already succeeded).
func TestFinishLoginConnectFleetErrorWarns(t *testing.T) {
	withTempConfigHome(t)

	var hits fleetHits
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/barkparks" {
			hits.barkparks++
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = io.WriteString(w, `{"error":"registry unavailable"}`)
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}
	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)

	finishLoginConnect(out, cfg)

	if hits.barkparks == 0 {
		t.Fatalf("the fleet lookup should have been attempted")
	}
	if stdout.Len() != 0 {
		t.Fatalf("a fleet error must not print to stdout; got %q", stdout.String())
	}
	if !bytes.Contains(stderr.Bytes(), []byte("couldn't reach your fleet")) {
		t.Fatalf("a fleet error should warn on stderr:\n%s", stderr.String())
	}
	loaded, _ := LoadConfig()
	if loaded.ActiveServer() != "" {
		t.Fatalf("a fleet error must not connect anything; active=%q", loaded.ActiveServer())
	}
}

// TestLoginWritesCloudToken drives `bp login --email … --password … --url <fake>`
// against a fake control plane and asserts the token + URL land in the temp
// config, and the success line prints.
func TestLoginWritesCloudToken(t *testing.T) {
	withTempConfigHome(t)

	var gotPath, gotAuth string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		_, _ = io.WriteString(w, `{"token":"sess-xyz","team_id":"team-9"}`)
	}))
	defer srv.Close()

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLoginCloud(out, []string{
			"--email", "a@b.com",
			"--password", "hunter2",
			"--url", srv.URL,
		})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/auth/login" {
		t.Fatalf("login hit %q, want /v1/auth/login", gotPath)
	}
	if gotAuth != "" {
		t.Fatalf("login must be unauthed; got %q", gotAuth)
	}
	if gotBody["email"] != "a@b.com" || gotBody["password"] != "hunter2" {
		t.Fatalf("login body = %v", gotBody)
	}

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.CloudToken != "sess-xyz" {
		t.Fatalf("CloudToken = %q, want sess-xyz", cfg.CloudToken)
	}
	if cfg.CloudURL != srv.URL {
		t.Fatalf("CloudURL = %q, want %q", cfg.CloudURL, srv.URL)
	}
	if cfg.CloudTeam != "team-9" {
		t.Fatalf("CloudTeam = %q, want team-9", cfg.CloudTeam)
	}
	if !bytes.Contains([]byte(stdout), []byte("logged in")) {
		t.Fatalf("expected a success line:\n%s", stdout)
	}
}

// TestLoginBadCredsExitsAuth: a 401 from the control plane is an auth error
// (exit 3) and writes NO token to config.
func TestLoginBadCredsExitsAuth(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid_credentials"}`)
	}))
	defer srv.Close()

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLoginCloud(out, []string{"--email", "a@b.com", "--password", "x", "--url", srv.URL})
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !bytes.Contains([]byte(stderr), []byte("invalid_credentials")) {
		t.Fatalf("stderr should surface the auth message:\n%s", stderr)
	}
	cfg, _ := LoadConfig()
	if cfg.CloudToken != "" {
		t.Fatalf("a failed login must not persist a token; got %q", cfg.CloudToken)
	}
}

// withStdin points os.Stdin at a pipe pre-filled with the given text for the
// duration of fn, so the non-TTY promptPassword/promptLine line-reads pull
// scripted input. Restores the real stdin afterwards.
func withStdin(t *testing.T, text string, fn func()) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	if _, err := io.WriteString(w, text); err != nil {
		t.Fatalf("write stdin: %v", err)
	}
	_ = w.Close()
	orig := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = orig; _ = r.Close() })
	fn()
}

// TestSignupWritesCloudToken drives `bp signup --email … --password … --team … --url <fake>`
// against a fake control plane and asserts the register body, the 201 token + URL
// landing in the temp config, and the success line.
func TestSignupWritesCloudToken(t *testing.T) {
	withTempConfigHome(t)

	var gotPath, gotAuth string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"token":"sess-new","team_id":"team-7"}`)
	}))
	defer srv.Close()

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSignupCloud(out, []string{
			"--email", "ada@x.com",
			"--password", "hunter2pw!",
			"--team", "ada",
			"--url", srv.URL,
		})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/auth/register" {
		t.Fatalf("signup hit %q, want /v1/auth/register", gotPath)
	}
	if gotAuth != "" {
		t.Fatalf("signup must be unauthed; got %q", gotAuth)
	}
	if gotBody["email"] != "ada@x.com" || gotBody["password"] != "hunter2pw!" || gotBody["team_name"] != "ada" {
		t.Fatalf("signup body = %v", gotBody)
	}

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.CloudToken != "sess-new" {
		t.Fatalf("CloudToken = %q, want sess-new", cfg.CloudToken)
	}
	if cfg.CloudURL != srv.URL {
		t.Fatalf("CloudURL = %q, want %q", cfg.CloudURL, srv.URL)
	}
	if cfg.CloudTeam != "team-7" {
		t.Fatalf("CloudTeam = %q, want team-7", cfg.CloudTeam)
	}
	if !bytes.Contains([]byte(stdout), []byte("account created")) {
		t.Fatalf("expected a success line:\n%s", stdout)
	}
}

// TestSignup409SurfacesLoginHint: a 409 email_taken surfaces the "run bp login"
// hint and writes NO token to config.
func TestSignup409SurfacesLoginHint(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"error":"email_taken"}`)
	}))
	defer srv.Close()

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSignupCloud(out, []string{"--email", "ada@x.com", "--password", "hunter2pw!", "--url", srv.URL})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	if !bytes.Contains([]byte(stderr), []byte("bp login")) {
		t.Fatalf("stderr should surface the login hint:\n%s", stderr)
	}
	cfg, _ := LoadConfig()
	if cfg.CloudToken != "" {
		t.Fatalf("a 409 signup must not persist a token; got %q", cfg.CloudToken)
	}
}

// TestSignup422SurfacesValidation: a 422 surfaces the validation message verbatim
// and writes NO token.
func TestSignup422SurfacesValidation(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"password_invalid"}`)
	}))
	defer srv.Close()

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSignupCloud(out, []string{"--email", "ada@x.com", "--password", "weak", "--url", srv.URL})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	if !bytes.Contains([]byte(stderr), []byte("password_invalid")) {
		t.Fatalf("stderr should surface the validation message:\n%s", stderr)
	}
	cfg, _ := LoadConfig()
	if cfg.CloudToken != "" {
		t.Fatalf("a 422 signup must not persist a token; got %q", cfg.CloudToken)
	}
}

// TestSignupPostCommitTransportDropRecoversHonestly: when POST /v1/auth/register
// drops in transport (the connection fails with no HTTP status — the account may
// already have been committed server-side), runSignupCloud must NOT print a bare
// "signup failed: <transport>" that strands a possibly-created account. It takes
// the recovery path: an honest receipt naming that the account may already exist
// and advising `bp login` with the same credentials — and it writes NO config.
// The transport failure is injected by closing the test server before the call,
// so the client dials a dead address (a real transport error, never a
// *cloudclient.CloudRefusal, which is exactly the seam runSignupCloud keys on).
func TestSignupPostCommitTransportDropRecoversHonestly(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	deadURL := srv.URL
	srv.Close() // dialing deadURL now fails in transport — no HTTP status is ever returned

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSignupCloud(out, []string{"--email", "ada@x.com", "--password", "hunter2pw!", "--url", deadURL})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	// The recovery copy names the ambiguous state and advises login with the same
	// creds — never the bare "signup failed:" line.
	if bytes.Contains([]byte(stderr), []byte("signup failed:")) {
		t.Fatalf("transport drop must NOT print the bare 'signup failed:' line:\n%s", stderr)
	}
	for _, want := range []string{"may already have been created", "bp login --email ada@x.com", "same password"} {
		if !bytes.Contains([]byte(stderr), []byte(want)) {
			t.Fatalf("recovery receipt missing %q:\n%s", want, stderr)
		}
	}
	// Fail closed: no session is minted from an unconfirmed register.
	cfg, _ := LoadConfig()
	if cfg.CloudToken != "" {
		t.Fatalf("a transport-dropped signup must not persist a token; got %q", cfg.CloudToken)
	}
}

// A server REFUSAL (a CloudRefusal — it carries an HTTP status) must NEVER take the
// ambiguous post-commit recovery path: the server said no, so nothing was committed,
// and "your account may already have been created" is the transport-drop copy's own
// failure mode in reverse. Pins the errors.As seam in the WIDENING direction.
func TestSignupRefusalNeverClaimsAmbiguity(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
	}{
		{"422 validation", `{"error":"password_invalid"}`, http.StatusUnprocessableEntity},
		{"401 unauthorized", `{"error":"nope"}`, http.StatusUnauthorized},
		{"500 server error", `{"error":"boom"}`, http.StatusInternalServerError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer srv.Close()
			_, stderr, _ := runCloudCapture(t, false, func(out *writer) int {
				out.output = "table"
				return runSignupCloud(out, []string{"--email", "ada@x.com", "--password", "weak", "--url", srv.URL})
			})
			if bytes.Contains([]byte(stderr), []byte("may already have been created")) {
				t.Fatalf("a %d REFUSAL must not claim the account may exist:\n%s", tc.status, stderr)
			}
		})
	}
}

// TestSignupTransportRecoveryKeepsNonDefaultURL: the recovery receipt is only
// actionable if the login hint reaches the SAME control plane. This path never
// persists CloudURL, so a first signup against a non-default host must carry the
// --url through — otherwise `bp login` resolves to the baked default, fails, and
// the copy's own next clause tells the user their account was not created when it
// may well have been. Against the default host the flag is redundant and omitted.
func TestSignupTransportRecoveryKeepsNonDefaultURL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	deadURL := srv.URL
	srv.Close() // dialing deadURL now fails in transport — no HTTP status is ever returned

	withTempConfigHome(t)
	_, stderr, _ := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSignupCloud(out, []string{"--email", "ada@x.com", "--password", "hunter2pw!", "--url", deadURL})
	})
	if !bytes.Contains([]byte(stderr), []byte("bp login --email ada@x.com --url "+deadURL)) {
		t.Fatalf("recovery receipt must send the user back to the SAME control plane %s:\n%s", deadURL, stderr)
	}

	if got := signupTransportRecoveryMessage("ada@x.com", cloudclient.DefaultBaseURL, "EOF"); strings.Contains(got, "--url") {
		t.Fatalf("the default control plane needs no --url in the login hint:\n%s", got)
	}
}

// TestSignupConfirmMismatchNeverCallsServer: the prompted password is typed twice
// and the two differ → signup errors BEFORE any network call. We stand up a
// counting server and assert it received ZERO requests.
func TestSignupConfirmMismatchNeverCallsServer(t *testing.T) {
	withTempConfigHome(t)

	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"token":"should-never-be-used","team_id":"team-x"}`)
	}))
	defer srv.Close()

	// No --password / no BARKPARK_PASSWORD → the interactive prompt path. Two
	// mismatched lines feed the password + confirm prompts.
	t.Setenv("BARKPARK_PASSWORD", "")
	var stderr string
	var code int
	withStdin(t, "firstpass\nsecondpass\n", func() {
		_, stderr, code = runCloudCapture(t, false, func(out *writer) int {
			out.output = "table"
			return runSignupCloud(out, []string{"--email", "ada@x.com", "--url", srv.URL})
		})
	})
	if code != exitUsage {
		t.Fatalf("confirm mismatch should be a usage error; exit = %d, want %d\n%s", code, exitUsage, stderr)
	}
	if !bytes.Contains([]byte(stderr), []byte("do not match")) {
		t.Fatalf("stderr should explain the mismatch:\n%s", stderr)
	}
	if hits != 0 {
		t.Fatalf("confirm mismatch must not reach the server; got %d request(s)", hits)
	}
	cfg, _ := LoadConfig()
	if cfg.CloudToken != "" {
		t.Fatalf("no token must be written on a mismatch; got %q", cfg.CloudToken)
	}
}

// TestSignupRequiresEmail: no --email and a non-TTY stdin that yields an empty
// line → a usage error, no network call.
func TestSignupRequiresEmail(t *testing.T) {
	withTempConfigHome(t)

	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
	}))
	defer srv.Close()

	var code int
	var stderr string
	withStdin(t, "\n", func() {
		_, stderr, code = runCloudCapture(t, false, func(out *writer) int {
			out.output = "table"
			return runSignupCloud(out, []string{"--password", "hunter2pw!", "--url", srv.URL})
		})
	})
	if code != exitUsage {
		t.Fatalf("missing email should be a usage error; exit = %d, want %d\n%s", code, exitUsage, stderr)
	}
	if hits != 0 {
		t.Fatalf("missing email must not reach the server; got %d request(s)", hits)
	}
}

// TestBarkparksHitsControlPlane: with a Cloud token saved, `bp barkparks` queries
// the fake control plane (Bearer attached) and renders the fleet table.
func TestBarkparksHitsControlPlane(t *testing.T) {
	withTempConfigHome(t)

	var gotAuth, gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("Authorization"), r.URL.Path
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"bp-1","name":"prod","slug":"prod","provider":"hetzner","url":"https://prod.example.com","host":"prod.example.com","mode":"managed","health_status":"up","agent_status":"online","team_id":"team-1"},
			{"id":"bp-2","name":"staging","slug":"staging","provider":"azure","host":"staging.example.com","mode":"byo","health_status":"unknown","agent_status":"offline","team_id":"team-1"}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/barkparks" {
		t.Fatalf("hit %q, want /v1/barkparks", gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	// The rendered table carries the authoritative rows plus the neutral vocabulary
	// (S10 activation, Decision 34): a PROVIDER identity column (hetzner/azure) and
	// a STATUS column folded to the S4 lifecycle vocabulary (both boxes have a host
	// → live). HEALTH/AGENT stay; the staging row's URL falls back to its host.
	for _, want := range []string{
		"prod", "https://prod.example.com", "up", "online",
		"staging", "staging.example.com", "HEALTH", "AGENT",
		"PROVIDER", "STATUS", "hetzner", "azure", "live",
	} {
		if !bytes.Contains([]byte(stdout), []byte(want)) {
			t.Fatalf("rendered table missing %q:\n%s", want, stdout)
		}
	}
	// It must NOT fall back to the local-config "no Barkparks known" hint.
	if bytes.Contains([]byte(stdout), []byte("register ssh")) {
		t.Fatalf("token present must use the control plane, not the local hint:\n%s", stdout)
	}
}

func TestBarkparksAllHitsCrossTeamScope(t *testing.T) {
	withTempConfigHome(t)

	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"bp-1","name":"prod","slug":"prod","provider":"hetzner","host":"prod.example.com","team_id":"team-1","team":{"id":"team-1","name":"Primary","slug":"primary","role":"owner"}},
			{"id":"bp-2","name":"docs","slug":"docs","provider":"azure","host":"docs.example.com","team_id":"team-2","team":{"id":"team-2","name":"Docs","slug":"docs","role":"member"}}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"--all"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotQuery != "scope=all" {
		t.Fatalf("query = %q, want scope=all", gotQuery)
	}
	for _, want := range []string{"TEAM", "Primary", "Docs", "prod", "docs"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("cross-team table missing %q:\n%s", want, stdout)
		}
	}

	jsonOut, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "json"
		return runBarkparks(out, []string{"--all"})
	})
	if code != exitOK {
		t.Fatalf("json exit = %d, want 0\n%s", code, jsonOut)
	}
	var payload struct {
		Barkparks []struct {
			Team struct {
				Slug string `json:"slug"`
				Role string `json:"role"`
			} `json:"team"`
		} `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(jsonOut), &payload); err != nil {
		t.Fatalf("decode cross-team json: %v\n%s", err, jsonOut)
	}
	if len(payload.Barkparks) != 2 || payload.Barkparks[1].Team.Slug != "docs" || payload.Barkparks[1].Team.Role != "member" {
		t.Fatalf("cross-team json missing team envelope: %+v", payload)
	}
}

func TestExecuteBarkparksAllHitsCrossTeamScope(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{name: "after noun", args: []string{"barkparks", "--all", "-o", "json"}},
		{name: "before noun", args: []string{"--all", "barkparks", "-o", "json"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)

			var gotAuth, gotPath, gotQuery string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				gotAuth = r.Header.Get("Authorization")
				gotPath = r.URL.Path
				gotQuery = r.URL.RawQuery
				_, _ = io.WriteString(w, `{"barkparks":[
					{"id":"bp-1","name":"prod","team_id":"team-1","team":{"id":"team-1","name":"Primary","slug":"primary","role":"owner"}},
					{"id":"bp-2","name":"docs","team_id":"team-2","team":{"id":"team-2","name":"Docs","slug":"docs","role":"member"}}
				]}`)
			}))
			defer srv.Close()
			seedCloudLogin(t, srv.URL)

			out, code := captureExecuteCode(t, tc.args)
			if code != exitOK {
				t.Fatalf("Execute(%v) exit = %d, want 0\n%s", tc.args, code, out)
			}
			if gotPath != "/v1/barkparks" || gotQuery != "scope=all" {
				t.Fatalf("Execute(%v) requested %q?%s, want /v1/barkparks?scope=all", tc.args, gotPath, gotQuery)
			}
			if gotAuth != "Bearer sess-abc" {
				t.Fatalf("Execute(%v) auth = %q, want Bearer sess-abc", tc.args, gotAuth)
			}
			var payload struct {
				Barkparks []struct {
					Name string `json:"name"`
					Team struct {
						Slug string `json:"slug"`
						Role string `json:"role"`
					} `json:"team"`
				} `json:"barkparks"`
			}
			if err := json.Unmarshal([]byte(out), &payload); err != nil {
				t.Fatalf("Execute(%v) decode cross-team output: %v\n%s", tc.args, err, out)
			}
			if len(payload.Barkparks) != 2 || payload.Barkparks[1].Name != "docs" || payload.Barkparks[1].Team.Slug != "docs" || payload.Barkparks[1].Team.Role != "member" {
				t.Fatalf("Execute(%v) missing cross-team envelope: %+v", tc.args, payload)
			}
		})
	}
}

func TestExecuteBarkparksDefaultStaysCurrentTeam(t *testing.T) {
	withTempConfigHome(t)

	var gotAuth, gotPath, gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		_, _ = io.WriteString(w, `{"barkparks":[]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	out, code := captureExecuteCode(t, []string{"barkparks", "-o", "json"})
	if code != exitOK {
		t.Fatalf("Execute(barkparks) exit = %d, want 0\n%s", code, out)
	}
	if gotPath != "/v1/barkparks" || gotQuery != "" {
		t.Fatalf("Execute(barkparks) requested %q?%s, want current-team /v1/barkparks with no query", gotPath, gotQuery)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("Execute(barkparks) auth = %q, want Bearer sess-abc", gotAuth)
	}
}

func TestExecuteBarkparksKindStaysLocalWithCloudSession(t *testing.T) {
	withTempConfigHome(t)

	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = io.WriteString(w, `{"barkparks":[]}`)
	}))
	defer srv.Close()

	seedTwoBarkparks(t)
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	cfg.CloudURL = srv.URL
	cfg.CloudToken = "sess-abc"
	cfg.CloudTeam = "team-1"
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	out, code := captureExecuteCode(t, []string{"barkparks", "--kind", "local", "-o", "json"})
	if code != exitOK {
		t.Fatalf("Execute(barkparks --kind local) exit = %d, want 0\n%s", code, out)
	}
	var payload struct {
		Source    string `json:"source"`
		Barkparks []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
			Kind string `json:"kind"`
		} `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("decode local barkparks output: %v\n%s", err, out)
	}
	if payload.Source != "local-config" || len(payload.Barkparks) != 1 ||
		payload.Barkparks[0].Name != "dev" || payload.Barkparks[0].URL != "http://localhost:4000" ||
		payload.Barkparks[0].Kind != "local" {
		t.Fatalf("explicit --kind did not preserve the local-config view: %+v", payload)
	}
	if got := hits.Load(); got != 0 {
		t.Fatalf("explicit --kind made %d control-plane request(s), want zero", got)
	}
}

func TestExecuteBarkparksAllRejectsKind(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://cloud.invalid")

	out, code := captureExecuteCode(t, []string{"barkparks", "--all", "--kind", "cloud"})
	if code != exitUsage {
		t.Fatalf("Execute(barkparks --all --kind cloud) exit = %d, want %d\n%s", code, exitUsage, out)
	}
	if !strings.Contains(out, "--all cannot be combined with --kind") {
		t.Fatalf("missing --all/--kind usage error:\n%s", out)
	}
}

func TestExecuteBarkparksHelpDocumentsScopeContract(t *testing.T) {
	out, code := captureExecuteCode(t, []string{"barkparks", "--help"})
	if code != exitOK {
		t.Fatalf("Execute(barkparks --help) exit = %d, want 0\n%s", code, out)
	}
	for _, want := range []string{
		"current team's",
		"control-plane fleet",
		"every authorized team membership",
		"includes the owning team",
		"--kind local|cloud",
		"reads local config and makes no network call",
		"requires login and cannot be combined with --kind",
		"-o json|yaml",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("barkparks help missing %q:\n%s", want, out)
		}
	}
}

// TestRegistryLifecycleToken pins the Go port of the SPA's lifecyclePillState
// (app.js:674-682 over instanceLifecycle :2375-2383): the same boolean ladder,
// the same precedence, the same "" fall-through. The first six cases MIRROR the
// SPA's own __app.test.mjs lifecyclePillState assertions verbatim so the two
// surfaces provably fold identical inputs to the same S4 state (Decision 34);
// the rest lock the precedence corners.
func TestRegistryLifecycleToken(t *testing.T) {
	cases := []struct {
		name string
		b    cloudclient.Barkpark
		want string
	}{
		// Cross-surface parity with __app.test.mjs (lifecyclePillState).
		{"live: has host", cloudclient.Barkpark{Host: "h"}, "live"},
		{"provisioning: no host, not failed", cloudclient.Barkpark{}, "provisioning"},
		{"degraded: provision failed, no host", cloudclient.Barkpark{ProvisionStatus: "failed"}, "degraded"},
		{"degraded: deprovision failed even with host", cloudclient.Barkpark{DeprovisionStatus: "failed", Host: "h"}, "degraded"},
		{"stopped: suspended with host", cloudclient.Barkpark{Host: "h", Suspended: true}, "stopped"},
		{"decommissioned: deprovision pending with host", cloudclient.Barkpark{DeprovisionStatus: "pending", Host: "h"}, "decommissioned"},
		// Precedence corners beyond the SPA test.
		{"decommissioned: deprovision claimed", cloudclient.Barkpark{DeprovisionStatus: "claimed"}, "decommissioned"},
		{"removing wins over suspended", cloudclient.Barkpark{DeprovisionStatus: "pending", Suspended: true, Host: "h"}, "decommissioned"},
		{"live: provision failed but host present is not failed", cloudclient.Barkpark{ProvisionStatus: "failed", Host: "h"}, "live"},
		{"suspended fold needs a host to not be provisioning-first? no — suspended beats provisioning", cloudclient.Barkpark{Suspended: true}, "stopped"},
	}
	for _, c := range cases {
		if got := registryLifecycleToken(c.b); got != c.want {
			t.Errorf("%s: registryLifecycleToken = %q, want %q", c.name, got, c.want)
		}
	}
}

// TestBarkparksFleetTableGolden pins the migrated control-plane fleet table
// (renderCloudBarkparksTable → the shared renderHzTable) with a mixed-provider,
// mixed-lifecycle fleet: the PROVIDER identity column and the STATUS lifecycle
// column are present and folded, and — color OFF (the test writer is not a tty) —
// the bytes are stable. A pre-migration row (blank provider) renders the house
// em-dash (hzCell, like every other cloud table) rather than guessing — and a
// dashed cell never paints (the tinters key on exact vocabulary values).
func TestBarkparksFleetTableGolden(t *testing.T) {
	list := []cloudclient.Barkpark{
		{Name: "prod", Provider: "hetzner", URL: "https://prod.example.com", Host: "prod.example.com", Mode: "managed", HealthStatus: "up", AgentStatus: "online"},
		{Name: "spinning", Provider: "azure", Mode: "managed", HealthStatus: "unknown", AgentStatus: "offline"},
		{Name: "broken", Provider: "hetzner", ProvisionStatus: "failed", Mode: "managed", HealthStatus: "unknown", AgentStatus: "offline"},
		{Name: "paused", Provider: "azure", Host: "paused.example.com", Suspended: true, Mode: "byo", HealthStatus: "up", AgentStatus: "online"},
		{Name: "leaving", Provider: "hetzner", Host: "leaving.example.com", DeprovisionStatus: "pending", Mode: "managed", HealthStatus: "up", AgentStatus: "online"},
		{Name: "legacy", Host: "legacy.example.com", Mode: "byo", HealthStatus: "up", AgentStatus: "online"},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	renderCloudBarkparksTable(w, list, false)
	assertGolden(t, "barkparks_fleet_table", stdout.String())
}

// TestBarkparksFleetTableLastSeen proves the LAST-SEEN column renders a real
// past stamp as a relative "ago" age (via relativeAge) while a never-seen row
// (empty LastSeenAt) falls back to the house em-dash (relativeAge("") → "" →
// hzCell → "—"). This is the NON-golden pin: the golden fixtures deliberately
// carry no LastSeenAt (so their regenerated cells stay clock-independent), so
// the wall-clock path itself needs its own deterministic-by-suffix assertion.
func TestBarkparksFleetTableLastSeen(t *testing.T) {
	stamp := time.Now().Add(-3 * time.Hour).Format(time.RFC3339)
	list := []cloudclient.Barkpark{
		{Name: "seen", Provider: "hetzner", Host: "seen.example.com", Mode: "managed", HealthStatus: "up", AgentStatus: "online", LastSeenAt: stamp},
		{Name: "never", Provider: "hetzner", Host: "never.example.com", Mode: "managed", HealthStatus: "unknown", AgentStatus: "offline"},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	renderCloudBarkparksTable(w, list, false)
	got := stdout.String()

	if !bytes.Contains([]byte(got), []byte("LAST-SEEN")) {
		t.Fatalf("fleet table missing the LAST-SEEN header:\n%s", got)
	}
	if !bytes.Contains([]byte(got), []byte("3h ago")) {
		t.Fatalf("a 3-hour-old stamp should render %q via relativeAge:\n%s", "3h ago", got)
	}
	// The never-seen row must carry the em-dash for the empty LastSeenAt.
	var neverLine string
	for _, line := range strings.Split(got, "\n") {
		if strings.HasPrefix(line, "never") {
			neverLine = line
			break
		}
	}
	if neverLine == "" {
		t.Fatalf("never-seen row not found in output:\n%s", got)
	}
	if !strings.Contains(neverLine, "—") {
		t.Fatalf("never-seen row should render the em-dash for an empty LastSeenAt:\n%q", neverLine)
	}
}

// TestBarkparksFleetTableSanitizes proves fleet cells ride through hzCell: a
// control-plane value carrying a raw ESC (a would-be terminal-injection) is
// stripped before it reaches the terminal, and a newline flattens to a space —
// the sanitizeCell contract every other cloud table already gets.
func TestBarkparksFleetTableSanitizes(t *testing.T) {
	list := []cloudclient.Barkpark{
		{Name: "evil\x1b[31mname", Provider: "hetzner", Host: "h.example.com\nx", Mode: "managed", HealthStatus: "up", AgentStatus: "online"},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	renderCloudBarkparksTable(w, list, false)
	got := stdout.String()
	if bytes.Contains([]byte(got), []byte("\x1b")) {
		t.Fatalf("fleet table echoed a raw ESC from a server value:\n%q", got)
	}
	if !bytes.Contains([]byte(got), []byte("evil[31mname")) {
		t.Fatalf("sanitized name missing (want ESC stripped, rest intact):\n%q", got)
	}
	if !bytes.Contains([]byte(got), []byte("h.example.com x")) {
		t.Fatalf("newline in host should flatten to a space:\n%q", got)
	}
}

// TestBarkparksFleetTableColorTints proves the fleet path itself lights up the
// #1739 header-driven chrome (criterion 1): under a TrueColor profile with color
// ON, the PROVIDER + STATUS cells carry SGR, and stripping the SGR yields the
// EXACT color-off golden bytes — tint only, no glyphs or injected columns.
func TestBarkparksFleetTableColorTints(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	oldDark := lipgloss.HasDarkBackground()
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(oldProfile)
		lipgloss.SetHasDarkBackground(oldDark)
	})

	list := []cloudclient.Barkpark{
		{Name: "prod", Provider: "hetzner", URL: "https://prod.example.com", Host: "prod.example.com", Mode: "managed", HealthStatus: "up", AgentStatus: "online"},
		{Name: "spinning", Provider: "azure", Mode: "managed", HealthStatus: "unknown", AgentStatus: "offline"},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.color = true
	renderCloudBarkparksTable(w, list, false)
	got := stdout.String()
	if !bytes.Contains([]byte(got), []byte("\x1b[")) {
		t.Fatalf("color-on fleet table carried no SGR — PROVIDER/STATUS chrome did not paint:\n%q", got)
	}

	// Stripping SGR must reproduce the color-off bytes exactly (tint-only contract).
	var offOut, offErr bytes.Buffer
	wo := newWriter(&offOut, &offErr) // buffer → not a tty → color off
	wo.output = "table"
	renderCloudBarkparksTable(wo, list, false)
	if strip := stripANSI(got); strip != offOut.String() {
		t.Fatalf("color-on minus SGR must equal color-off bytes:\n--- stripped ---\n%q\n--- color-off ---\n%q", strip, offOut.String())
	}
}

// TestBarkparksYAMLParity: `bp barkparks -o yaml` must emit the SAME structured
// payload as -o json (a `barkparks:` list + `source:`), not silently downgrade to
// the human table. Guards the -o yaml format-parity fix for the cloud family.
func TestBarkparksYAMLParity(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"bp-1","name":"prod","slug":"prod","url":"https://prod.example.com","mode":"managed","health_status":"up","agent_status":"online","last_seen_at":"2026-08-18T10:00:00Z","team_id":"team-1"}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "yaml"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	// YAML keys (lowercase) present …
	for _, want := range []string{"barkparks:", "source:", "name: prod", "last_seen_at:"} {
		if !bytes.Contains([]byte(stdout), []byte(want)) {
			t.Fatalf("yaml output missing %q:\n%s", want, stdout)
		}
	}
	// … and the human table header must NOT appear (proves no silent downgrade).
	if bytes.Contains([]byte(stdout), []byte("HEALTH")) {
		t.Fatalf("yaml path leaked the human table header:\n%s", stdout)
	}
}

// TestBarkparksFallsBackToLocalWithoutToken: no Cloud token → the cloud-11 local
// KnownServers view, no network call.
func TestBarkparksFallsBackToLocalWithoutToken(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t) // local KnownServers, no cloud token

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	// Local view shows the KIND column (cloud-11), which the control-plane table
	// does not render.
	if !bytes.Contains([]byte(stdout), []byte("KIND")) {
		t.Fatalf("no token should render the local KIND-column view:\n%s", stdout)
	}
}

// TestGoLivePostsRightBody: `bp go-live --name blog --plan supporter` posts the right
// body with the Bearer attached and renders the provisioned row.
func TestGoLivePostsRightBody(t *testing.T) {
	withTempConfigHome(t)

	var gotPath, gotAuth string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-7","name":"blog","url":"https://blog.barkpark.cloud","mode":"managed","health_status":"unknown","agent_status":"offline","team_id":"team-1"}}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runGoLive(out, []string{"--name", "blog", "--plan", "supporter"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/go-live" {
		t.Fatalf("hit %q, want /v1/go-live", gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	if gotBody["name"] != "blog" || gotBody["plan"] != "supporter" {
		t.Fatalf("go-live body = %v", gotBody)
	}
	if !bytes.Contains([]byte(stdout), []byte("https://blog.barkpark.cloud")) {
		t.Fatalf("rendered confirmation missing the new URL:\n%s", stdout)
	}
}

// TestGoLive422SurfacesNameRequired: the control plane's 422 surfaces in the CLI.
func TestGoLive422SurfacesNameRequired(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"name_required"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	// --name is non-empty client-side (the client requires it), but the server
	// rejects it — proving the 422 path surfaces. We pass a name so we reach the
	// POST rather than the local guard.
	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runGoLive(out, []string{"--name", "blog"})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	if !bytes.Contains([]byte(stderr), []byte("name_required")) {
		t.Fatalf("stderr should surface name_required:\n%s", stderr)
	}
}

// TestSubscribePostsPlanAndPrintsURL: `bp subscribe --plan supporter` posts {plan}
// (Bearer attached, NO client-supplied team) and prints the checkout URL.
func TestSubscribePostsPlanAndPrintsURL(t *testing.T) {
	withTempConfigHome(t)

	var gotPath, gotAuth string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"checkout_url":"https://checkout.stub/deadbeef"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSubscribe(out, []string{"--plan", "supporter"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/billing/checkout" {
		t.Fatalf("hit %q, want /v1/billing/checkout", gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	if gotBody["plan"] != "supporter" {
		t.Fatalf("subscribe body = %v, want plan=supporter", gotBody)
	}
	if _, present := gotBody["team_id"]; present {
		t.Fatalf("subscribe must not send a team_id; got %v", gotBody)
	}
	for _, want := range []string{"Subscribe at:", "https://checkout.stub/deadbeef", "supporter"} {
		if !bytes.Contains([]byte(stdout), []byte(want)) {
			t.Fatalf("subscribe output missing %q:\n%s", want, stdout)
		}
	}
}

// TestSubscribeUnknownPlanNeverCallsServer: an unknown --plan (and the
// no-checkout "free" tier) is rejected as a usage error BEFORE any network call.
func TestSubscribeUnknownPlanNeverCallsServer(t *testing.T) {
	withTempConfigHome(t)

	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"checkout_url":"https://should.not/happen"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	for _, plan := range []string{"enterprise", "free"} {
		_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
			out.output = "table"
			return runSubscribe(out, []string{"--plan", plan})
		})
		if code != exitUsage {
			t.Fatalf("plan %q: exit = %d, want %d (usage)\n%s", plan, code, exitUsage, stderr)
		}
		if !bytes.Contains([]byte(stderr), []byte("plan_invalid")) {
			t.Fatalf("plan %q: stderr should say plan_invalid:\n%s", plan, stderr)
		}
	}
	if hits != 0 {
		t.Fatalf("an invalid plan must not reach the server; got %d request(s)", hits)
	}
}

// TestSubscribe422SurfacesPlanInvalid: the server's own 422 plan_invalid (the
// backstop when the local guard is bypassed) surfaces honestly.
func TestSubscribe422SurfacesPlanInvalid(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"plan_invalid"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	// "supporter" passes the client guard, so we reach the POST; the server 422s.
	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSubscribe(out, []string{"--plan", "supporter"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
	if !bytes.Contains([]byte(stderr), []byte("plan_invalid")) {
		t.Fatalf("stderr should surface plan_invalid:\n%s", stderr)
	}
}

// TestLaunch402SurfacesSubscribeHint: when the control plane gates a launch with
// 402 no_active_subscription, the CLI surfaces the `bp subscribe` hint.
func TestLaunch402SurfacesSubscribeHint(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusPaymentRequired)
		_, _ = io.WriteString(w, `{"error":"no_active_subscription","checkout_path":"/v1/billing/checkout"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLaunch(out, []string{"hetzner", "--name", "shop"})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	for _, want := range []string{"no active subscription", "bp subscribe"} {
		if !bytes.Contains([]byte(stderr), []byte(want)) {
			t.Fatalf("stderr should surface the subscribe hint %q:\n%s", want, stderr)
		}
	}
}

// TestGoLive402SurfacesSubscribeHint: the same 402 gate on go-live surfaces the
// subscribe hint (the zero-config path also requires an active subscription).
func TestGoLive402SurfacesSubscribeHint(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusPaymentRequired)
		_, _ = io.WriteString(w, `{"error":"no_active_subscription","checkout_path":"/v1/billing/checkout"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runGoLive(out, []string{"--name", "blog"})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	for _, want := range []string{"no active subscription", "bp subscribe"} {
		if !bytes.Contains([]byte(stderr), []byte(want)) {
			t.Fatalf("stderr should surface the subscribe hint %q:\n%s", want, stderr)
		}
	}
}

// TestSubscribeRequiresLogin: with NO cloud token, `bp subscribe` fails with
// exit 3, tells the user to run `bp login`, and never hits the network.
func TestSubscribeRequiresLogin(t *testing.T) {
	withTempConfigHome(t) // empty config — no cloud token

	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
	}))
	defer srv.Close()

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSubscribe(out, []string{"--plan", "supporter"})
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !bytes.Contains([]byte(stderr), []byte("bp login")) {
		t.Fatalf("stderr should tell the user to run bp login:\n%s", stderr)
	}
	if hits != 0 {
		t.Fatalf("a missing token must not reach the server; got %d request(s)", hits)
	}
}

// TestProviderAddPostsBody: `bp provider add hetzner --token t --label l` posts
// the right body and renders the connected provider.
func TestProviderAddPostsBody(t *testing.T) {
	withTempConfigHome(t)

	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"provider":{"id":"prov-1","kind":"hetzner","label":"main","team_id":"team-1"}}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runProvider(out, []string{"add", "hetzner", "--token", "hcloud-tok", "--label", "main"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/providers" {
		t.Fatalf("hit %q, want /v1/providers", gotPath)
	}
	if gotBody["kind"] != "hetzner" || gotBody["token"] != "hcloud-tok" || gotBody["label"] != "main" {
		t.Fatalf("provider body = %v", gotBody)
	}
	if !bytes.Contains([]byte(stdout), []byte("prov-1")) {
		t.Fatalf("rendered confirmation missing the provider id:\n%s", stdout)
	}
}

// TestLaunchPostsBody: `bp launch hetzner --name shop` posts provider+name.
func TestLaunchPostsBody(t *testing.T) {
	withTempConfigHome(t)

	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-9","name":"shop","host":"shop.example.com","mode":"byo","health_status":"unknown","agent_status":"offline","team_id":"team-1"}}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLaunch(out, []string{"hetzner", "--name", "shop"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/launch" {
		t.Fatalf("hit %q, want /v1/launch", gotPath)
	}
	if gotBody["provider"] != "hetzner" || gotBody["name"] != "shop" {
		t.Fatalf("launch body = %v", gotBody)
	}
}

// TestLaunchAzurePassesThrough: `bp launch azure --name shop` passes the provider
// positional through OPAQUELY — the control plane resolves the Team's connected
// azure provider. S5 does NOT special-case azure in the CLI; this pins that the
// existing pass-through already carries it (only the body's provider changes).
func TestLaunchAzurePassesThrough(t *testing.T) {
	withTempConfigHome(t)

	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-az","name":"shop","host":"shop.example.com","mode":"byo","health_status":"unknown","agent_status":"offline","team_id":"team-1"}}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLaunch(out, []string{"azure", "--name", "shop"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/launch" {
		t.Fatalf("hit %q, want /v1/launch", gotPath)
	}
	if gotBody["provider"] != "azure" || gotBody["name"] != "shop" {
		t.Fatalf("launch body = %v (provider must be the opaque azure positional)", gotBody)
	}
}

// TestParseLaunchArgsProviderIsOpaque: the launch arg parser treats the provider
// positional as an opaque string — azure is accepted exactly like hetzner, with
// no CLI-side allowlist to update per provider.
func TestParseLaunchArgsProviderIsOpaque(t *testing.T) {
	provider, name, err := parseLaunchArgs([]string{"azure", "--name", "shop"})
	if err != nil {
		t.Fatalf("parseLaunchArgs: %v", err)
	}
	if provider != "azure" || name != "shop" {
		t.Fatalf("parseLaunchArgs = (%q,%q), want (azure,shop)", provider, name)
	}
}

// TestParseLoginArgsFlagShapedValueRejected: nextFlagValue used to consume
// args[i+1] unconditionally, so `bp login --password --device-start` bound the
// password to the literal "--device-start" and left --device-start's own bool
// false, with NO error. Every login value-flag (--email/--password/
// --device-poll/--url), followed immediately by any other known login flag or
// by end-of-args, must now fail with the flag-needs-a-value error instead of
// silently swallowing the follower. This is the fails-before-fix case.
func TestParseLoginArgsFlagShapedValueRejected(t *testing.T) {
	valueFlags := []string{"--email", "--password", "--device-poll", "--url"}
	followers := append([]string{""}, loginKnownFlags...) // "" stands for end-of-args
	for _, vf := range valueFlags {
		for _, follower := range followers {
			var args []string
			if follower == "" {
				args = []string{vf}
			} else {
				args = []string{vf, follower}
			}
			name := vf + "_then_" + follower
			if follower == "" {
				name = vf + "_end_of_args"
			}
			t.Run(name, func(t *testing.T) {
				_, _, _, _, _, _, err := parseLoginArgs(args)
				if err == nil {
					t.Fatalf("parseLoginArgs(%v) = nil error, want %q needs a value", args, vf)
				}
				if !strings.Contains(err.Error(), vf+" needs a value") {
					t.Fatalf("parseLoginArgs(%v) error = %q, want it to contain %q", args, err, vf+" needs a value")
				}
			})
		}
	}
}

// TestParseLoginArgsLegitValueStillParses: the guard must not reject a value
// that merely starts with "-" but isn't a flag this parser knows.
func TestParseLoginArgsLegitValueStillParses(t *testing.T) {
	email, password, _, _, _, _, err := parseLoginArgs([]string{"--email", "a@b.com", "--password", "-secret"})
	if err != nil {
		t.Fatalf("parseLoginArgs: %v", err)
	}
	if email != "a@b.com" || password != "-secret" {
		t.Fatalf("parseLoginArgs = (%q,%q), want (a@b.com,-secret)", email, password)
	}
}

// TestParseSignupArgsFlagShapedValueRejected mirrors the login case for
// `bp signup`'s value-flags (--email/--password/--team/--url).
func TestParseSignupArgsFlagShapedValueRejected(t *testing.T) {
	valueFlags := []string{"--email", "--password", "--team", "--url"}
	followers := append([]string{""}, signupKnownFlags...)
	for _, vf := range valueFlags {
		for _, follower := range followers {
			var args []string
			if follower == "" {
				args = []string{vf}
			} else {
				args = []string{vf, follower}
			}
			name := vf + "_then_" + follower
			if follower == "" {
				name = vf + "_end_of_args"
			}
			t.Run(name, func(t *testing.T) {
				_, _, _, _, err := parseSignupArgs(args)
				if err == nil {
					t.Fatalf("parseSignupArgs(%v) = nil error, want %q needs a value", args, vf)
				}
				if !strings.Contains(err.Error(), vf+" needs a value") {
					t.Fatalf("parseSignupArgs(%v) error = %q, want it to contain %q", args, err, vf+" needs a value")
				}
			})
		}
	}
}

// TestParseSignupArgsLegitValueStillParses: a dash-leading value that isn't a
// known flag still binds normally.
func TestParseSignupArgsLegitValueStillParses(t *testing.T) {
	email, password, team, _, err := parseSignupArgs([]string{"--email", "a@b.com", "--team", "-acme", "--password", "-secret"})
	if err != nil {
		t.Fatalf("parseSignupArgs: %v", err)
	}
	if email != "a@b.com" || team != "-acme" || password != "-secret" {
		t.Fatalf("parseSignupArgs = (%q,%q,%q), want (a@b.com,-acme,-secret)", email, password, team)
	}
}

// TestAuthedCommandsRequireLogin: with NO cloud token, the authed commands fail
// with exit 3 and tell the user to run `bp login`. They must NOT hit the network.
func TestAuthedCommandsRequireLogin(t *testing.T) {
	withTempConfigHome(t) // empty config — no cloud token

	cases := []struct {
		name string
		run  func(out *writer) int
	}{
		{"provider", func(out *writer) int { return runProvider(out, []string{"add", "hetzner", "--token", "t"}) }},
		{"launch", func(out *writer) int { return runLaunch(out, []string{"hetzner", "--name", "x"}) }},
		{"go-live", func(out *writer) int { return runGoLive(out, []string{"--name", "x"}) }},
	}
	for _, tc := range cases {
		_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
			out.output = "table"
			return tc.run(out)
		})
		if code != exitAuth {
			t.Fatalf("%s: exit = %d, want %d (auth)", tc.name, code, exitAuth)
		}
		if !bytes.Contains([]byte(stderr), []byte("bp login")) {
			t.Fatalf("%s: stderr should tell the user to run bp login:\n%s", tc.name, stderr)
		}
	}
}

// TestBarkparks401ExitsAuthWithLoginHint: a SAVED-but-dead session (the control
// plane 401s the token) is an auth failure, not a generic one — `bp barkparks`
// exits 3 and points the user back at `bp login`, exactly like the no-token path.
func TestBarkparks401ExitsAuthWithLoginHint(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid or expired token"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	for _, want := range []string{"unauthorized", "bp login"} {
		if !bytes.Contains([]byte(stderr), []byte(want)) {
			t.Fatalf("stderr should carry %q:\n%s", want, stderr)
		}
	}
}

// TestLaunch401ExitsAuthWithLoginHint: the same dead-session contract on a
// provisioning command — a 401 from /v1/launch exits 3 with the `bp login` hint
// (and must NOT be mistaken for the 402 subscription gate).
func TestLaunch401ExitsAuthWithLoginHint(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid or expired token"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLaunch(out, []string{"hetzner", "--name", "shop"})
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	for _, want := range []string{"unauthorized", "bp login"} {
		if !bytes.Contains([]byte(stderr), []byte(want)) {
			t.Fatalf("stderr should carry %q:\n%s", want, stderr)
		}
	}
}

// TestBarkparks500StaysGeneric: cloudFail must not over-trigger — a non-401
// control-plane failure keeps the plain "failed" exit 1 with no login hint.
func TestBarkparks500StaysGeneric(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `{"error":"registry unavailable"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d (generic)", code, exitGeneric)
	}
	if !bytes.Contains([]byte(stderr), []byte("registry unavailable")) {
		t.Fatalf("stderr should surface the server error:\n%s", stderr)
	}
	if bytes.Contains([]byte(stderr), []byte("bp login")) {
		t.Fatalf("a 500 must not claim the session is dead:\n%s", stderr)
	}
}

// TestLogoutClearsCloudFields: a plain `bp logout` blanks exactly the three
// Cloud* session fields and persists, while the per-server content Token and the
// KnownServers fleet survive — logout is a cloud-session action, not a wipe.
func TestLogoutClearsCloudFields(t *testing.T) {
	withTempConfigHome(t)
	if err := SaveConfig(&Config{
		Server:     "https://api.barkpark.cloud",
		Token:      "content-tok",
		CloudURL:   "https://api.barkpark.cloud",
		CloudToken: "sess-secret-abc",
		CloudTeam:  "team-x",
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	if code := runLogout(w, globals{}, nil); code != exitOK {
		t.Fatalf("runLogout exit = %d\n%s", code, stderr.String())
	}

	cfg, _ := LoadConfig()
	if cfg.CloudToken != "" || cfg.CloudURL != "" || cfg.CloudTeam != "" {
		t.Fatalf("Cloud* fields not fully cleared: %+v", cfg)
	}
	if cfg.Token != "content-tok" {
		t.Fatalf("content Token must survive a plain logout; got %q", cfg.Token)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("logged out")) {
		t.Fatalf("expected a logout confirmation:\n%s", stdout.String())
	}
}

// TestLogoutAllClearsContentToken: `bp logout --all` (a global → g.all) also
// drops the ACTIVE content token, not just the Cloud session.
func TestLogoutAllClearsContentToken(t *testing.T) {
	withTempConfigHome(t)
	if err := SaveConfig(&Config{
		Token:      "content-tok",
		CloudURL:   "https://api.barkpark.cloud",
		CloudToken: "sess-secret-abc",
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	if code := runLogout(w, globals{all: true}, nil); code != exitOK {
		t.Fatalf("runLogout --all exit = %d\n%s", code, stderr.String())
	}

	cfg, _ := LoadConfig()
	if cfg.Token != "" {
		t.Fatalf("--all must clear the content Token; got %q", cfg.Token)
	}
	if cfg.CloudToken != "" {
		t.Fatalf("--all must still clear the Cloud session; got %q", cfg.CloudToken)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("content token cleared")) {
		t.Fatalf("expected the content-token note:\n%s", stdout.String())
	}
}

// TestLogoutJSONEnvelope: -o json emits a {ok,was_logged_in,token_cleared}
// receipt for machine consumers.
func TestLogoutJSONEnvelope(t *testing.T) {
	withTempConfigHome(t)
	if err := SaveConfig(&Config{
		CloudURL:   "https://api.barkpark.cloud",
		CloudToken: "sess-secret-abc",
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if code := runLogout(w, globals{}, nil); code != exitOK {
		t.Fatalf("runLogout exit = %d\n%s", code, stderr.String())
	}
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("parse json: %v\n%s", err, stdout.String())
	}
	if env["ok"] != true {
		t.Errorf("ok = %v, want true", env["ok"])
	}
	if env["was_logged_in"] != true {
		t.Errorf("was_logged_in = %v, want true", env["was_logged_in"])
	}
	if env["token_cleared"] != false {
		t.Errorf("token_cleared = %v, want false (no --all)", env["token_cleared"])
	}
}

// TestLogoutIdempotentWhenLoggedOut: logging out with no Cloud session is a clean
// no-op that still exits 0 and says so.
func TestLogoutIdempotentWhenLoggedOut(t *testing.T) {
	withTempConfigHome(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	if code := runLogout(w, globals{}, nil); code != exitOK {
		t.Fatalf("runLogout on a clean config exit = %d\n%s", code, stderr.String())
	}
	if !bytes.Contains(stdout.Bytes(), []byte("already logged out")) {
		t.Fatalf("expected the idempotent message:\n%s", stdout.String())
	}
}

// --- cloudFail reads the STATUS, not the sentence ----------------------------
//
// TestCloudFailDoesNotReadTheServersProseForAuth: cloudFail decides "your cloud
// session is dead — run `bp login`" for ~30 cloud verbs. It used to decide it by
// asking whether the RENDERED SENTENCE contained the substring "unauthorized" —
// a sentence that carries the control plane's own `detail`, `reason`, `required`,
// `scope` and `details` prose, and, for any body that is not the flat
// {"error":"<string>"} shape, the RAW BODY verbatim (cloudError's 200-rune
// fallback). All of that is text the CLI does not author.
//
// The fixture below is the control plane's OWN 502: router.ex 7741 answers a
// site create whose read-token mint failed with
// {"error":"read_token_mint_failed","detail":<mint_failure_copy>}, and
// mint_failure_copy/mint_failure_detail (router.ex 13775-13805) RELAY THE BOX'S
// OWN REFUSAL VERBATIM — "…: <code> — <message>". A box whose stored admin token
// is dead answers with its canonical auth slug, the literal string
// "unauthorized" (api/lib/barkpark/content/errors.ex builds
// %{code: "unauthorized", message: "missing or invalid token", status: 401}).
//
// So the user's cloud session is fine, and the fact "was THIS request refused
// for auth" is declared structurally on the wire — CloudRefusal.HTTPStatus,
// which every other refusal reader in this tree already branches on
// (builtins.go, cloud_deliveries_cmd.go, cloud_deploy_census_cmd.go,
// cloud_site_cmd.go). Reading the box's word out of the plane's prose instead
// told the user to re-run `bp login`, which fixes nothing, and exited 3 (auth)
// where a script's auth-retry loop then re-authenticates forever.
//
// RED BEFORE (reproducible by reverting cloudFail alone): exit 3 with "bp login".
func TestCloudFailDoesNotReadTheServersProseForAuth(t *testing.T) {
	const relayed = "acme refused to mint the site's read token (HTTP 401): unauthorized — missing or invalid token"
	body := `{"error":"read_token_mint_failed","detail":"` + relayed + `"}`

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = io.WriteString(w, body)
	}))
	defer srv.Close()

	c := &cloudclient.Client{BaseURL: srv.URL, Token: "sess-abc"}
	_, err := c.CreateSpawnSite(cloudCtx(), cloudclient.SpawnSiteCreate{Name: "blog"})
	if err == nil {
		t.Fatal("CreateSpawnSite must fail on a 502")
	}

	// The typed fact is on the wire and already parsed — assert it, so this test
	// can never pass because the refusal stopped being typed.
	var ref *cloudclient.CloudRefusal
	if !errors.As(err, &ref) {
		t.Fatalf("a 502 refusal must be a *CloudRefusal, got %T (%v)", err, err)
	}
	if ref.HTTPStatus != http.StatusBadGateway {
		t.Fatalf("HTTPStatus = %d, want %d", ref.HTTPStatus, http.StatusBadGateway)
	}
	if !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("fixture no longer exercises the trap — the rendered message must carry the box's relayed slug:\n%s", err.Error())
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	code := cloudFail(w, "create site", err)

	if code == exitAuth {
		t.Fatalf("cloudFail classified an HTTP %d refusal as a DEAD CLOUD SESSION (exit %d) "+
			"because the control plane's relayed detail happens to SPELL %q — the status "+
			"the refusal declares is %d, not 401, and the credential that was rejected is "+
			"the BOX's, not the user's:\n%s",
			ref.HTTPStatus, exitAuth, "unauthorized", ref.HTTPStatus, stderr.String())
	}
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d (generic)", code, exitGeneric)
	}
	if strings.Contains(stderr.String(), "bp login") {
		t.Fatalf("a 502 the BOX caused must never tell the user their cloud session expired:\n%s", stderr.String())
	}
	// The plane's own words still reach the user — the fix narrows the VERDICT,
	// never the evidence.
	if !strings.Contains(stderr.String(), relayed) {
		t.Fatalf("the plane's relayed detail must still be surfaced verbatim:\n%s", stderr.String())
	}
}

// TestCloudFailStillCallsARealDeadSessionAuth is the preserved half of the
// contract: a genuine 401 keeps the "auth" label, exit 3 and the `bp login`
// hint. The status is the signal, so this holds whatever the body says.
func TestCloudFailStillCallsARealDeadSessionAuth(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid_credentials"}`)
	}))
	defer srv.Close()

	c := &cloudclient.Client{BaseURL: srv.URL, Token: "sess-abc"}
	_, err := c.CreateSpawnSite(cloudCtx(), cloudclient.SpawnSiteCreate{Name: "blog"})
	if err == nil {
		t.Fatal("CreateSpawnSite must fail on a 401")
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	if code := cloudFail(w, "create site", err); code != exitAuth {
		t.Fatalf("a 401 must exit %d (auth), got %d\n%s", exitAuth, code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "bp login") {
		t.Fatalf("a dead session must still name the cure:\n%s", stderr.String())
	}
}
