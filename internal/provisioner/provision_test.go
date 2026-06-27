package provisioner

import (
	"context"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// greenGate is a cloud.HealthChecker that passes without a live server — the
// fake gate the happy-path provision runs against (no real https probe).
func greenGate(_ context.Context, base, _ string) (setup.HealthReport, error) {
	return setup.HealthReport{
		BaseURL: base,
		OK:      true,
		Checks: []setup.CheckResult{
			{Name: "capabilities", Pass: true, Detail: "ok (fake)"},
			{Name: "websocket-not-403", Pass: true, Detail: "ok (fake)"},
		},
	}, nil
}

// recordingRunner records Caddy/migrate steps instead of shelling out — the fake
// StepRunner seam so the provision never touches a box.
type recordingRunner struct{ cmds []string }

func (r *recordingRunner) Run(_ context.Context, s cloud.CaddyStep) error {
	r.cmds = append(r.cmds, s.Cmd)
	return nil
}

// fakeSeams wires ProvisionWith entirely from the cloud-package fakes — no real
// cloud, DNS, box, or registry. Returns the seams plus the fakes the test
// asserts against.
func fakeSeams() (Seams, *cloud.FakeProvider, *cloud.FakeDNS, *recordingRunner) {
	prov := cloud.NewFakeProvider()
	dns := cloud.NewFakeDNS()
	runner := &recordingRunner{}
	return Seams{
		Provider: prov,
		DNS:      dns,
		Registry: NopRegistry{},
		Health:   greenGate,
		Runner:   runner,
	}, prov, dns, runner
}

// TestProvisionWithRunsTheChainAgainstFakes proves the worker's Provision is the
// REAL cloud-6 WarmPool.Provision driven through the fakes: a host is created +
// provisioned, DNS gets the A record, the live IP comes back. This is the seam
// the FullChainGreen test (warmpool_test.go) proves in isolation — here we prove
// the worker's wiring reaches it.
func TestProvisionWithRunsTheChainAgainstFakes(t *testing.T) {
	seams, prov, dns, runner := fakeSeams()
	ctx := context.Background()

	job := JobSpec{JobID: "job-1", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11"}
	ip, err := ProvisionWith(ctx, seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}

	// ── a live IP came back (the popped warm host's fake IP) ──
	if ip == "" {
		t.Fatal("ProvisionWith returned an empty IP")
	}

	// ── DNS got acme.barkpark.cloud → that IP ──
	values, err := dns.Resolve(ctx, "acme.barkpark.cloud")
	if err != nil {
		t.Fatalf("dns.Resolve: %v", err)
	}
	if len(values) != 1 || values[0] != ip {
		t.Errorf("DNS for acme.barkpark.cloud = %v, want [%s]", values, ip)
	}

	// ── the Caddy steps ran with PHX_HOST set + migrate ran ──
	var sawPHX, sawMigrate bool
	for _, c := range runner.cmds {
		if contains(c, "PHX_HOST=acme.barkpark.cloud") {
			sawPHX = true
		}
		if contains(c, "ecto.migrate") {
			sawMigrate = true
		}
	}
	if !sawPHX {
		t.Errorf("Caddy steps did not set PHX_HOST=acme.barkpark.cloud; ran: %v", runner.cmds)
	}
	if !sawMigrate {
		t.Errorf("migrate step did not run; ran: %v", runner.cmds)
	}

	// ── the pool stays warm: the popped host + one replacement exist ──
	hosts, _ := prov.List(ctx)
	if len(hosts) != 2 {
		t.Errorf("provider has %d hosts after provision, want 2 (popped + replacement): %+v", len(hosts), hosts)
	}
}

// TestProvisionWithFailsClosed proves the fail-closed guarantee survives the
// worker wiring: a RED health gate makes ProvisionWith return an error (which
// the worker reports to /fail) and the IP is empty.
func TestProvisionWithFailsClosed(t *testing.T) {
	seams, _, _, _ := fakeSeams()
	seams.Health = func(_ context.Context, base, _ string) (setup.HealthReport, error) {
		return setup.HealthReport{BaseURL: base, OK: false, Checks: []setup.CheckResult{
			{Name: "websocket-not-403", Pass: false, Detail: "403 (fake)"},
		}}, errString("health gate failed: websocket-not-403")
	}

	job := JobSpec{JobID: "job-3", Name: "boom", Slug: "boom", Region: "nbg1", ServerType: "cax11"}
	ip, err := ProvisionWith(context.Background(), seams, job)
	if err == nil {
		t.Fatal("ProvisionWith with a red gate returned nil, want an error (fail closed)")
	}
	if ip != "" {
		t.Errorf("ProvisionWith returned ip %q on a red gate, want empty", ip)
	}
}

// TestProvisionWithNoProviderErrors proves a missing provider fails fast.
func TestProvisionWithNoProviderErrors(t *testing.T) {
	seams := Seams{DNS: cloud.NewFakeDNS(), Registry: NopRegistry{}, Health: greenGate}
	if _, err := ProvisionWith(context.Background(), seams, JobSpec{Name: "x", Slug: "x"}); err == nil {
		t.Fatal("ProvisionWith with no provider returned nil, want a config error")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
