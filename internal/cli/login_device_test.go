package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// withInstantDevicePolls shrinks the poll seams so a device-login test finishes
// in microseconds: no real sleeps, a small poll cap. Restores the originals.
func withInstantDevicePolls(t *testing.T, maxPolls int) {
	t.Helper()
	origSleep, origMax := deviceSleep, devicePollMax
	deviceSleep = func(time.Duration) {}
	devicePollMax = maxPolls
	t.Cleanup(func() { deviceSleep = origSleep; devicePollMax = origMax })
}

// forceDeviceTTY makes deviceRequested's both-TTY gate return want for the test's
// duration, so the gating table can be exercised without a pseudo-terminal.
func forceDeviceTTY(t *testing.T, want bool) {
	t.Helper()
	orig := deviceTTYCheck
	deviceTTYCheck = func() bool { return want }
	t.Cleanup(func() { deviceTTYCheck = orig })
}

// stubBrowserOpener records the URL a device flow would open and never launches a
// real browser. Restores the original opener.
func stubBrowserOpener(t *testing.T) *string {
	t.Helper()
	var opened string
	orig := browserOpener
	browserOpener = func(url string) error { opened = url; return nil }
	t.Cleanup(func() { browserOpener = orig })
	return &opened
}

// deviceServer stands up a fake control plane that answers device/start with a
// fixed code pair, then answers the first (pendingPolls) device/poll calls with
// the charter's 200 {"status":"pending"} before approving with the given
// token/team. It records how many times each route was hit.
type deviceServer struct {
	startHits atomic.Int64
	pollHits  atomic.Int64
	loginHits atomic.Int64
}

func newDeviceServer(t *testing.T, ds *deviceServer, pendingPolls int, token, team string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			ds.startHits.Add(1)
			_, _ = io.WriteString(w, `{
				"device_code":"dev-secret",
				"user_code":"WXYZ-1234",
				"verification_uri":"`+deviceVerifyBase(r)+`/device",
				"verification_uri_complete":"`+deviceVerifyBase(r)+`/device?code=WXYZ-1234",
				"interval":1,
				"expires_in":900
			}`)
		case "/v1/auth/device/poll":
			n := ds.pollHits.Add(1)
			if int(n) <= pendingPolls {
				// The control plane's pending steady-state (charter decision 10).
				_, _ = io.WriteString(w, `{"status":"pending"}`)
				return
			}
			_, _ = io.WriteString(w, `{"token":"`+token+`","team_id":"`+team+`"}`)
		case "/v1/auth/login":
			ds.loginHits.Add(1)
			_, _ = io.WriteString(w, `{"token":"pw-token","team_id":"pw-team"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func deviceVerifyBase(r *http.Request) string { return "http://" + r.Host }

// TestDeviceLoginFlowStoresToken drives the whole copy-a-link flow: start →
// pending twice → approved, and asserts the token/URL/team land in config
// exactly like a password login, plus the boxed URL + code + email fallback
// print to STDERR (chrome) while stdout stays clean.
func TestDeviceLoginFlowStoresToken(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)

	var ds deviceServer
	srv := newDeviceServer(t, &ds, 2, "sess-device", "team-dev")

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table" // isTTY stays false (buffer) → no browser/enter prompt

	if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp on test"); err != nil {
		t.Fatalf("runDeviceLoginFlow: %v\nstderr:\n%s", err, stderr.String())
	}
	if ds.startHits.Load() != 1 {
		t.Fatalf("device/start hits = %d, want 1", ds.startHits.Load())
	}
	if ds.pollHits.Load() != 3 {
		t.Fatalf("device/poll hits = %d, want 3 (2 pending + 1 approved)", ds.pollHits.Load())
	}

	loaded, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if loaded.CloudToken != "sess-device" {
		t.Fatalf("CloudToken = %q, want sess-device", loaded.CloudToken)
	}
	if loaded.CloudURL != srv.URL {
		t.Fatalf("CloudURL = %q, want %q", loaded.CloudURL, srv.URL)
	}
	if loaded.CloudTeam != "team-dev" {
		t.Fatalf("CloudTeam = %q, want team-dev", loaded.CloudTeam)
	}

	// Chrome (box, code, URL, fallback) is on STDERR.
	errOut := stderr.String()
	for _, want := range []string{"WXYZ-1234", "/device", "Or log in with email", "Barkpark Cloud"} {
		if !bytes.Contains([]byte(errOut), []byte(want)) {
			t.Fatalf("stderr chrome missing %q:\n%s", want, errOut)
		}
	}
	// The human success confirmation is on stdout (table mode).
	if !bytes.Contains(stdout.Bytes(), []byte("logged in")) {
		t.Fatalf("stdout should carry the success line:\n%s", stdout.String())
	}
}

// TestDeviceLoginFlowJSONEnvelopeCleanStdout: with -o json ONLY the
// {ok,cloud_url,team_id} envelope hits stdout; all chrome stays on stderr.
func TestDeviceLoginFlowJSONEnvelopeCleanStdout(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)

	var ds deviceServer
	srv := newDeviceServer(t, &ds, 1, "sess-json", "team-json")

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp on test"); err != nil {
		t.Fatalf("runDeviceLoginFlow: %v", err)
	}
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout.String())
	}
	if env["ok"] != true || env["cloud_url"] != srv.URL || env["team_id"] != "team-json" {
		t.Fatalf("envelope = %v", env)
	}
	// Chrome must NOT be on stdout.
	if bytes.Contains(stdout.Bytes(), []byte("WXYZ-1234")) {
		t.Fatalf("device code leaked onto stdout:\n%s", stdout.String())
	}
}

// TestDeviceLoginSlowDownBacksOff: a slow_down widens the interval. We assert the
// flow still reaches approval (the back-off does not derail it) and the slow_down
// response was consumed.
func TestDeviceLoginSlowDownBacksOff(t *testing.T) {
	withTempConfigHome(t)
	origSleep, origMax := deviceSleep, devicePollMax
	var sleeps []time.Duration
	deviceSleep = func(d time.Duration) { sleeps = append(sleeps, d) }
	devicePollMax = 10
	t.Cleanup(func() { deviceSleep = origSleep; devicePollMax = origMax })

	var pollHits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			switch pollHits.Add(1) {
			case 1:
				// First poll pending → a sleep at the BASE interval.
				_, _ = io.WriteString(w, `{"status":"pending"}`)
			case 2:
				// Second poll slow_down (the real 429) → widen the interval, then
				// sleep wider.
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = io.WriteString(w, `{"error":"slow_down"}`)
			default:
				_, _ = io.WriteString(w, `{"token":"sess-slow","team_id":"team-slow"}`)
			}
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
		t.Fatalf("runDeviceLoginFlow: %v", err)
	}
	if len(sleeps) < 2 {
		t.Fatalf("expected at least two poll sleeps, got %d", len(sleeps))
	}
	// The interval after slow_down (2nd sleep) must exceed the initial one — the
	// back-off widened it.
	if sleeps[1] <= sleeps[0] {
		t.Fatalf("slow_down should widen the interval: %v then %v", sleeps[0], sleeps[1])
	}
	loaded, _ := LoadConfig()
	if loaded.CloudToken != "sess-slow" {
		t.Fatalf("CloudToken = %q, want sess-slow", loaded.CloudToken)
	}
}

// TestDeviceLoginDenialExitsAuth: the control plane folds denied / expired /
// replayed into one 404 expired_or_invalid — a terminal AUTH failure:
// runDeviceLoginFlow returns a *deviceAuthError (→ exitAuth) and writes NO token.
func TestDeviceLoginDenialExitsAuth(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":"expired_or_invalid"}`)
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	err := runDeviceLoginFlow(w, cfg, srv.URL, "bp")
	if err == nil {
		t.Fatal("denial must be an error")
	}
	if !asDeviceAuthError(err) {
		t.Fatalf("denial should be a deviceAuthError (→ exitAuth); got %T: %v", err, err)
	}
	loaded, _ := LoadConfig()
	if loaded.CloudToken != "" {
		t.Fatalf("a denied login must not persist a token; got %q", loaded.CloudToken)
	}
}

// TestDeviceLoginTimeoutExitsAuth: the poll loop exhausts devicePollMax without
// an approval → a *deviceAuthError naming the email fallback.
func TestDeviceLoginTimeoutExitsAuth(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 3)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			_, _ = io.WriteString(w, `{"status":"pending"}`)
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	err := runDeviceLoginFlow(w, cfg, srv.URL, "bp")
	if !asDeviceAuthError(err) {
		t.Fatalf("timeout should be a deviceAuthError; got %T: %v", err, err)
	}
	if !bytes.Contains([]byte(err.Error()), []byte("--email")) {
		t.Fatalf("timeout message should offer the email fallback; got %q", err.Error())
	}
}

// TestDeviceLoginSurvivesTransientPollError is the regression guard for the
// onb-w4 fix: a single transient 500 mid-poll must NOT abort the interactive
// flow. Before the fix, login_device.go returned ANY non-nil poll error, so one
// injected 500 killed `bp login` after exactly one poll — while the one-shot
// --device-poll mapped the identical error to a retryable exitGeneric. The loop
// now retries a non-terminal (asDeviceAuthError==false) error with backoff, so
// the flow rides through the blip and still lands the token.
func TestDeviceLoginSurvivesTransientPollError(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)

	var pollHits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			switch pollHits.Add(1) {
			case 1:
				// A pending steady-state before the blip.
				_, _ = io.WriteString(w, `{"status":"pending"}`)
			case 2:
				// The injected transient failure — a 500 with NO refusal substring,
				// so classifyDevicePollError keeps it a generic (retryable) error.
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = io.WriteString(w, `{"error":"internal_server_error"}`)
			default:
				// The user has since approved — the flow must reach here.
				_, _ = io.WriteString(w, `{"token":"sess-survive","team_id":"team-survive"}`)
			}
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
		t.Fatalf("a transient 500 must NOT abort the interactive flow: %v\nstderr:\n%s", err, stderr.String())
	}
	// The flow rode past the blip: poll 1 (pending), poll 2 (500, retried), poll 3
	// (approved) — a pre-fix loop would have stopped at 2.
	if pollHits.Load() < 3 {
		t.Fatalf("flow aborted early on the transient error; poll hits = %d, want >= 3", pollHits.Load())
	}
	loaded, _ := LoadConfig()
	if loaded.CloudToken != "sess-survive" {
		t.Fatalf("the surviving flow must persist the token; got %q", loaded.CloudToken)
	}
}

// TestDeviceLoginRefusalAbortsWithNoRetry proves the OTHER direction of the
// onb-w4 fix: a TRUE refusal (deviceAuthError) still terminates immediately with
// ZERO retries — the retry path must never swallow the user's denial. The plane
// answers the very first poll with a refusal; the loop must abort after exactly
// one poll, return a *deviceAuthError (→ exitAuth), and persist no token.
func TestDeviceLoginRefusalAbortsWithNoRetry(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)

	var pollHits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			pollHits.Add(1)
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":"access_denied"}`)
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	err := runDeviceLoginFlow(w, cfg, srv.URL, "bp")
	if !asDeviceAuthError(err) {
		t.Fatalf("a refusal must be a terminal deviceAuthError; got %T: %v", err, err)
	}
	if pollHits.Load() != 1 {
		t.Fatalf("a refusal must abort with NO retry; poll hits = %d, want 1", pollHits.Load())
	}
	if loaded, _ := LoadConfig(); loaded.CloudToken != "" {
		t.Fatalf("a refused login must not persist a token; got %q", loaded.CloudToken)
	}
}

// TestDeviceLoginAllErrorsCannotSpinForever proves the retry bound is finite: a
// server that ALWAYS returns a transient 500 must not loop forever. The retry
// path is capped by devicePollMax, so the flow terminates with a *deviceAuthError
// (the timeout) after exactly devicePollMax polls — never more.
func TestDeviceLoginAllErrorsCannotSpinForever(t *testing.T) {
	withTempConfigHome(t)
	const maxPolls = 4
	withInstantDevicePolls(t, maxPolls)

	var pollHits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			pollHits.Add(1)
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = io.WriteString(w, `{"error":"internal_server_error"}`)
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	err := runDeviceLoginFlow(w, cfg, srv.URL, "bp")
	if !asDeviceAuthError(err) {
		t.Fatalf("an all-error server must terminate with the timeout deviceAuthError; got %T: %v", err, err)
	}
	if got := pollHits.Load(); got != maxPolls {
		t.Fatalf("retries must be bounded by devicePollMax; poll hits = %d, want %d", got, maxPolls)
	}
	if loaded, _ := LoadConfig(); loaded.CloudToken != "" {
		t.Fatalf("a never-approved login must persist no token; got %q", loaded.CloudToken)
	}
}

// TestDeviceLoginPersistFailureAbortsHonestly pins the post-approval edge of the
// transient-retry fix: when the plane APPROVES but SaveConfig fails locally, the
// loop must abort with the honest save error — never re-poll the now-burned code
// (which would answer expired_or_invalid and mask the disk problem as a refusal).
func TestDeviceLoginPersistFailureAbortsHonestly(t *testing.T) {
	xdg := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", xdg)
	// Squat the config DIR with a plain file so SaveConfig's MkdirAll fails.
	if err := os.WriteFile(filepath.Join(xdg, "barkpark"), []byte("squat"), 0o600); err != nil {
		t.Fatal(err)
	}
	withInstantDevicePolls(t, 10)

	var pollHits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			pollHits.Add(1)
			// Approved on the FIRST poll — the failure under test is local.
			_, _ = io.WriteString(w, `{"token":"sess-persist","team_id":"team-persist"}`)
		}
	}))
	t.Cleanup(srv.Close)

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	err := runDeviceLoginFlow(w, cfg, srv.URL, "bp")
	if err == nil {
		t.Fatal("a failed SaveConfig after approval must surface an error")
	}
	if asDeviceAuthError(err) {
		t.Fatalf("a local persistence failure must NOT read as an auth refusal; got %v", err)
	}
	if !strings.Contains(err.Error(), "save config") {
		t.Fatalf("the honest local cause must surface verbatim; got %v", err)
	}
	if got := pollHits.Load(); got != 1 {
		t.Fatalf("a persist failure must abort with NO re-poll of the burned code; poll hits = %d, want 1", got)
	}
}

// meDeviceServer stands up a fake control plane that approves the FIRST poll with
// the given token/team, then answers /v1/me with meBody at whatever HTTP status
// meStatus names (200 for a healthy identity, a 5xx to exercise the honest
// degrade). It records the Authorization header /v1/me saw so a test can prove the
// minted bearer — and only the minted bearer — rode the identity probe.
func newMeDeviceServer(t *testing.T, token, team string, meStatus int, meBody string, gotMeAuth *string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			_, _ = io.WriteString(w, `{"token":"`+token+`","team_id":"`+team+`"}`)
		case "/v1/me":
			if gotMeAuth != nil {
				*gotMeAuth = r.Header.Get("Authorization")
			}
			if meStatus != 0 && meStatus != http.StatusOK {
				w.WriteHeader(meStatus)
			}
			_, _ = io.WriteString(w, meBody)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestDeviceLoginReceiptNamesBoundAccount is the charter-D37 proof: after a
// successful device login the receipt names WHICH account the browser approval
// bound — the account email (human + json) and the team by its human Name (not
// just the raw team id) — resolved best-effort via a client-side /v1/me carrying
// the just-minted bearer. A wrong-account approval is now visible in the receipt.
func TestDeviceLoginReceiptNamesBoundAccount(t *testing.T) {
	const meBody = `{"user":{"id":"u-1","email":"ada@example.com","confirmed":true},` +
		`"team":{"id":"team-uuid","name":"Primary","slug":"primary","role":"owner"},"role":"owner"}`

	t.Run("human receipt names account + team by name", func(t *testing.T) {
		withTempConfigHome(t)
		withInstantDevicePolls(t, 10)
		var meAuth string
		srv := newMeDeviceServer(t, "sess-me", "team-uuid", http.StatusOK, meBody, &meAuth)

		cfg := &Config{}
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "table"
		if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
			t.Fatalf("runDeviceLoginFlow: %v\nstderr:\n%s", err, stderr.String())
		}
		// The minted bearer — and only it — rode the /v1/me identity probe.
		if meAuth != "Bearer sess-me" {
			t.Fatalf("/v1/me must carry the just-minted bearer; got %q", meAuth)
		}
		out := stdout.String()
		if !strings.Contains(out, "account: ada@example.com") {
			t.Fatalf("receipt must name the bound account email:\n%s", out)
		}
		// The team is named by its human Name, not the raw uuid.
		if !strings.Contains(out, "team: Primary") {
			t.Fatalf("receipt must name the team by Name:\n%s", out)
		}
	})

	t.Run("json receipt carries account + identity:verified", func(t *testing.T) {
		withTempConfigHome(t)
		withInstantDevicePolls(t, 10)
		srv := newMeDeviceServer(t, "sess-me", "team-uuid", http.StatusOK, meBody, nil)

		cfg := &Config{}
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "json"
		if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
			t.Fatalf("runDeviceLoginFlow: %v", err)
		}
		var env map[string]any
		if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
			t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout.String())
		}
		if env["ok"] != true || env["cloud_url"] != srv.URL || env["team_id"] != "team-uuid" {
			t.Fatalf("base envelope changed: %v", env)
		}
		if env["account"] != "ada@example.com" || env["identity"] != "verified" {
			t.Fatalf("json must carry the bound account + identity:verified; got %v", env)
		}
	})

	t.Run("teamless identity does not panic", func(t *testing.T) {
		withTempConfigHome(t)
		withInstantDevicePolls(t, 10)
		// Team omitted → MeResult.Team is nil (a teamless first login). The receipt
		// must still name the account and fall back to the raw team id for the team
		// line — never dereference the nil *Team.
		const teamlessMe = `{"user":{"id":"u-2","email":"solo@example.com"},"role":"member"}`
		srv := newMeDeviceServer(t, "sess-solo", "team-raw", http.StatusOK, teamlessMe, nil)

		cfg := &Config{}
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "table"
		if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
			t.Fatalf("teamless login must not fail: %v", err)
		}
		out := stdout.String()
		if !strings.Contains(out, "account: solo@example.com") {
			t.Fatalf("teamless receipt must still name the account:\n%s", out)
		}
		if !strings.Contains(out, "team: team-raw") {
			t.Fatalf("teamless receipt should fall back to the raw team id:\n%s", out)
		}
	})
}

// TestDeviceLoginReceiptDegradesOnMeFailure is the honesty proof: an unreachable
// /v1/me after the token mints must NOT turn a stored session into a failed login.
// The login still exits ok; the human receipt says the account is unverified and
// names bp whoami; the json envelope carries account:null + identity:"unverified"
// with ok:true intact. Proven with a 500-serving /v1/me fixture.
func TestDeviceLoginReceiptDegradesOnMeFailure(t *testing.T) {
	t.Run("human receipt says unverified", func(t *testing.T) {
		withTempConfigHome(t)
		withInstantDevicePolls(t, 10)
		srv := newMeDeviceServer(t, "sess-x", "team-x", http.StatusInternalServerError, `{"error":"boom"}`, nil)

		cfg := &Config{}
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "table"
		if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
			t.Fatalf("a failed /v1/me must NOT fail the login: %v", err)
		}
		// The session still persisted — the login succeeded end to end.
		if loaded, _ := LoadConfig(); loaded.CloudToken != "sess-x" {
			t.Fatalf("the token must still persist despite a failed /v1/me; got %q", loaded.CloudToken)
		}
		out := stdout.String()
		if !strings.Contains(out, "logged in") {
			t.Fatalf("the login still succeeded — the success line must print:\n%s", out)
		}
		if !strings.Contains(out, "account: unverified (run 'bp whoami')") {
			t.Fatalf("the honest degrade must name bp whoami:\n%s", out)
		}
	})

	t.Run("json carries account:null + identity:unverified, ok stays true", func(t *testing.T) {
		withTempConfigHome(t)
		withInstantDevicePolls(t, 10)
		srv := newMeDeviceServer(t, "sess-x", "team-x", http.StatusInternalServerError, `{"error":"boom"}`, nil)

		cfg := &Config{}
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "json"
		if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
			t.Fatalf("runDeviceLoginFlow: %v", err)
		}
		var env map[string]any
		if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
			t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout.String())
		}
		if env["ok"] != true {
			t.Fatalf("ok must never drop on the degrade; got %v", env["ok"])
		}
		if got, ok := env["account"]; !ok || got != nil {
			t.Fatalf("account must be present and null on the degrade; got %v (present=%v)", got, ok)
		}
		if env["identity"] != "unverified" {
			t.Fatalf("identity must be unverified on the degrade; got %v", env["identity"])
		}
	})
}

// TestDeviceLoginReceiptNeverPrintsBearer is the seeded-secret assertion: the
// session token rides the /v1/me request as a Bearer header, but the raw bearer
// value must appear NOWHERE in the emitted receipt bytes (stdout OR stderr) on
// either render. The token is a distinctive sentinel so a stray leak is
// unmistakable.
//
// Env-token edge (documented, not a failure): BARKPARK_CLOUD_TOKEN shadows the
// minted token in ResolveCloudToken, so on a machine where that env var is set the
// bearer that rides /v1/me — and the identity it names — would be the ENV token's,
// not the freshly-minted one. This test leaves that env unset so the assertion is
// about the minted token; the shadowing is acceptable because the receipt still
// names a real bound account.
func TestDeviceLoginReceiptNeverPrintsBearer(t *testing.T) {
	t.Setenv("BARKPARK_CLOUD_TOKEN", "") // pin the minted token as the sole bearer source
	const secret = "sess-SUPER-SECRET-bearer-do-not-print"
	const meBody = `{"user":{"id":"u-1","email":"ada@example.com"},` +
		`"team":{"id":"team-uuid","name":"Primary","slug":"primary"},"role":"owner"}`

	for _, output := range []string{"table", "json"} {
		t.Run(output, func(t *testing.T) {
			withTempConfigHome(t)
			withInstantDevicePolls(t, 10)
			var meAuth string
			srv := newMeDeviceServer(t, secret, "team-uuid", http.StatusOK, meBody, &meAuth)

			cfg := &Config{}
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = output
			if err := runDeviceLoginFlow(w, cfg, srv.URL, "bp"); err != nil {
				t.Fatalf("runDeviceLoginFlow: %v", err)
			}
			// The bearer DID ride the identity probe…
			if meAuth != "Bearer "+secret {
				t.Fatalf("/v1/me must carry the minted bearer; got %q", meAuth)
			}
			// …and it leaked into NEITHER stream of the receipt.
			if strings.Contains(stdout.String(), secret) {
				t.Fatalf("the bearer must never print on stdout:\n%s", stdout.String())
			}
			if strings.Contains(stderr.String(), secret) {
				t.Fatalf("the bearer must never print on stderr:\n%s", stderr.String())
			}
		})
	}
}

// TestOfferOpenDeskEnterReturnsSentinel: on a terminal, a bare Enter at the
// "open the desk" offer returns the ExitOpenDesk sentinel main() reads to launch
// the TUI in-process. The prompt is written to stderr (chrome), never stdout.
func TestOfferOpenDeskEnterReturnsSentinel(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.isTTY = true // force the interactive path (a buffer is not a real tty)

	var code int
	withStdin(t, "\n", func() { code = offerOpenDesk(w) })

	if code != ExitOpenDesk {
		t.Fatalf("bare Enter should return ExitOpenDesk (%d); got %d", ExitOpenDesk, code)
	}
	if !bytes.Contains(stderr.Bytes(), []byte("open the desk")) {
		t.Fatalf("the offer prompt should print to stderr; got:\n%s", stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("the offer must not write to stdout; got:\n%s", stdout.String())
	}
}

// TestOfferOpenDeskDeclineStaysPut: typing n declines — exitOK (not the
// sentinel), with a one-line reminder rather than a dead prompt.
func TestOfferOpenDeskDeclineStaysPut(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.isTTY = true

	var code int
	withStdin(t, "n\n", func() { code = offerOpenDesk(w) })

	if code != exitOK {
		t.Fatalf("declining should return exitOK; got %d", code)
	}
	if !bytes.Contains(stdout.Bytes(), []byte("Run 'bp'")) {
		t.Fatalf("declining should print a reminder; got:\n%s", stdout.String())
	}
}

// TestOfferOpenDeskSilentOnMachinePath: the report branch (-o json) and any
// non-tty are a SILENT no-op — no prompt, no stdin read, exitOK — so the
// {ok,…} envelope and headless callers are never disturbed.
func TestOfferOpenDeskSilentOnMachinePath(t *testing.T) {
	cases := []struct {
		name   string
		output string
		isTTY  bool
	}{
		{"json output even on a tty", "json", true},
		{"yaml output even on a tty", "yaml", true},
		{"table but non-tty (piped)", "table", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = tc.output
			w.isTTY = tc.isTTY

			// Stdin is primed with an Enter; the guard must return BEFORE reading it.
			var code int
			withStdin(t, "\n", func() { code = offerOpenDesk(w) })

			if code != exitOK {
				t.Fatalf("machine/non-tty path should return exitOK; got %d", code)
			}
			if stderr.Len() != 0 || stdout.Len() != 0 {
				t.Fatalf("machine/non-tty path must print nothing; stderr=%q stdout=%q", stderr.String(), stdout.String())
			}
		})
	}
}

// TestLoggedInWithoutServer covers the hint-hole predicate main() uses: a Cloud
// token with no active content server is the one true "logged in but not
// connected" state; a saved server, an env server, or no token all read false.
func TestLoggedInWithoutServer(t *testing.T) {
	// Neutralize the ambient env so the config is the sole signal. axi-b4: this
	// used to name two vars by hand and went stale the moment the dialect grew —
	// LoggedInWithoutServer reads ServerEnvNames, so a developer exporting
	// BARKPARK_URL made this suite assert against their own machine.
	clearBarkparkEnv(t)

	t.Run("cloud token, no server → true", func(t *testing.T) {
		withTempConfigHome(t)
		if err := SaveConfig(&Config{CloudURL: "https://api.barkpark.cloud", CloudToken: "sess"}); err != nil {
			t.Fatal(err)
		}
		if !LoggedInWithoutServer() {
			t.Fatal("cloud token + empty server should be logged-in-without-server")
		}
	})

	t.Run("cloud token WITH a server → false", func(t *testing.T) {
		withTempConfigHome(t)
		if err := SaveConfig(&Config{CloudToken: "sess", Server: "https://my.barkpark"}); err != nil {
			t.Fatal(err)
		}
		if LoggedInWithoutServer() {
			t.Fatal("a connected server means NOT logged-in-without-server")
		}
	})

	t.Run("no cloud token → false", func(t *testing.T) {
		withTempConfigHome(t)
		if err := SaveConfig(&Config{}); err != nil {
			t.Fatal(err)
		}
		if LoggedInWithoutServer() {
			t.Fatal("without a cloud token there is nothing logged in")
		}
	})

	t.Run("env server overrides → false", func(t *testing.T) {
		withTempConfigHome(t)
		if err := SaveConfig(&Config{CloudToken: "sess"}); err != nil {
			t.Fatal(err)
		}
		t.Setenv("BARKPARK_API_URL", "https://env.barkpark")
		if LoggedInWithoutServer() {
			t.Fatal("an explicit env server IS an active server")
		}
	})
}

// TestLoginCloudDeviceJSONEnvelopeNoAutoConnect: driving the FULL `bp login`
// device path with -o json emits a single clean {ok,cloud_url,team_id} envelope
// AND fires no auto-register — finishLoginConnect runs after the envelope but is
// frozen on the machine path (the device-branch gate cannot lean on a json
// early-return). Complements TestDeviceLoginFlowJSONEnvelopeCleanStdout, which
// exercises the helper directly; this proves the command wiring.
func TestLoginCloudDeviceJSONEnvelopeNoAutoConnect(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)
	forceDeviceTTY(t, true) // zero creds + both-TTY → device path engages
	stubBrowserOpener(t)
	t.Setenv("BARKPARK_PASSWORD", "")

	var barkparksHits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			_, _ = io.WriteString(w, `{"token":"sess-json","team_id":"team-json"}`)
		case "/v1/barkparks":
			barkparksHits++
			_, _ = io.WriteString(w, `{"barkparks":[{"id":"bp-1","name":"solo","url":"https://x"}]}`)
		}
	}))
	t.Cleanup(srv.Close)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runLoginCloud(out, []string{"--url", srv.URL})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout)
	}
	if env["ok"] != true || env["cloud_url"] != srv.URL || env["team_id"] != "team-json" {
		t.Fatalf("envelope = %v", env)
	}
	if barkparksHits != 0 {
		t.Fatalf("the -o json path must NOT auto-register; /v1/barkparks hit %d times", barkparksHits)
	}
}

// TestDeviceStartReturnsCodesWithoutPolling proves the non-interactive FIRST leg
// (`bp login --device-start`, BP-ONB-13): it mints the code pair via DeviceStart,
// emits it as a single JSON envelope (device_code/user_code/verification_uri/
// verification_uri_complete/interval/expires_in), and exits WITHOUT ever polling —
// the script drives the poll cadence itself. The pollHits==0 assertion is the
// heart of it: --device-start must NEVER block on a poll loop.
func TestDeviceStartReturnsCodesWithoutPolling(t *testing.T) {
	withTempConfigHome(t)

	var ds deviceServer
	srv := newDeviceServer(t, &ds, 0, "unused", "unused")

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runLoginCloud(out, []string{"--url", srv.URL, "--device-start"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK\n%s", code, stdout)
	}
	if ds.startHits.Load() != 1 {
		t.Fatalf("device/start hits = %d, want 1", ds.startHits.Load())
	}
	if ds.pollHits.Load() != 0 {
		t.Fatalf("--device-start must NOT poll; device/poll hits = %d, want 0", ds.pollHits.Load())
	}

	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout)
	}
	if env["device_code"] != "dev-secret" || env["user_code"] != "WXYZ-1234" {
		t.Fatalf("envelope missing the code pair: %v", env)
	}
	for _, k := range []string{"verification_uri", "verification_uri_complete", "interval", "expires_in"} {
		if _, ok := env[k]; !ok {
			t.Fatalf("envelope missing %q: %v", k, env)
		}
	}
	// A start-only step stores NOTHING — the token arrives on a later poll.
	if loaded, _ := LoadConfig(); loaded.CloudToken != "" {
		t.Fatalf("--device-start must not persist a token; got %q", loaded.CloudToken)
	}
}

// TestDevicePollSingleShotStatuses proves the non-interactive SECOND leg
// (`bp login --device-poll <code>`, BP-ONB-13): it performs EXACTLY ONE poll
// (pollHits==1 in every case — no 15-min loop) and maps the outcome to an exit
// code a shell `until` loop can drive: exitOK ONLY on approval, non-zero on
// pending/slow_down. On approval it persists token+team+url like the interactive
// flow; on pending it persists nothing.
func TestDevicePollSingleShotStatuses(t *testing.T) {
	t.Run("pending → one poll, non-zero exit, no token", func(t *testing.T) {
		withTempConfigHome(t)
		var pollHits atomic.Int64
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/v1/auth/device/poll" {
				pollHits.Add(1)
				_, _ = io.WriteString(w, `{"status":"pending"}`)
			}
		}))
		t.Cleanup(srv.Close)

		stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
			return runLoginCloud(out, []string{"--url", srv.URL, "--device-poll", "dev-secret"})
		})
		if code == exitOK {
			t.Fatalf("pending must be a non-zero exit so `until` keeps polling; got %d", code)
		}
		if pollHits.Load() != 1 {
			t.Fatalf("--device-poll must poll EXACTLY once; hits = %d", pollHits.Load())
		}
		var env map[string]any
		if err := json.Unmarshal([]byte(stdout), &env); err != nil {
			t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout)
		}
		if env["status"] != "pending" {
			t.Fatalf("envelope status = %v, want pending", env["status"])
		}
		if loaded, _ := LoadConfig(); loaded.CloudToken != "" {
			t.Fatalf("a pending poll must not persist a token; got %q", loaded.CloudToken)
		}
	})

	t.Run("slow_down → one poll, non-zero exit", func(t *testing.T) {
		withTempConfigHome(t)
		var pollHits atomic.Int64
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/v1/auth/device/poll" {
				pollHits.Add(1)
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = io.WriteString(w, `{"error":"slow_down"}`)
			}
		}))
		t.Cleanup(srv.Close)

		stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
			return runLoginCloud(out, []string{"--url", srv.URL, "--device-poll", "dev-secret"})
		})
		if code == exitOK {
			t.Fatalf("slow_down must be a non-zero exit; got %d", code)
		}
		if pollHits.Load() != 1 {
			t.Fatalf("--device-poll must poll EXACTLY once; hits = %d", pollHits.Load())
		}
		var env map[string]any
		if err := json.Unmarshal([]byte(stdout), &env); err != nil {
			t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout)
		}
		if env["status"] != "slow_down" {
			t.Fatalf("envelope status = %v, want slow_down", env["status"])
		}
	})

	t.Run("approved → one poll, exitOK, token persisted", func(t *testing.T) {
		withTempConfigHome(t)
		var pollHits atomic.Int64
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/v1/auth/device/poll" {
				pollHits.Add(1)
				_, _ = io.WriteString(w, `{"token":"sess-oneshot","team_id":"team-oneshot"}`)
			}
		}))
		t.Cleanup(srv.Close)

		stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
			return runLoginCloud(out, []string{"--url", srv.URL, "--device-poll", "dev-secret"})
		})
		if code != exitOK {
			t.Fatalf("approval must exit exitOK so `until` terminates; got %d\n%s", code, stdout)
		}
		if pollHits.Load() != 1 {
			t.Fatalf("--device-poll must poll EXACTLY once; hits = %d", pollHits.Load())
		}
		// Approval persists the session byte-identically to the interactive flow.
		loaded, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if loaded.CloudToken != "sess-oneshot" || loaded.CloudTeam != "team-oneshot" || loaded.CloudURL != srv.URL {
			t.Fatalf("approved poll must persist token+team+url; got %+v", loaded)
		}
		// devicePollStep emitted the success envelope; stdout stays a single doc.
		var env map[string]any
		if err := json.Unmarshal([]byte(stdout), &env); err != nil {
			t.Fatalf("stdout is not a single clean JSON envelope: %v\n%s", err, stdout)
		}
		if env["ok"] != true || env["team_id"] != "team-oneshot" {
			t.Fatalf("approved envelope = %v", env)
		}
	})
}

// TestLoginGatingTable is the CORE backward-compat proof: only a
// zero-credential + both-TTY (or --device) invocation takes the device path;
// every credential input, and any non-TTY, takes the password path verbatim
// (proven by which endpoint the fake control plane sees).
func TestLoginGatingTable(t *testing.T) {
	stubBrowserOpener(t) // never open a real browser on any path

	cases := []struct {
		name     string
		bothTTY  bool
		env      string   // BARKPARK_PASSWORD value ("" = unset)
		stdin    string   // scripted stdin for the password path
		args     []string // extra bp login flags (beyond --url)
		wantPath string   // the endpoint the fake plane should see
	}{
		{"no creds + both TTY → device", true, "", "", nil, "/v1/auth/device/start"},
		{"--device forces device even non-TTY", false, "", "", []string{"--device"}, "/v1/auth/device/start"},
		{"--email present → password path", true, "", "hunter2\n", []string{"--email", "a@b.com", "--password", "hunter2"}, "/v1/auth/login"},
		{"BARKPARK_PASSWORD set → password path", true, "envpass", "", []string{"--email", "a@b.com"}, "/v1/auth/login"},
		{"non-TTY no creds → password path", false, "", "a@b.com\nhunter2\n", nil, "/v1/auth/login"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			withInstantDevicePolls(t, 5)
			forceDeviceTTY(t, tc.bothTTY)
			t.Setenv("BARKPARK_PASSWORD", tc.env)

			// Record the FIRST /v1/auth/* route the plane sees — the device path
			// opens with device/start, the password path with login, so the first
			// auth hit is the unambiguous discriminator (device also hits poll after).
			// barkparksHits counts the auto-register fleet call: every case here runs
			// with a NON-tty writer (buffer), so the W2 auto-register tail must stay
			// frozen — a hit would mean the headless contract leaked.
			var firstAuthPath string
			var barkparksHits int
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if firstAuthPath == "" && strings.HasPrefix(r.URL.Path, "/v1/auth/") {
					firstAuthPath = r.URL.Path
				}
				switch r.URL.Path {
				case "/v1/auth/device/start":
					_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
				case "/v1/auth/device/poll":
					_, _ = io.WriteString(w, `{"token":"sess-dev","team_id":"team-dev"}`)
				case "/v1/auth/login":
					_, _ = io.WriteString(w, `{"token":"pw","team_id":"team-pw"}`)
				case "/v1/barkparks":
					barkparksHits++
					_, _ = io.WriteString(w, `{"barkparks":[]}`)
				}
			}))
			t.Cleanup(srv.Close)

			args := append([]string{"--url", srv.URL}, tc.args...)
			run := func() {
				_, _, code := runCloudCapture(t, false, func(out *writer) int {
					out.output = "table"
					return runLoginCloud(out, args)
				})
				if code != exitOK {
					t.Fatalf("exit = %d, want 0", code)
				}
			}
			if tc.stdin != "" {
				withStdin(t, tc.stdin, run)
			} else {
				run()
			}
			if firstAuthPath != tc.wantPath {
				t.Fatalf("routed to %q, want %q", firstAuthPath, tc.wantPath)
			}
			if barkparksHits != 0 {
				t.Fatalf("non-tty login must NOT auto-register; /v1/barkparks hit %d times", barkparksHits)
			}
		})
	}
}
