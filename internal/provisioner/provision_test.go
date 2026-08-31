package provisioner

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

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

	// freshen (dwb-17) capture controls, mirroring the cloud-package recordingRunner.
	// Default (zero value) → the box is CURRENT, so freshen is a no-op. Set `behind`
	// to drive the rebuild path; `checkErr` / `rebuildErr` to drive the fail-closed
	// warm-create teardown paths.
	behind     bool
	checkErr   error
	rebuildErr error
	rebuildRan bool
	// checkGate, when non-nil, blocks the cheap-check until the channel is closed —
	// lets a test hold a freshen "in flight" to prove the one-in-flight refresh guard.
	checkGate chan struct{}
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

// RunOutput implements the cloud.hostCommandRunner capture capability the freshen
// step type-asserts. It scripts the cheap-check output (current by default, behind
// when r.behind) and the rebuild.
func (r *recordingRunner) RunOutput(_ context.Context, script string) (string, error) {
	if strings.Contains(script, "apply-update.sh") {
		r.rebuildRan = true
		if r.rebuildErr != nil {
			return "rebuild failed on box", r.rebuildErr
		}
		return "rebuilt", nil
	}
	if r.checkGate != nil {
		<-r.checkGate // block until the test releases the in-flight freshen
	}
	if r.checkErr != nil {
		return "fatal: unable to access origin", r.checkErr
	}
	head, remote := "abc123", "abc123"
	if r.behind {
		head, remote = "aaa111", "bbb222"
	}
	return "FRESHEN_HEAD=" + head + "\nFRESHEN_REMOTE=" + remote + "\nFRESHEN_FROM=v0.42\nFRESHEN_TO=v0.45\n", nil
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
// asserts against. It also points the golden-path VERIFY gate (C2) at an
// all-green httptest fake instance so a happy-path provision reaches `ready`
// without a real network call; a test that wants to exercise a red probe swaps
// seams.VerifyBaseURL for a fake instance with the failing behavior.
func fakeSeams(t *testing.T) (Seams, *cloud.FakeProvider, *cloud.FakeDNS, *recordingRunner) {
	t.Helper()
	prov := cloud.NewFakeProvider()
	dns := cloud.NewFakeDNS()
	runner := &recordingRunner{}
	inst := newFakeInstance(t, fakeInstanceBehavior{})
	return Seams{
		Provider:      prov,
		DNS:           dns,
		Registry:      NopRegistry{},
		Health:        greenGate,
		RunnerFor:     func(string) cloud.StepRunner { return runner },
		VerifyBaseURL: inst.URL,
		// Poll fast so the bounded health-gate poll's retry/fail-closed path runs
		// without real sleeps (production leaves these zero → the ~10s/~4m defaults).
		HealthPollInterval: time.Millisecond,
		HealthPollDeadline: 30 * time.Millisecond,
	}, prov, dns, runner
}

// TestProvisionWithRunsTheChainAgainstFakes proves the worker's Provision is the
// REAL cloud-6 one-shot chain driven through the fakes: ONE host is created +
// provisioned with a globally-unique name, DNS gets the A record, the live IP
// comes back, and exactly ONE server remains (no warm-N counter, no orphan).
func TestProvisionWithRunsTheChainAgainstFakes(t *testing.T) {
	seams, prov, dns, runner := fakeSeams(t)
	ctx := context.Background()

	job := JobSpec{JobID: "job-1", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11"}
	ip, adminToken, _, teardown, err := ProvisionWith(ctx, seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}

	// ── a live IP came back (the created host's fake IP) ──
	if ip == "" {
		t.Fatal("ProvisionWith returned an empty IP")
	}
	// ── the minted per-instance admin token (instance-admin-token) is surfaced so
	// the worker can report it on /succeed (stored encrypted for the owner) ──
	if !strings.HasPrefix(adminToken, "bp_admin_") {
		t.Errorf("ProvisionWith adminToken = %q, want a bp_admin_ token to forward to the control plane", adminToken)
	}
	// ── success hands back a non-nil teardown (the worker's orphan lever) ──
	if teardown == nil {
		t.Fatal("ProvisionWith returned a nil teardown on success, want non-nil (the worker needs it to tear down an orphan on a succeed-report failure)")
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
	var sawPHX, sawSelfUpdate, sawMigrate bool
	for _, c := range runner.cmds {
		if contains(c, "PHX_HOST=acme.barkpark.cloud") {
			sawPHX = true
		}
		if contains(c, "BARKPARK_SELF_UPDATE_APPLY=1") {
			sawSelfUpdate = true
		}
		if contains(c, "ecto.migrate") {
			sawMigrate = true
		}
	}
	if !sawPHX {
		t.Errorf("Caddy steps did not set PHX_HOST=acme.barkpark.cloud; ran: %v", runner.cmds)
	}
	// New boxes get the self-update executor flag at provision time (managed
	// boxes are cloud-operated; the team autoupdate policy is the consent).
	if !sawSelfUpdate {
		t.Errorf("provision steps did not set BARKPARK_SELF_UPDATE_APPLY=1; ran: %v", runner.cmds)
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
	seams, prov, _, _ := fakeSeams(t)
	ctx := context.Background()

	ip1, _, _, _, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-1", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11"})
	if err != nil {
		t.Fatalf("ProvisionWith job #1: %v", err)
	}
	ip2, _, _, _, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-2", Name: "Beta Inc", Slug: "beta", Region: "nbg1", ServerType: "cax11"})
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
	seams, prov, _, _ := fakeSeams(t)
	ctx := context.Background()

	if _, _, _, _, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-1", Name: "Acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"}); err != nil {
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
	seams, prov, dns, runner := fakeSeams(t)
	runner.failOn = "PHX_HOST" // fail a caddy step (runs after create + dns upsert)
	ctx := context.Background()

	_, _, _, teardown, err := ProvisionWith(ctx, seams, JobSpec{JobID: "job-9", Name: "Boom", Slug: "boom", Region: "nbg1", ServerType: "cax11"})
	if err == nil {
		t.Fatal("ProvisionWith with a red caddy step returned nil, want an error")
	}
	// ── on failure the teardown is nil: the box was already cleaned up by the
	// provision path, so the worker has nothing left to tear down ──
	if teardown != nil {
		t.Error("ProvisionWith returned a non-nil teardown on failure, want nil (the half-built box was already cleaned up)")
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
	seams, prov, dns, runner := fakeSeams(t)
	runner.failOn = "ecto.migrate"
	ctx := context.Background()

	if _, _, _, _, err := ProvisionWith(ctx, seams, JobSpec{JobID: "j", Name: "Mig", Slug: "mig", Region: "nbg1", ServerType: "cax11"}); err == nil {
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
	seams, prov, dns, runner := fakeSeams(t)
	runner.failOn = "admin token"
	ctx := context.Background()

	_, _, _, _, err := ProvisionWith(ctx, seams, JobSpec{JobID: "j", Name: "Tok", Slug: "tok", Region: "nbg1", ServerType: "cax11"})
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
	seams, prov, dns, _ := fakeSeams(t)
	seams.Health = func(_ context.Context, base, _ string) (setup.HealthReport, error) {
		return setup.HealthReport{BaseURL: base, OK: false, Checks: []setup.CheckResult{
			{Name: "websocket-not-403", Pass: false, Detail: "403 (fake)"},
		}}, errString("health gate failed: websocket-not-403")
	}

	job := JobSpec{JobID: "job-3", Name: "boom", Slug: "boom", Region: "nbg1", ServerType: "cax11"}
	ip, _, _, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err == nil {
		t.Fatal("ProvisionWith with a red gate returned nil, want an error (fail closed)")
	}
	if ip != "" {
		t.Errorf("ProvisionWith returned ip %q on a red gate, want empty", ip)
	}
	if teardown != nil {
		t.Error("ProvisionWith returned a non-nil teardown on a fail-closed gate, want nil (the box was already torn down)")
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
	if _, _, _, _, err := ProvisionWith(context.Background(), seams, JobSpec{Name: "x", Slug: "x"}); err == nil {
		t.Fatal("ProvisionWith with no provider returned nil, want a config error")
	}
}

func contains(s, sub string) bool {
	return strings.Contains(s, sub)
}

// TestSweepWith_DeletesOnlyOrphans proves the worker-facing sweep seam deletes
// ONLY boxes labeled barkpark-orphaned=true, leaving a managed (live) box alone.
// It exercises SweepWith over the FakeProvider, the same path DefaultSweep binds
// for main().
func TestSweepWith_DeletesOnlyOrphans(t *testing.T) {
	ctx := context.Background()
	prov := cloud.NewFakeProvider()

	// A live managed box (created → managed=true) and a leaked orphan (teardown
	// marked it orphaned after a persistent Delete failure).
	live, _ := prov.Create(ctx, cloud.ServerSpec{Name: "live-box"})
	orphan, _ := prov.Create(ctx, cloud.ServerSpec{Name: "bp-orphan"})
	if err := prov.LabelServer(ctx, orphan.Name, cloud.OrphanedLabelKey, "true"); err != nil {
		t.Fatalf("mark orphan: %v", err)
	}

	seams := Seams{Provider: prov, DNS: cloud.NewFakeDNS()}
	swept, err := SweepWith(ctx, seams)
	if err != nil {
		t.Fatalf("SweepWith: %v", err)
	}
	if swept != 1 {
		t.Errorf("swept %d, want 1 (only the orphan)", swept)
	}
	hosts, _ := prov.List(ctx)
	if len(hosts) != 1 || hosts[0].Name != live.Name {
		t.Errorf("after sweep hosts=%+v, want only the live managed box", hosts)
	}
}

// TestDefaultSweep_BindsSeams proves DefaultSweep returns a SweepFunc bound to the
// seams (the value main() hands the worker), and that it is a clean no-op when
// there are no orphans.
func TestDefaultSweep_BindsSeams(t *testing.T) {
	prov := cloud.NewFakeProvider()
	_, _ = prov.Create(context.Background(), cloud.ServerSpec{Name: "only-managed"})
	sweep := DefaultSweep(Seams{Provider: prov, DNS: cloud.NewFakeDNS()})

	swept, err := sweep(context.Background())
	if err != nil {
		t.Fatalf("DefaultSweep: %v", err)
	}
	if swept != 0 {
		t.Errorf("swept %d on a managed-only fleet, want 0", swept)
	}
}

// stepRec records every step transition ProvisionWith reports (dwb-14). Its
// Report ALWAYS returns an error to prove the failure is swallowed — a broken
// control plane must never fail a provision (narration is telemetry).
// TestProvisionReportsLiveCaptions (dwb-19) proves the live sub-captions reach
// the reporter as `<step>/progress` with a human detail at each real
// sub-boundary — create narrates the server IP, secure the fqdn, configure the
// database, content the bootstrap caption (proving the DetailSink→report wiring),
// ready the finishing line — and that NO token ever rides in a caption.
func TestProvisionReportsLiveCaptions(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	rec := &detailRec{}
	seams.StepReporter = rec.Report
	// The fake bootstrap invokes the DetailSink so the content caption path is
	// exercised end-to-end at the provisioner boundary (the real captions come
	// from internal/bootstrap, covered by its own test).
	seams.Bootstrap = func(_ context.Context, req BootstrapRequest) (*BootstrapOutputs, error) {
		if req.DetailSink != nil {
			req.DetailSink("Creating your workspace…")
		}
		return &BootstrapOutputs{Template: "blog", Workspace: "acme"}, nil
	}

	job := JobSpec{JobID: "job-caps", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11", Template: "blog"}
	ip, adminToken, _, _, err := ProvisionWith(context.Background(), seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}

	// create narrates the real server IP (the user owns it — safe to surface).
	if got := rec.detail("create", "progress"); !strings.Contains(got, "Server up at "+ip) {
		t.Errorf("create/progress caption = %q, want it to narrate %q", got, "Server up at "+ip)
	}
	// secure narrates the fqdn at one of its sub-boundaries (DNS → TLS).
	if !rec.hasDetail("secure", "progress", "acme.barkpark.cloud") {
		t.Errorf("no secure/progress caption narrated the fqdn; got %v", rec.all())
	}
	// configure narrates plain language (never raw command output).
	if got := rec.detail("configure", "progress"); got == "" {
		t.Error("configure/progress emitted no caption")
	}
	// content: the DetailSink caption reached the reporter as content/progress.
	if got := rec.detail("content", "progress"); got != "Creating your workspace…" {
		t.Errorf("content/progress caption = %q, want the DetailSink line", got)
	}
	// ready: a finishing caption before the terminal done.
	if got := rec.detail("ready", "progress"); got == "" {
		t.Error("ready/progress emitted no caption")
	}

	// Redaction posture: the minted admin token never leaks into any caption.
	if !strings.HasPrefix(adminToken, "bp_admin_") {
		t.Fatalf("expected a bp_admin_ token, got %q", adminToken)
	}
	for _, d := range rec.all() {
		if strings.Contains(d, "bp_admin_") || strings.Contains(d, adminToken) {
			t.Errorf("a token leaked into a caption: %q", d)
		}
	}
}

// detailRec captures (step, status, detail) for the dwb-19 caption assertions.
type detailRec struct {
	mu      sync.Mutex
	entries []struct{ step, status, detail string }
}

func (r *detailRec) Report(_ context.Context, _ /*jobID*/, step, status, detail string) error {
	r.mu.Lock()
	r.entries = append(r.entries, struct{ step, status, detail string }{step, status, detail})
	r.mu.Unlock()
	return nil
}

// detail returns the LAST detail reported for step/status (captions are
// latest-wins), or "" if none.
func (r *detailRec) detail(step, status string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := ""
	for _, e := range r.entries {
		if e.step == step && e.status == status {
			out = e.detail
		}
	}
	return out
}

// hasDetail reports whether any recorded step/status detail contains sub.
func (r *detailRec) hasDetail(step, status, sub string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.entries {
		if e.step == step && e.status == status && strings.Contains(e.detail, sub) {
			return true
		}
	}
	return false
}

func (r *detailRec) all() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var ds []string
	for _, e := range r.entries {
		ds = append(ds, e.detail)
	}
	return ds
}

type stepRec struct {
	mu    sync.Mutex
	steps []string // "step/status" in order
}

func (s *stepRec) Report(_ context.Context, _ /*jobID*/, step, status, _ /*detail*/ string) error {
	s.mu.Lock()
	s.steps = append(s.steps, step+"/"+status)
	s.mu.Unlock()
	return errString("control plane unreachable (simulated)")
}

func (s *stepRec) has(want string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, got := range s.steps {
		if got == want {
			return true
		}
	}
	return false
}

// TestProvisionReportsStepsAndSwallowsReportErrors (dwb-14) proves two things at
// once against the fakes: (1) the create→live chain reports the honest step
// vocabulary — create/secure/configure (chain) + content/ready (provisioner) —
// with started+done transitions; and (2) a StepReporter that fails on EVERY call
// does NOT fail the provision (it still returns a live IP). Non-vacuous: the
// reporter returns an error each time, yet ProvisionWith succeeds.
func TestProvisionReportsStepsAndSwallowsReportErrors(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	rec := &stepRec{}
	seams.StepReporter = rec.Report
	// A template so the content (bootstrap) step runs; inject a fake bootstrap so no
	// instance is touched.
	seams.Bootstrap = func(context.Context, BootstrapRequest) (*BootstrapOutputs, error) {
		return &BootstrapOutputs{Template: "blog", Workspace: "acme"}, nil
	}

	job := JobSpec{JobID: "job-steps", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11", Template: "blog"}
	ip, _, boot, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith failed despite step-report being pure telemetry: %v", err)
	}
	if ip == "" || teardown == nil {
		t.Fatalf("ProvisionWith returned ip=%q teardown=%v, want a live IP + teardown", ip, teardown)
	}
	if boot == nil {
		t.Fatal("ProvisionWith returned nil bootstrap outputs, want the fake's outputs")
	}

	// The honest vocabulary reached the reporter, in each phase, started→done.
	for _, want := range []string{
		"create/started", "create/done",
		"secure/started", "secure/done",
		"configure/started", "configure/done",
		"content/started", "content/done",
		"ready/done",
	} {
		if !rec.has(want) {
			t.Errorf("step %q was not reported; got %v", want, rec.steps)
		}
	}
}

// TestProvisionSkipsContentWhenNoTemplate (dwb-14) proves the content step is
// only narrated when the job carries a template — a template-less job walks
// create→secure→configure→ready with NO content transition.
func TestProvisionSkipsContentWhenNoTemplate(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	rec := &stepRec{}
	seams.StepReporter = rec.Report

	job := JobSpec{JobID: "job-notmpl", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11"}
	if _, _, _, _, err := ProvisionWith(context.Background(), seams, job); err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}
	if rec.has("content/started") || rec.has("content/done") {
		t.Errorf("content step was reported for a template-less job; got %v", rec.steps)
	}
	if !rec.has("ready/done") {
		t.Errorf("ready/done not reported; got %v", rec.steps)
	}
}
