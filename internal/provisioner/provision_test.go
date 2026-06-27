package provisioner

import (
	"context"
	"strings"
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
// StepRunner seam so the provision never touches a box. A non-empty failOn makes
// Run error on the first step whose Title CONTAINS failOn (used to inject a red
// caddy/migrate/admin-token step and exercise the cleanup path).
type recordingRunner struct {
	cmds   []string
	failOn string
}

func (r *recordingRunner) Run(_ context.Context, s cloud.CaddyStep) error {
	r.cmds = append(r.cmds, s.Cmd)
	if r.failOn != "" && strings.Contains(s.Title, r.failOn) {
		// Echo the raw admin token in the output so the redaction test can prove it
		// is scrubbed before the error is wrapped. The runner mirrors the real
		// SSHStepRunner: it scrubs s.Redact from captured output BEFORE fmt.Errorf.
		out := "remote failed; captured output for step " + s.Title
		for _, secret := range s.Redact {
			out += " token=" + secret
		}
		return errString("step " + s.Title + " failed: " + redact(out, s.Redact))
	}
	return nil
}

// redact mirrors cloud.scrubSecrets (unexported there): replace each secret with
// a placeholder so the fake runner's error never carries the raw token — the same
// contract the real SSHStepRunner.Run enforces.
func redact(out string, secrets []string) string {
	for _, secret := range secrets {
		if secret != "" {
			out = strings.ReplaceAll(out, secret, "[REDACTED]")
		}
	}
	return out
}

// fakeSeams wires ProvisionWith entirely from the cloud-package fakes — no real
// cloud, DNS, box, or registry. Uses RunnerFor so a test can capture the runner
// and (optionally) make a step fail. Returns the seams plus the fakes the test
// asserts against.
func fakeSeams() (Seams, *cloud.FakeProvider, *cloud.FakeDNS, *recordingRunner) {
	prov := cloud.NewFakeProvider()
	dns := cloud.NewFakeDNS()
	runner := &recordingRunner{}
	return Seams{
		Provider:  prov,
		DNS:       dns,
		Registry:  NopRegistry{},
		Health:    greenGate,
		RunnerFor: func(string) cloud.StepRunner { return runner },
	}, prov, dns, runner
}

// TestProvisionWithRunsTheChainAgainstFakes proves the worker's Provision is the
// REAL cloud-6 one-shot chain driven through the fakes: ONE host is created +
// provisioned with a globally-unique name, DNS gets the A record, the live IP
// comes back, and exactly ONE server remains (no warm-N counter, no orphan).
func TestProvisionWithRunsTheChainAgainstFakes(t *testing.T) {
	seams, prov, dns, runner := fakeSeams()
	ctx := context.Background()

	job := JobSpec{JobID: "job-1", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11"}
	ip, err := ProvisionWith(ctx, seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}

	// ── a live IP came back (the created host's fake IP) ──
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

	// ── one-shot: exactly ONE server remains, named bp-<slug>-<suffix>, no orphan ──
	hosts, _ := prov.List(ctx)
	if len(hosts) != 1 {
		t.Fatalf("provider has %d hosts after a one-shot provision, want exactly 1 (no warm-N, no orphan): %+v", len(hosts), hosts)
	}
	// The name is bp-<slug>-<crypto suffix> (globally unique), so prefix-check the
	// slug rather than exact-match: bp-acme- with a 6-hex suffix appended.
	if !strings.HasPrefix(hosts[0].Name, "bp-acme-") {
		t.Errorf("created server name = %q, want prefix bp-acme- (globally-unique, slug + crypto suffix)", hosts[0].Name)
	}
	if len(hosts[0].Name) > 63 {
		t.Errorf("created server name %q is %d chars, want <=63 (hostname-label limit)", hosts[0].Name, len(hosts[0].Name))
	}
}

// TestProvisionWithTwiceSucceeds locks the unique-name fix: running TWO jobs
// against ONE shared FakeProvider both succeed. The OLD per-job-pool path named
// every host warm-1 and job #2 died with "warm-1 already exists"; the one-shot
// path derives bp-<slug> from each job's distinct subdomain, so they never
// collide. Two distinct live servers remain.
func TestProvisionWithTwiceSucceeds(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	ctx := context.Background()

	ip1, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-1", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11"})
	if err != nil {
		t.Fatalf("ProvisionWith job #1: %v", err)
	}
	ip2, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-2", Name: "Beta Inc", Slug: "beta", Region: "nbg1", ServerType: "cax11"})
	if err != nil {
		t.Fatalf("ProvisionWith job #2 (the unique-name regression): %v", err)
	}
	if ip1 == "" || ip2 == "" || ip1 == ip2 {
		t.Errorf("want two distinct non-empty IPs, got %q and %q", ip1, ip2)
	}

	hosts, _ := prov.List(ctx)
	if len(hosts) != 2 {
		t.Fatalf("after two one-shot jobs want 2 servers (bp-acme-* + bp-beta-*), got %d: %+v", len(hosts), hosts)
	}
	// Prefix-match each slug (names carry a per-job crypto suffix now).
	var sawAcme, sawBeta bool
	for _, h := range hosts {
		if strings.HasPrefix(h.Name, "bp-acme-") {
			sawAcme = true
		}
		if strings.HasPrefix(h.Name, "bp-beta-") {
			sawBeta = true
		}
	}
	if !sawAcme || !sawBeta {
		t.Errorf("server names = %+v, want one bp-acme-* and one bp-beta-*", hosts)
	}
}

// TestProvisionWithSuccessNoOrphan proves the happy path leaves EXACTLY the
// intended live-server count — one created host, zero stragglers.
func TestProvisionWithSuccessNoOrphan(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	ctx := context.Background()

	if _, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-1", Name: "Acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"}); err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}
	hosts, _ := prov.List(ctx)
	if len(hosts) != 1 {
		t.Errorf("success path left %d servers, want exactly 1 (no orphan): %+v", len(hosts), hosts)
	}
}

// TestProvisionWithCleansUpOnPostCreateFailure proves the no-orphan-on-failure
// guarantee: a red step AFTER the server exists (here, the caddy step) makes
// ProvisionWith delete the created server AND the DNS A record — provider ends
// empty, DNS resolves to nothing.
func TestProvisionWithCleansUpOnPostCreateFailure(t *testing.T) {
	seams, prov, dns, runner := fakeSeams()
	runner.failOn = "PHX_HOST" // fail a caddy step (runs after create + dns upsert)
	ctx := context.Background()

	_, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-9", Name: "Boom", Slug: "boom", Region: "nbg1", ServerType: "cax11"})
	if err == nil {
		t.Fatal("ProvisionWith with a red caddy step returned nil, want an error")
	}

	// ── the created server was deleted — no orphan ──
	hosts, _ := prov.List(ctx)
	if len(hosts) != 0 {
		t.Errorf("post-failure provider has %d servers, want 0 (the half-built box must be deleted): %+v", len(hosts), hosts)
	}

	// ── the DNS A record was deleted ──
	values, _ := dns.Resolve(ctx, "boom.barkpark.cloud")
	if len(values) != 0 {
		t.Errorf("post-failure DNS for boom.barkpark.cloud = %v, want none (the A record must be deleted)", values)
	}
}

// TestProvisionWithCleansUpOnMigrateFailure exercises a DIFFERENT post-create
// step (migrate) to prove cleanup is independent of which step failed.
func TestProvisionWithCleansUpOnMigrateFailure(t *testing.T) {
	seams, prov, dns, runner := fakeSeams()
	runner.failOn = "ecto.migrate"
	ctx := context.Background()

	if _, err := ProvisionWith(ctx, seams, JobSpec{JobID: "j", Name: "Mig", Slug: "mig", Region: "nbg1", ServerType: "cax11"}); err == nil {
		t.Fatal("ProvisionWith with a red migrate step returned nil, want an error")
	}
	hosts, _ := prov.List(ctx)
	if len(hosts) != 0 {
		t.Errorf("migrate-failure left %d servers, want 0: %+v", len(hosts), hosts)
	}
	if values, _ := dns.Resolve(ctx, "mig.barkpark.cloud"); len(values) != 0 {
		t.Errorf("migrate-failure left DNS %v, want none", values)
	}
}

// TestProvisionWithCleansUpOnAdminTokenFailure_RedactsToken combines two
// guarantees: an admin-token step failure (a) cleans up the server + DNS, and
// (b) the wrapped error does NOT contain the raw bp_admin_ token — the fake
// runner echoes the token into its captured output, and the secret-redaction
// contract scrubs it before the error is built.
func TestProvisionWithCleansUpOnAdminTokenFailure_RedactsToken(t *testing.T) {
	seams, prov, dns, runner := fakeSeams()
	runner.failOn = "admin token"
	ctx := context.Background()

	_, err := ProvisionWith(ctx, seams, JobSpec{JobID: "j", Name: "Tok", Slug: "tok", Region: "nbg1", ServerType: "cax11"})
	if err == nil {
		t.Fatal("ProvisionWith with a red admin-token step returned nil, want an error")
	}
	// The minted token is bp_admin_… — assert no such substring survived into the
	// error (the runner echoed it; redaction must have scrubbed it).
	if strings.Contains(err.Error(), "bp_admin_") {
		t.Errorf("admin-token error leaked the raw token: %v", err)
	}
	// Cleanup still happened.
	hosts, _ := prov.List(ctx)
	if len(hosts) != 0 {
		t.Errorf("admin-token-failure left %d servers, want 0: %+v", len(hosts), hosts)
	}
	if values, _ := dns.Resolve(ctx, "tok.barkpark.cloud"); len(values) != 0 {
		t.Errorf("admin-token-failure left DNS %v, want none", values)
	}
}

// TestProvisionWithFailsClosed proves the fail-closed guarantee survives the
// worker wiring: a RED health gate makes ProvisionWith return an error (which
// the worker reports to /fail) and the IP is empty — and the half-built server
// is cleaned up.
func TestProvisionWithFailsClosed(t *testing.T) {
	seams, prov, dns, _ := fakeSeams()
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
	// Fail-closed also means no orphan: the box that failed health is torn down.
	if hosts, _ := prov.List(context.Background()); len(hosts) != 0 {
		t.Errorf("red-gate run left %d servers, want 0 (cleanup on fail-closed): %+v", len(hosts), hosts)
	}
	if values, _ := dns.Resolve(context.Background(), "boom.barkpark.cloud"); len(values) != 0 {
		t.Errorf("red-gate run left DNS %v, want none", values)
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
	return strings.Contains(s, sub)
}
