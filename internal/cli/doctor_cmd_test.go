package cli

// doctor_cmd_test.go drives `bp doctor` against an httptest server — no live
// deployment — through the REAL setup.RunHealthGate (only the gate's options are
// injected via doctorGateOpts, to trust the test TLS cert and point the stub
// probes at the fake). Two cases: all-green → exit 0 + a READY verdict, and a
// 403 websocket → non-zero exit + the failing check named. The volatile httptest
// URL is redacted before the golden compare so the fixture is stable.

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// doctorStatusHandler answers `defaultCode` for any path not in overrides, and
// the override code for paths that are — mirroring healthgate_test's
// statusHandler so one fake server can simulate "all green" or "websocket 403".
func doctorStatusHandler(defaultCode int, overrides map[string]int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c, ok := overrides[r.URL.Path]; ok {
			w.WriteHeader(c)
			return
		}
		w.WriteHeader(defaultCode)
	})
}

// doctorAllGreen is the per-path code set that makes every check pass: the four
// BaseURL checks (capabilities/studio/websocket-not-403/tls-via-200) plus the
// Postgres probe and the agent/backup stub probes the test points at this server.
func doctorAllGreen() map[string]int {
	return map[string]int{
		"/v1/capabilities": http.StatusOK,
		"/studio":          http.StatusOK,
		"/live/websocket":  http.StatusUpgradeRequired, // 426 — not 403
		"/w/default/p/default/v1/data/query/production/post": http.StatusOK,
		"/agent":  http.StatusOK,
		"/backup": http.StatusOK,
	}
}

// withDoctorGate swaps doctorGateOpts to trust srv's cert and point every probe
// at srv for the duration of the test, then restores it. This is the seam that
// lets doctor run the REAL gate against an httptest server.
func withDoctorGate(t *testing.T, srv *httptest.Server) {
	t.Helper()
	pool := x509.NewCertPool()
	if srv.TLS != nil {
		pool.AddCert(srv.Certificate())
	}
	orig := doctorGateOpts
	doctorGateOpts = func(base, token string) setup.HealthGate {
		return setup.HealthGate{
			RootCAs:          pool,
			PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
			AgentStatusURL:   srv.URL + "/agent",
			BackupStatusURL:  srv.URL + "/backup",
		}
	}
	t.Cleanup(func() { doctorGateOpts = orig })
}

// redactURL replaces the httptest server's URL (and its bare host:port, which the
// TLS check prints scheme-less) with fixed placeholders so the golden fixture is
// deterministic across the random port httptest picks.
func redactURL(s, rawURL string) string {
	s = strings.ReplaceAll(s, rawURL, "https://acme.test")
	if host := strings.TrimPrefix(rawURL, "https://"); host != rawURL {
		s = strings.ReplaceAll(s, host, "acme.test")
	}
	return s
}

// TestDoctorAllGreen: every check passes → exit 0, a READY verdict, and the human
// report matches the golden (URL redacted). Driven with an explicit --url so it
// needs no config.
func TestDoctorAllGreen(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, doctorAllGreen()))
	defer srv.Close()
	withDoctorGate(t, srv)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table" // force the human render path for the golden
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (all checks green)\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "READY") {
		t.Fatalf("all-green report should say READY:\n%s", stdout)
	}
	assertGolden(t, "doctor_all_green", redactURL(stdout, srv.URL))
}

// TestDoctorWebsocket403FailsNonZero: a 403 websocket sinks the gate → non-zero
// exit and the websocket-not-403 check is named as the failure.
func TestDoctorWebsocket403FailsNonZero(t *testing.T) {
	withTempConfigHome(t)
	ov := doctorAllGreen()
	ov["/live/websocket"] = http.StatusForbidden // the check_origin/PHX_HOST footgun
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, ov))
	defer srv.Close()
	withDoctorGate(t, srv)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	if code == exitOK {
		t.Fatalf("exit = 0, want non-zero when the websocket is 403\n%s", stdout)
	}
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d (a failed check)", code, exitGeneric)
	}
	if !strings.Contains(stdout, "websocket-not-403") {
		t.Fatalf("report must name the failing websocket check:\n%s", stdout)
	}
	if !strings.Contains(stdout, "NOT READY") {
		t.Fatalf("a failed gate should say NOT READY:\n%s", stdout)
	}
	if !strings.Contains(stdout, "✗") {
		t.Fatalf("a failed check should render the ✗ marker:\n%s", stdout)
	}
}

// TestDoctorJSONEnvelope: -o json emits a stable envelope with ok/target/checks/
// failures and a non-zero exit on failure. Exercises the agent of an agent: the
// shape an agent (non-TTY) consumes.
func TestDoctorJSONEnvelope(t *testing.T) {
	withTempConfigHome(t)
	ov := doctorAllGreen()
	ov["/live/websocket"] = http.StatusForbidden
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, ov))
	defer srv.Close()
	withDoctorGate(t, srv)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d on a failed gate", code, exitGeneric)
	}
	var env struct {
		OK     bool `json:"ok"`
		Checks []struct {
			Name string `json:"name"`
			Pass bool   `json:"pass"`
		} `json:"checks"`
		Failures []string `json:"failures"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("unmarshal %q: %v", stdout, err)
	}
	if env.OK {
		t.Fatalf("ok = true, want false on a 403 websocket: %s", stdout)
	}
	if len(env.Checks) != 7 {
		t.Fatalf("want 7 checks in the envelope, got %d: %s", len(env.Checks), stdout)
	}
	found := false
	for _, f := range env.Failures {
		if f == "websocket-not-403" {
			found = true
		}
	}
	if !found {
		t.Fatalf("failures should include websocket-not-403, got %v", env.Failures)
	}
}

// TestDoctorAllGreenJSONExitZero: the green path in JSON mode exits 0 with ok=true.
func TestDoctorAllGreenJSONExitZero(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, doctorAllGreen()))
	defer srv.Close()
	withDoctorGate(t, srv)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 on all-green\n%s", code, stdout)
	}
	if !bytes.Contains([]byte(stdout), []byte(`"ok": true`)) {
		t.Fatalf("green JSON should carry ok:true:\n%s", stdout)
	}
}

// TestDoctorResolvesActiveServer: with no --url, doctor probes the ACTIVE saved
// server. We seed an active server pointed at the fake plane (via --url-less path)
// by registering it under the test server URL, then assert the gate ran against
// it (READY). This proves the config target-resolution path, not just --url.
func TestDoctorResolvesActiveServer(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, doctorAllGreen()))
	defer srv.Close()
	withDoctorGate(t, srv)

	cfg := &Config{}
	cfg.RememberServer(ServerEntry{
		Name:   "acme",
		Server: srv.URL,
		Token:  "tok-acme",
		Tier:   "admin",
	})
	if e, ok := cfg.FindServer("acme"); ok {
		cfg.SetActiveServer(e)
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDoctor(out, nil) // no --url: resolve the active server
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (active server all-green)\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "acme") {
		t.Fatalf("report should name the resolved target acme:\n%s", stdout)
	}
	if !strings.Contains(stdout, "READY") {
		t.Fatalf("active-server probe should be READY:\n%s", stdout)
	}
}

// TestDoctorNoTarget: no --url and no active server is a clean usage error.
func TestDoctorNoTarget(t *testing.T) {
	withTempConfigHome(t) // empty config — no active server
	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runDoctor(out, nil)
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (no target)", code, exitUsage)
	}
}
