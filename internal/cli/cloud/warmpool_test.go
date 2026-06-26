package cloud

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// recordingRunner records every CaddyStep it is handed instead of shelling out —
// the fake step-runner seam, mirroring caddy_test.go's fakeStepRunner. It never
// touches a box and never issues an ACME cert.
type recordingRunner struct {
	titles []string
	cmds   []string
	argvs  [][]string
}

func (r *recordingRunner) Run(_ context.Context, s CaddyStep) error {
	r.titles = append(r.titles, s.Title)
	r.cmds = append(r.cmds, s.Cmd)
	r.argvs = append(r.argvs, s.Argv)
	return nil
}

func (r *recordingRunner) joined() string { return strings.Join(r.cmds, "\n") }

// greenGate is a HealthChecker that returns an all-pass report without a live
// server — the fake gate the happy-path chain runs against.
func greenGate(base string) HealthChecker {
	return func(_ context.Context, _, _ string) (setup.HealthReport, error) {
		return setup.HealthReport{
			BaseURL: base,
			OK:      true,
			Checks:  passingChecks("capabilities", "studio", "websocket-not-403", "tls", "postgres-via-api"),
		}, nil
	}
}

// passingChecks builds a slice of passing checks for the fake report so the
// green report reads cleanly.
func passingChecks(names ...string) []setup.CheckResult {
	out := make([]setup.CheckResult, len(names))
	for i, n := range names {
		out[i] = setup.CheckResult{Name: n, Pass: true, Detail: "ok (fake)"}
	}
	return out
}

// acmeSpec is the canonical go-live fixture: acme.barkpark.cloud, app on :4000,
// a base health URL pointed at a fake (empty deploy → no real https probe).
func acmeSpec() GoLiveSpec {
	return GoLiveSpec{
		Name:    "acme",
		Zone:    "barkpark.cloud",
		App:     4000,
		Spec:    ServerSpec{Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"},
		BaseURL: "http://10.0.0.1:4000", // fake target; greenGate ignores it anyway
	}
}

// newFakeWarmPool wires a WarmPool entirely from fakes: a FakeProvider-backed
// pool pre-seeded with one warm host, FakeDNS, the recording runner, FakeRegistry,
// and the supplied health checker. Returns the pool + the fakes the test asserts
// against.
func newFakeWarmPool(t *testing.T, health HealthChecker) (*WarmPool, *FakeProvider, *FakeDNS, *recordingRunner, *FakeRegistry) {
	t.Helper()
	prov := NewFakeProvider()
	dns := NewFakeDNS()
	runner := &recordingRunner{}
	reg := NewFakeRegistry()

	pool, err := SeedPool(context.Background(), prov, 1, ServerSpec{Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"})
	if err != nil {
		t.Fatalf("SeedPool: %v", err)
	}
	if pool.Len() != 1 {
		t.Fatalf("seeded pool: want 1 warm host, got %d", pool.Len())
	}

	wp := &WarmPool{
		Pool:     pool,
		DNS:      dns,
		Runner:   runner,
		Health:   health,
		Registry: reg,
	}
	return wp, prov, dns, runner, reg
}

// TestProvision_FullChainGreen drives the WHOLE assign→live sequence against
// fakes and asserts every seam fired: a host was popped, DNS upserted for
// acme.barkpark.cloud, the Caddy steps ran with PHX_HOST set, migrate ran,
// health ran, the server registered, and a replacement warm host was created.
func TestProvision_FullChainGreen(t *testing.T) {
	spec := acmeSpec()
	wp, prov, dns, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	ctx := context.Background()

	// The seeded warm host (warm-1) is what pop assigns; record it up front.
	before, _ := prov.List(ctx)
	if len(before) != 1 || before[0].Name != "warm-1" {
		t.Fatalf("pre-provision pool: want [warm-1], got %+v", before)
	}
	assignedIP := before[0].IP

	live, err := wp.Provision(ctx, spec)
	if err != nil {
		t.Fatalf("Provision: unexpected error: %v", err)
	}

	// ── popped host ──
	if live.IP != assignedIP {
		t.Errorf("live server IP = %q, want the popped warm host IP %q", live.IP, assignedIP)
	}
	if live.FQDN != "acme.barkpark.cloud" {
		t.Errorf("live FQDN = %q, want acme.barkpark.cloud", live.FQDN)
	}

	// ── DNS upserted for acme.barkpark.cloud → the popped IP ──
	values, err := dns.Resolve(ctx, "acme.barkpark.cloud")
	if err != nil {
		t.Fatalf("dns.Resolve: %v", err)
	}
	if len(values) != 1 || values[0] != assignedIP {
		t.Errorf("DNS for acme.barkpark.cloud = %v, want [%s]", values, assignedIP)
	}

	// ── Caddy steps ran with PHX_HOST set ──
	if len(runner.cmds) == 0 {
		t.Fatal("no Caddy/migrate steps ran through the injected runner")
	}
	all := runner.joined()
	if !strings.Contains(all, "PHX_HOST=acme.barkpark.cloud") {
		t.Errorf("Caddy steps did not set PHX_HOST=acme.barkpark.cloud; ran:\n%s", all)
	}
	if !strings.Contains(all, "PHX_SCHEME=https") {
		t.Errorf("Caddy steps did not set PHX_SCHEME=https; ran:\n%s", all)
	}

	// ── migrate ran ──
	if !strings.Contains(all, "ecto.migrate") {
		t.Errorf("migrate step did not run; ran:\n%s", all)
	}

	// ── server registered ──
	if !reg.Has("acme.barkpark.cloud") {
		t.Errorf("acme.barkpark.cloud was not registered; registry=%+v", reg.Registered())
	}
	if got := reg.Registered(); len(got) != 1 {
		t.Errorf("registry: want 1 server, got %d", len(got))
	} else if got[0].Secrets.SecretKeyBase == "" || got[0].Secrets.AdminToken == "" {
		t.Errorf("registered server missing minted secrets: %+v", got[0].Secrets)
	}

	// ── a replacement warm host was created (pool stays warm) ──
	after, _ := prov.List(ctx)
	// warm-1 was popped (still exists in the provider — pop does not delete the
	// host), and warm-2 was created as the refill: 2 hosts total.
	if len(after) != 2 {
		t.Fatalf("post-provision provider: want 2 hosts (popped + replacement), got %d: %+v", len(after), after)
	}
	var sawReplacement bool
	for _, s := range after {
		if s.Name == "warm-2" {
			sawReplacement = true
		}
	}
	if !sawReplacement {
		t.Errorf("no replacement warm host (warm-2) was created; provider=%+v", after)
	}
	// The pool itself is back to 1 ready host (popped one, refilled one).
	if wp.Pool.Len() != 1 {
		t.Errorf("pool ready count = %d after provision, want 1 (refilled)", wp.Pool.Len())
	}
}

// TestProvision_HealthFailsClosed asserts the FAIL-CLOSED rule: a red health
// gate stops the chain — Provision returns an error and the server is NOT
// registered.
func TestProvision_HealthFailsClosed(t *testing.T) {
	spec := acmeSpec()
	redGate := func(_ context.Context, base, _ string) (setup.HealthReport, error) {
		rep := setup.HealthReport{
			BaseURL: base,
			OK:      false,
			Checks: []setup.CheckResult{
				{Name: "capabilities", Pass: true, Detail: "ok (fake)"},
				{Name: "websocket-not-403", Pass: false, Detail: "403 — check_origin/PHX_HOST drift (fake)"},
			},
		}
		// Mirror RunHealthGate's contract: a non-OK report returns a non-nil error
		// naming the failed checks. Provision treats either signal as fail-closed.
		return rep, fmt.Errorf("health gate failed: %s not ready", strings.Join(rep.Failures(), ", "))
	}
	wp, _, dns, _, reg := newFakeWarmPool(t, redGate)
	ctx := context.Background()

	_, err := wp.Provision(ctx, spec)
	if err == nil {
		t.Fatal("Provision: want an error when the health gate is red, got nil")
	}
	if !strings.Contains(err.Error(), "health") {
		t.Errorf("error should name the health stage, got: %v", err)
	}

	// The server must NOT be registered — fail closed.
	if reg.Has("acme.barkpark.cloud") {
		t.Errorf("acme.barkpark.cloud was registered despite a red health gate — chain did not fail closed")
	}
	if got := reg.Registered(); len(got) != 0 {
		t.Errorf("registry: want 0 servers after a red gate, got %d: %+v", len(got), got)
	}

	// DNS was still upserted (it precedes health in the chain) — the assigned
	// host exists; it just never got marked ready. That is the honest state.
	values, _ := dns.Resolve(ctx, "acme.barkpark.cloud")
	if len(values) != 1 {
		t.Errorf("DNS should still hold the pre-health A record, got %v", values)
	}
}
