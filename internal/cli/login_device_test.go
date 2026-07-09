package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
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
			var firstAuthPath string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if firstAuthPath == "" {
					firstAuthPath = r.URL.Path
				}
				switch r.URL.Path {
				case "/v1/auth/device/start":
					_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
				case "/v1/auth/device/poll":
					_, _ = io.WriteString(w, `{"token":"sess-dev","team_id":"team-dev"}`)
				case "/v1/auth/login":
					_, _ = io.WriteString(w, `{"token":"pw","team_id":"team-pw"}`)
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
		})
	}
}
