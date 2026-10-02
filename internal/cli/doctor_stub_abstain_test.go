package cli

import (
	"crypto/x509"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// task-0421f0261badd1d6 — `bp doctor` against a healthy instance exited 1 on
// every run, because the two cloud-9/10 stub checks (agent/backup) have no
// endpoint on ANY instance yet and the default gate treated "unwired" as
// "not ready". The default now declares them optional: they abstain (NOT
// CHECKED) — not a failure, and not counted as a pass either.
func TestDoctorDefaultGateLetsUnwiredStubsAbstain(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, doctorAllGreen()))
	defer srv.Close()

	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	orig := doctorGateOpts
	// The REAL default options (no stub URLs), plus only what a test needs to
	// reach the fake: its CA and the scoped Postgres probe path.
	doctorGateOpts = func(base, token string) setup.HealthGate {
		g := orig(base, token)
		g.RootCAs = pool
		g.PostgresProbeURL = srv.URL + "/w/default/p/default/v1/data/query/production/post"
		return g
	}
	t.Cleanup(func() { doctorGateOpts = orig })

	if g := orig("https://x.test", "tok"); !g.StubsOptional || g.AgentStatusURL != "" || g.BackupStatusURL != "" {
		t.Fatalf("default doctor gate: StubsOptional=%v agent=%q backup=%q — want optional, unwired", g.StubsOptional, g.AgentStatusURL, g.BackupStatusURL)
	}

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 — a healthy instance must not fail on unwired cloud-9/10 stubs\n%s", code, stdout)
	}
	for _, name := range []string{"agent-connected-stub", "backup-scheduled-stub"} {
		line := ""
		for _, ln := range strings.Split(stdout, "\n") {
			if strings.Contains(ln, name) {
				line = ln
			}
		}
		if line == "" || !strings.Contains(line, "NOT CHECKED") {
			t.Errorf("%s must still print, as NOT CHECKED (abstaining), got %q\n%s", name, line, stdout)
		}
	}
}
