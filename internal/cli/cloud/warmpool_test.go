package cloud

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"

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

// ─── FIX 1: pattern-based .env secret scrubbing ──────────────────────────────

// TestScrubEnvSecrets_RedactsShapes asserts the PATTERN scrubber redacts
// secret-SHAPED substrings the worker can't enumerate (the values are generated
// on the box): the ecto/postgres URL userinfo and the SECRET_KEY_BASE /
// BARKPARK_CLOAK_KEY / PREVIEW_JWT_SECRET / DATABASE_URL assignments.
func TestScrubEnvSecrets_RedactsShapes(t *testing.T) {
	in := "ERROR: connect ecto://bp:hunter2@localhost/db failed\n" +
		"BARKPARK_CLOAK_KEY=abc123xyz\n" +
		"SECRET_KEY_BASE=deadBEEF0123456789\n" +
		"PREVIEW_JWT_SECRET=jwt-shhh\n" +
		"DATABASE_URL=ecto://u:p@h:5432/d\n" +
		"postgres://admin:s3cr3t@10.0.0.1/app also here"
	out := scrubEnvSecrets(in)

	// No raw secret VALUE survives.
	for _, leaked := range []string{"hunter2", "abc123xyz", "deadBEEF0123456789", "jwt-shhh", "s3cr3t", "u:p@h"} {
		if strings.Contains(out, leaked) {
			t.Errorf("scrubEnvSecrets leaked %q; got:\n%s", leaked, out)
		}
	}
	// The KEY names / schemes are kept so the failure is still diagnosable.
	for _, kept := range []string{"BARKPARK_CLOAK_KEY=[REDACTED]", "SECRET_KEY_BASE=[REDACTED]", "PREVIEW_JWT_SECRET=[REDACTED]", "DATABASE_URL=[REDACTED]", "ecto://[REDACTED]@", "postgres://[REDACTED]@"} {
		if !strings.Contains(out, kept) {
			t.Errorf("scrubEnvSecrets dropped expected %q; got:\n%s", kept, out)
		}
	}
}

// TestScrubEnvSecrets_LeavesCleanOutput asserts the scrubber is a no-op on output
// with no secret shapes — it must not mangle ordinary error text.
func TestScrubEnvSecrets_LeavesCleanOutput(t *testing.T) {
	in := "migration 20260101 failed: relation \"posts\" already exists"
	if out := scrubEnvSecrets(in); out != in {
		t.Errorf("scrubEnvSecrets mangled clean output:\n in: %s\nout: %s", in, out)
	}
}

// TestSSHRunner_MigrateFailure_ScrubsEnvSecrets is the FIX-1 integration: a
// migrate step (RedactEnvSecrets=true) whose captured SSH output carries a DB
// password and a cloak key has BOTH scrubbed in the wrapped error, AND the
// literal-token Redact path still works in the SAME error. This is the exact leak
// the review flagged: a migrate failure flowing raw secrets into worker.fail().
func TestSSHRunner_MigrateFailure_ScrubsEnvSecrets(t *testing.T) {
	const dbURL = "ecto://bp:hunter2@localhost/db"
	const cloak = "BARKPARK_CLOAK_KEY=abc123"
	const literalTok = "bp_admin_LITERALSECRET"
	captured := "remote migrate failed\nDATABASE_URL=" + dbURL + "\n" + cloak + "\nleftover " + literalTok

	r := &SSHStepRunner{
		Host: "198.51.100.7",
		Key:  "/dev/null",
		Exec: func(_ context.Context, _ string, _ ...string) (string, error) {
			return captured, fmt.Errorf("exit status 1")
		},
	}
	step := CaddyStep{
		Title:            "run database migrations (mix ecto.migrate)",
		Argv:             []string{"bash", "-lc", "set -a; . /opt/barkpark/.env; set +a; mix ecto.migrate"},
		Redact:           []string{literalTok}, // literal-token path must still work
		RedactEnvSecrets: true,                 // pattern path
	}

	err := r.Run(context.Background(), step)
	if err == nil {
		t.Fatal("SSHStepRunner.Run: want an error for a failed migrate step, got nil")
	}
	msg := err.Error()
	for _, leaked := range []string{"hunter2", "abc123", literalTok} {
		if strings.Contains(msg, leaked) {
			t.Errorf("migrate-failure error leaked %q; got:\n%s", leaked, msg)
		}
	}
	// The redaction markers + the surviving key names prove it was scrubbed, not
	// dropped wholesale.
	if !strings.Contains(msg, "[REDACTED]") {
		t.Errorf("migrate-failure error has no [REDACTED] marker — was anything scrubbed? got:\n%s", msg)
	}
}

// TestRealStepRunner_ScrubsEnvSecrets proves the LOCAL real runner path also
// pattern-scrubs: a failing .env-sourcing step's captured output is redacted in
// the error. Uses a command guaranteed to fail (a missing binary) but the secret
// must come from the step's OWN echoed output, so we instead run a tiny shell
// that prints the secrets then exits non-zero.
func TestRealStepRunner_ScrubsEnvSecrets(t *testing.T) {
	step := CaddyStep{
		Title: "env-sourcing step",
		// Print a bare ecto URL (NOT a DATABASE_URL= assignment — that path is
		// covered by the unit test; here we isolate the userinfo regex), then fail.
		// No real .env, no SSH — this is a LOCAL exec of /bin/sh that the
		// realStepRunner shells out.
		Argv:             []string{"sh", "-c", "echo 'connect to ecto://bp:hunter2@localhost/db failed'; exit 3"},
		RedactEnvSecrets: true,
	}
	err := realStepRunner{}.Run(context.Background(), step)
	if err == nil {
		t.Fatal("realStepRunner.Run: want an error for the exit-3 step, got nil")
	}
	if strings.Contains(err.Error(), "hunter2") {
		t.Errorf("realStepRunner leaked the DB password; got:\n%s", err.Error())
	}
	if !strings.Contains(err.Error(), "ecto://[REDACTED]@") {
		t.Errorf("realStepRunner did not pattern-scrub the ecto userinfo; got:\n%s", err.Error())
	}
}

// ─── FIX 2: globally-unique server name ──────────────────────────────────────

// TestOneShotServerName_GloballyUnique asserts two calls for the SAME slug return
// DIFFERENT names (the crypto suffix makes a per-team slug globally unique), both
// start "bp-", and both are <=63 chars.
func TestOneShotServerName_GloballyUnique(t *testing.T) {
	a := oneShotServerName("prod")
	b := oneShotServerName("prod")
	if a == b {
		t.Errorf("oneShotServerName(\"prod\") returned the same name twice (%q) — not globally unique", a)
	}
	for _, n := range []string{a, b} {
		if !strings.HasPrefix(n, "bp-") {
			t.Errorf("name %q does not start with bp-", n)
		}
		if !strings.HasPrefix(n, "bp-prod-") {
			t.Errorf("name %q does not keep the slug (want bp-prod-<suffix>)", n)
		}
		if len(n) > serverNameMaxLen {
			t.Errorf("name %q is %d chars, want <=%d", n, len(n), serverNameMaxLen)
		}
	}
}

// TestOneShotServerName_CapsAt63 asserts a very long slug is truncated so the
// final name fits 63 chars while ALWAYS keeping the bp- prefix and the -<suffix>.
func TestOneShotServerName_CapsAt63(t *testing.T) {
	longSlug := strings.Repeat("a", 200)
	n := oneShotServerName(longSlug)
	if len(n) > serverNameMaxLen {
		t.Errorf("name for a 200-char slug is %d chars, want <=%d: %q", len(n), serverNameMaxLen, n)
	}
	if !strings.HasPrefix(n, "bp-") {
		t.Errorf("truncated name %q dropped the bp- prefix", n)
	}
	// The suffix (last serverNameSuffixHex chars after a dash) must survive the cap.
	wantSuffixLen := serverNameSuffixHex
	parts := strings.Split(n, "-")
	last := parts[len(parts)-1]
	if len(last) != wantSuffixLen {
		t.Errorf("truncated name %q lost its %d-char suffix (got suffix %q)", n, wantSuffixLen, last)
	}
}

// TestOneShotServerName_EmptyAndJunkSlug asserts a slug that sanitizes to empty
// still yields a valid bp-<stem>-<suffix> rather than "bp--<suffix>".
func TestOneShotServerName_EmptyAndJunkSlug(t *testing.T) {
	for _, slug := range []string{"", "   ", "@@@", "***"} {
		n := oneShotServerName(slug)
		if !strings.HasPrefix(n, "bp-") || strings.HasPrefix(n, "bp--") {
			t.Errorf("oneShotServerName(%q) = %q, want a non-empty stem (no bp-- )", slug, n)
		}
		if len(n) > serverNameMaxLen {
			t.Errorf("oneShotServerName(%q) = %q is %d chars, want <=%d", slug, n, len(n), serverNameMaxLen)
		}
	}
}

// ─── FIX 4: cleanupHost surfaces the Delete error ────────────────────────────

// deleteErrProvider is a CloudProvider whose Delete always errors — used to prove
// cleanupHost surfaces (does not swallow) a failed teardown of a BILLED box.
type deleteErrProvider struct {
	*FakeProvider
	deleteCalls int
}

func (d *deleteErrProvider) Delete(_ context.Context, name string) error {
	d.deleteCalls++
	return fmt.Errorf("hcloud server delete %q: rate limited (fake)", name)
}

// deleteErrDNS is a FakeDNS whose DeleteRecord always errors — used to prove the
// DNS-delete failure is ALSO surfaced, not just the server one.
type deleteErrDNS struct {
	*FakeDNS
}

func (deleteErrDNS) DeleteRecord(_ context.Context, _, _, _ string) error {
	return fmt.Errorf("dns delete: upstream 500 (fake)")
}

// TestCleanupHost_SurfacesServerDeleteError asserts a failed Provider.Delete
// during cleanup is RETURNED (so the caller can log it), not swallowed — the
// review's FIX 4. The error must name the orphaned server so a leaked billed box
// is detectable.
func TestCleanupHost_SurfacesServerDeleteError(t *testing.T) {
	prov := &deleteErrProvider{FakeProvider: NewFakeProvider()}
	wp := &WarmPool{Provider: prov, DNS: NewFakeDNS(), DeleteRetryBackoff: time.Millisecond}
	spec := acmeSpec()

	err := wp.cleanupHost(Server{Name: "bp-acme-abc123", IP: "10.0.0.5"}, spec)
	if err == nil {
		t.Fatal("cleanupHost swallowed a failed server Delete — want a surfaced error (FIX 4)")
	}
	// EDGE 1: Delete is now retried before giving up, so the full budget is spent.
	if prov.deleteCalls != deleteRetries+1 {
		t.Errorf("Provider.Delete called %d times, want %d (deleteRetries+1)", prov.deleteCalls, deleteRetries+1)
	}
	if !strings.Contains(err.Error(), "bp-acme-abc123") || !strings.Contains(err.Error(), "ORPHAN") {
		t.Errorf("cleanup error should name the orphaned server; got: %v", err)
	}
}

// TestCleanupHost_SurfacesBothDeleteErrors asserts a failed DNS delete AND a
// failed server delete are BOTH surfaced (cleanup is best-effort — it attempts
// both even when one fails — but reports everything that went wrong).
func TestCleanupHost_SurfacesBothDeleteErrors(t *testing.T) {
	prov := &deleteErrProvider{FakeProvider: NewFakeProvider()}
	wp := &WarmPool{Provider: prov, DNS: deleteErrDNS{FakeDNS: NewFakeDNS()}, DeleteRetryBackoff: time.Millisecond}
	spec := acmeSpec()

	err := wp.cleanupHost(Server{Name: "bp-acme-abc123", IP: "10.0.0.5"}, spec)
	if err == nil {
		t.Fatal("cleanupHost swallowed failed deletes — want a surfaced error")
	}
	msg := err.Error()
	if !strings.Contains(msg, "DNS") {
		t.Errorf("cleanup error should mention the DNS delete failure; got: %v", err)
	}
	if !strings.Contains(msg, "bp-acme-abc123") {
		t.Errorf("cleanup error should mention the server delete failure; got: %v", err)
	}
	// Best-effort: the server delete was still attempted despite the DNS failure
	// (and retried the full budget before giving up).
	if prov.deleteCalls != deleteRetries+1 {
		t.Errorf("Provider.Delete called %d times, want %d (best-effort, retried)", prov.deleteCalls, deleteRetries+1)
	}
}

// TestCleanupHost_CleanTeardownReturnsNil asserts the happy teardown (both deletes
// succeed) returns nil, so a successful cleanup creates no spurious log noise.
func TestCleanupHost_CleanTeardownReturnsNil(t *testing.T) {
	prov := NewFakeProvider()
	srv, err := prov.Create(context.Background(), ServerSpec{Name: "bp-acme-abc123"})
	if err != nil {
		t.Fatalf("seed Create: %v", err)
	}
	dns := NewFakeDNS()
	wp := &WarmPool{Provider: prov, DNS: dns}
	if cerr := wp.cleanupHost(srv, acmeSpec()); cerr != nil {
		t.Errorf("cleanupHost on a clean teardown returned %v, want nil", cerr)
	}
	// The server is actually gone.
	if hosts, _ := prov.List(context.Background()); len(hosts) != 0 {
		t.Errorf("clean cleanup left %d servers, want 0", len(hosts))
	}
}

// ─── EDGE 1: teardown Delete retry + orphan-label marking + SweepOrphans ─────

// flakyDeleteProvider fails Delete for the first failDeletes calls then succeeds,
// modelling a transient Hetzner Delete blip. It records label calls so a test can
// assert the orphan label was (or was NOT) set. Embeds FakeProvider for
// Create/IP/List/ListByLabel.
type flakyDeleteProvider struct {
	*FakeProvider
	failDeletes int // first N Delete calls fail
	deleteCalls int
	labelCalls  []string // "<name> <key>=<val>" per LabelServer call
}

func (p *flakyDeleteProvider) Delete(ctx context.Context, name string) error {
	p.deleteCalls++
	if p.deleteCalls <= p.failDeletes {
		return fmt.Errorf("hcloud server delete %q: rate limited (fake transient)", name)
	}
	return p.FakeProvider.Delete(ctx, name)
}

func (p *flakyDeleteProvider) LabelServer(ctx context.Context, name, key, val string) error {
	p.labelCalls = append(p.labelCalls, fmt.Sprintf("%s %s=%s", name, key, val))
	return p.FakeProvider.LabelServer(ctx, name, key, val)
}

// TestCleanupHost_RetriesDeleteThenSucceeds asserts the teardown Delete is RETRIED
// on a transient blip: a provider that fails Delete twice then succeeds is retried
// (deleteRetries+1 attempts available) and the box is gone — NO orphan label set,
// clean (nil) return. This is the common "Hetzner hiccupped once" self-heal.
func TestCleanupHost_RetriesDeleteThenSucceeds(t *testing.T) {
	prov := &flakyDeleteProvider{FakeProvider: NewFakeProvider(), failDeletes: 2}
	srv, err := prov.Create(context.Background(), ServerSpec{Name: "bp-acme-retry"})
	if err != nil {
		t.Fatalf("seed Create: %v", err)
	}
	wp := &WarmPool{Provider: prov, DNS: NewFakeDNS(), DeleteRetryBackoff: time.Millisecond}

	if cerr := wp.cleanupHost(srv, acmeSpec()); cerr != nil {
		t.Errorf("cleanupHost should self-heal after 2 transient Delete failures, got: %v", cerr)
	}
	// 2 failures + 1 success = 3 attempts (== deleteRetries+1).
	if prov.deleteCalls != deleteRetries+1 {
		t.Errorf("Delete attempted %d times, want %d (deleteRetries+1)", prov.deleteCalls, deleteRetries+1)
	}
	if len(prov.labelCalls) != 0 {
		t.Errorf("orphan label set despite a successful retry: %v", prov.labelCalls)
	}
	if hosts, _ := prov.List(context.Background()); len(hosts) != 0 {
		t.Errorf("box not deleted after retry; %d remain", len(hosts))
	}
}

// TestCleanupHost_PersistentDeleteFailureMarksOrphan asserts the double-failure
// recovery flag: when Delete fails on EVERY attempt, cleanupHost (a) retries the
// full budget then (b) best-effort stamps barkpark-orphaned=true AND the FQDN, so
// SweepOrphans can recover the box later. The returned error names the orphan and
// says it was marked for the sweep.
func TestCleanupHost_PersistentDeleteFailureMarksOrphan(t *testing.T) {
	prov := &flakyDeleteProvider{FakeProvider: NewFakeProvider(), failDeletes: 1000} // never succeeds
	srv, err := prov.Create(context.Background(), ServerSpec{Name: "bp-acme-orphan"})
	if err != nil {
		t.Fatalf("seed Create: %v", err)
	}
	wp := &WarmPool{Provider: prov, DNS: NewFakeDNS(), DeleteRetryBackoff: time.Millisecond}

	cerr := wp.cleanupHost(srv, acmeSpec())
	if cerr == nil {
		t.Fatal("cleanupHost: want an error when Delete persistently fails, got nil")
	}
	// The full retry budget was spent.
	if prov.deleteCalls != deleteRetries+1 {
		t.Errorf("Delete attempted %d times, want %d (full budget)", prov.deleteCalls, deleteRetries+1)
	}
	// The orphan + FQDN labels were stamped on the leaked box.
	gotOrphaned, gotFQDN := false, false
	for _, c := range prov.labelCalls {
		if strings.Contains(c, OrphanedLabelKey+"=true") {
			gotOrphaned = true
		}
		if strings.Contains(c, FQDNLabelKey+"=acme.barkpark.cloud") {
			gotFQDN = true
		}
	}
	if !gotOrphaned {
		t.Errorf("box not marked %s=true on persistent Delete failure; labelCalls=%v", OrphanedLabelKey, prov.labelCalls)
	}
	if !gotFQDN {
		t.Errorf("box not stamped with its FQDN for DNS recovery; labelCalls=%v", prov.labelCalls)
	}
	// The actual stored labels reflect the marking, so a subsequent ListByLabel
	// would find it.
	orphans, _ := prov.ListByLabel(context.Background(), OrphanedLabelKey, "true")
	if len(orphans) != 1 || orphans[0].Name != "bp-acme-orphan" {
		t.Errorf("ListByLabel(orphaned) = %+v, want the marked box", orphans)
	}
	if !strings.Contains(cerr.Error(), "BILLED ORPHAN") || !strings.Contains(cerr.Error(), "marked") {
		t.Errorf("cleanup error should name the orphan and the marking; got: %v", cerr)
	}
}

// TestSweepOrphans_DeletesOnlyOrphaned is the core SAFETY assertion: SweepOrphans
// deletes ONLY boxes labeled barkpark-orphaned=true. A managed-but-not-orphaned
// box and an UNLABELED box must survive — the sweep can never touch a live box.
func TestSweepOrphans_DeletesOnlyOrphaned(t *testing.T) {
	ctx := context.Background()
	prov := NewFakeProvider()

	// (a) a healthy managed box (created → managed=true, never orphaned).
	managed, _ := prov.Create(ctx, ServerSpec{Name: "managed-live"})
	// (b) an unlabeled box (created outside Barkpark) — strip its labels.
	unlabeled, _ := prov.Create(ctx, ServerSpec{Name: "rando-box"})
	if err := stripLabels(prov, unlabeled.Name); err != nil {
		t.Fatalf("stripLabels: %v", err)
	}
	// (c) two orphaned boxes (teardown marked them).
	orphanA, _ := prov.Create(ctx, ServerSpec{Name: "bp-orphan-a"})
	orphanB, _ := prov.Create(ctx, ServerSpec{Name: "bp-orphan-b"})
	for _, o := range []Server{orphanA, orphanB} {
		if err := prov.LabelServer(ctx, o.Name, OrphanedLabelKey, "true"); err != nil {
			t.Fatalf("mark orphan: %v", err)
		}
	}
	// Give orphanA an FQDN label + a DNS record so the sweep's DNS cleanup is exercised.
	if err := prov.LabelServer(ctx, orphanA.Name, FQDNLabelKey, "orphan-a.barkpark.cloud"); err != nil {
		t.Fatalf("fqdn label: %v", err)
	}
	dns := NewFakeDNS()
	_ = dns.UpsertRecord(ctx, Record{Zone: "barkpark.cloud", Name: "orphan-a", Type: "A", Value: "203.0.113.7"})

	wp := &WarmPool{Provider: prov, DNS: dns}
	swept, err := wp.SweepOrphans(ctx)
	if err != nil {
		t.Fatalf("SweepOrphans: %v", err)
	}
	if swept != 2 {
		t.Errorf("swept %d boxes, want 2 (the two orphans)", swept)
	}

	// The managed and unlabeled boxes MUST survive.
	remaining, _ := prov.List(ctx)
	names := map[string]bool{}
	for _, s := range remaining {
		names[s.Name] = true
	}
	if !names[managed.Name] {
		t.Errorf("the managed (not orphaned) box %q was deleted — sweep crossed the fence!", managed.Name)
	}
	if !names[unlabeled.Name] {
		t.Errorf("the unlabeled box %q was deleted — sweep crossed the fence!", unlabeled.Name)
	}
	if names["bp-orphan-a"] || names["bp-orphan-b"] {
		t.Errorf("an orphaned box survived the sweep; remaining=%v", names)
	}
	if len(remaining) != 2 {
		t.Errorf("after sweep %d boxes remain, want 2 (managed + unlabeled)", len(remaining))
	}

	// The orphan's stranded DNS record was deleted too (recovered from its FQDN label).
	if vals, _ := dns.Resolve(ctx, "orphan-a.barkpark.cloud"); len(vals) != 0 {
		t.Errorf("orphan-a DNS record survived the sweep: %v", vals)
	}
}

// TestSweepOrphans_NoOrphansIsCleanNoop asserts an empty orphan set is a clean
// (0, nil) no-op — the common case, no spurious error/noise.
func TestSweepOrphans_NoOrphansIsCleanNoop(t *testing.T) {
	prov := NewFakeProvider()
	_, _ = prov.Create(context.Background(), ServerSpec{Name: "managed-only"})
	wp := &WarmPool{Provider: prov, DNS: NewFakeDNS()}

	swept, err := wp.SweepOrphans(context.Background())
	if err != nil {
		t.Fatalf("SweepOrphans on no orphans returned error: %v", err)
	}
	if swept != 0 {
		t.Errorf("swept %d, want 0 (nothing orphaned)", swept)
	}
	if hosts, _ := prov.List(context.Background()); len(hosts) != 1 {
		t.Errorf("the managed box was disturbed; %d remain, want 1", len(hosts))
	}
}

// TestSweepOrphans_ContinuesPastDeleteFailure asserts the sweep is best-effort: a
// box whose Delete fails is left labeled (retried next sweep) but the OTHER orphan
// is still deleted, and the aggregated error names the failure.
func TestSweepOrphans_ContinuesPastDeleteFailure(t *testing.T) {
	ctx := context.Background()
	// stuckProvider: Delete fails for a specific name, succeeds otherwise.
	prov := &stuckDeleteProvider{FakeProvider: NewFakeProvider(), stuckName: "bp-stuck"}
	good, _ := prov.Create(ctx, ServerSpec{Name: "bp-good"})
	stuck, _ := prov.Create(ctx, ServerSpec{Name: "bp-stuck"})
	for _, o := range []Server{good, stuck} {
		_ = prov.LabelServer(ctx, o.Name, OrphanedLabelKey, "true")
	}
	wp := &WarmPool{Provider: prov, DNS: NewFakeDNS()}

	swept, err := wp.SweepOrphans(ctx)
	if swept != 1 {
		t.Errorf("swept %d, want 1 (the good orphan deleted despite the stuck one)", swept)
	}
	if err == nil || !strings.Contains(err.Error(), "bp-stuck") {
		t.Errorf("sweep error should name the stuck box; got: %v", err)
	}
	// The good orphan is gone, the stuck one survives (still labeled, retried later).
	remaining, _ := prov.List(ctx)
	if len(remaining) != 1 || remaining[0].Name != "bp-stuck" {
		t.Errorf("after sweep remaining=%+v, want only the stuck box", remaining)
	}
}

// stuckDeleteProvider fails Delete only for stuckName.
type stuckDeleteProvider struct {
	*FakeProvider
	stuckName string
}

func (p *stuckDeleteProvider) Delete(ctx context.Context, name string) error {
	if name == p.stuckName {
		return fmt.Errorf("hcloud server delete %q: still in use (fake)", name)
	}
	return p.FakeProvider.Delete(ctx, name)
}

// stripLabels clears a fake box's labels, modelling a box created outside Barkpark
// (no managed/orphaned labels at all) so the sweep-safety test can prove an
// unlabeled box is never touched.
func stripLabels(fp *FakeProvider, name string) error {
	fp.mu.Lock()
	defer fp.mu.Unlock()
	srv, ok := fp.servers[name]
	if !ok {
		return fmt.Errorf("strip: %q not found", name)
	}
	srv.Labels = nil
	fp.servers[name] = srv
	return nil
}

// TestProvisionOneShot_LogsFailedCleanup proves the end-to-end FIX-4 wiring: when
// a one-shot provision fails AFTER create AND the orphan teardown's Delete also
// fails, ProvisionOneShot LOGS the cleanup failure to stderr (so a leaked billed
// box is observable in the worker journal) rather than swallowing it. We capture
// os.Stderr around the call and assert the warning lands.
func TestProvisionOneShot_LogsFailedCleanup(t *testing.T) {
	// A provider that CREATES fine (so the chain gets past create) but ERRORS on
	// Delete (so cleanup fails). Embeds FakeProvider for Create/IP/List.
	prov := &deleteErrProvider{FakeProvider: NewFakeProvider()}
	runner := &recordingRunner{}
	// Make a post-create step fail so cleanupHost runs. The recordingRunner here
	// never errors, so force the failure via a red health gate instead.
	redGate := func(_ context.Context, base, _ string) (setup.HealthReport, error) {
		return setup.HealthReport{BaseURL: base, OK: false, Checks: []setup.CheckResult{{Name: "x", Pass: false}}},
			fmt.Errorf("health gate failed (fake)")
	}
	wp := &WarmPool{
		Provider:           prov,
		DNS:                NewFakeDNS(),
		Runner:             runner,
		Health:             redGate,
		Registry:           NewFakeRegistry(),
		DeleteRetryBackoff: time.Millisecond,
	}

	r, w, _ := os.Pipe()
	origStderr := os.Stderr
	os.Stderr = w

	_, err := wp.ProvisionOneShot(context.Background(), acmeSpec())

	w.Close()
	os.Stderr = origStderr
	var buf strings.Builder
	io.Copy(&buf, r)
	logged := buf.String()

	if err == nil {
		t.Fatal("ProvisionOneShot: want the (health) provision error, got nil")
	}
	// EDGE 1: Delete is retried the full budget before the cleanup is declared failed.
	if prov.deleteCalls != deleteRetries+1 {
		t.Errorf("cleanup did not retry the server Delete: deleteCalls=%d, want %d", prov.deleteCalls, deleteRetries+1)
	}
	if !strings.Contains(logged, "ORPHAN") || !strings.Contains(logged, "WARNING") {
		t.Errorf("a failed cleanup was not logged to stderr; captured:\n%s", logged)
	}
}

// TestDeprovisionByIP_DeletesMatchedBoxAndDNS proves the user-initiated Remove
// resolves the box by its IP AND its barkpark-fqdn identity label (the control
// plane never stored the random create name), deletes ONLY that box, and tears
// its DNS A record down — leaving the other managed box untouched.
func TestDeprovisionByIP_DeletesMatchedBoxAndDNS(t *testing.T) {
	ctx := context.Background()
	prov := NewFakeProvider()

	// Two managed boxes. Create stamps managed=true and assigns deterministic IPs
	// (10.0.0.1, 10.0.0.2). ProvisionOneShot stamps each box's FQDN identity label
	// at create; mirror that here so the deprovision can confirm box identity.
	keep, _ := prov.Create(ctx, ServerSpec{Name: "keep-box"})
	target, _ := prov.Create(ctx, ServerSpec{Name: "target-box"})
	_ = prov.LabelServer(ctx, "keep-box", FQDNLabelKey, "keep.barkpark.cloud")
	_ = prov.LabelServer(ctx, "target-box", FQDNLabelKey, "target.barkpark.cloud")

	dns := NewFakeDNS()
	_ = dns.UpsertRecord(ctx, Record{Zone: "barkpark.cloud", Name: "target", Type: "A", Value: target.IP})

	wp := &WarmPool{Provider: prov, DNS: dns}
	if err := wp.DeprovisionByIP(ctx, target.IP, "target", "barkpark.cloud"); err != nil {
		t.Fatalf("DeprovisionByIP: %v", err)
	}

	remaining, _ := prov.List(ctx)
	names := map[string]bool{}
	for _, s := range remaining {
		names[s.Name] = true
	}
	if names["target-box"] {
		t.Errorf("the targeted box %q survived the deprovision", target.Name)
	}
	if !names["keep-box"] {
		t.Errorf("the other managed box %q was deleted — deprovision hit the wrong box!", keep.Name)
	}
	if len(remaining) != 1 {
		t.Errorf("after deprovision %d boxes remain, want 1 (the keep box)", len(remaining))
	}
	if vals, _ := dns.Resolve(ctx, "target.barkpark.cloud"); len(vals) != 0 {
		t.Errorf("target DNS record survived the deprovision: %v", vals)
	}
}

// TestDeprovisionByIP_NoMatchIsIdempotentNoop proves a deprovision whose IP
// matches no managed box is NOT an error — the box is already gone — and still
// deletes the DNS record (idempotent), so a retried Remove converges cleanly.
func TestDeprovisionByIP_NoMatchIsIdempotentNoop(t *testing.T) {
	ctx := context.Background()
	prov := NewFakeProvider()
	keep, _ := prov.Create(ctx, ServerSpec{Name: "keep-box"})

	dns := NewFakeDNS()
	_ = dns.UpsertRecord(ctx, Record{Zone: "barkpark.cloud", Name: "gone", Type: "A", Value: "203.0.113.99"})

	wp := &WarmPool{Provider: prov, DNS: dns}
	// 203.0.113.99 matches no managed box (Create assigns 10.0.0.x).
	if err := wp.DeprovisionByIP(ctx, "203.0.113.99", "gone", "barkpark.cloud"); err != nil {
		t.Fatalf("DeprovisionByIP no-match returned error, want nil (idempotent): %v", err)
	}

	remaining, _ := prov.List(ctx)
	if len(remaining) != 1 || remaining[0].Name != keep.Name {
		t.Errorf("a no-match deprovision disturbed the fleet; remaining=%+v", remaining)
	}
	// DNS is still cleaned up even with no box match.
	if vals, _ := dns.Resolve(ctx, "gone.barkpark.cloud"); len(vals) != 0 {
		t.Errorf("DNS record survived an idempotent deprovision: %v", vals)
	}
}

// TestDeprovisionByIP_IPReuseMatchesByFQDNLabel is the money-safety guard against
// IP reuse: two managed boxes pathologically share the SAME public IP (simulating
// Hetzner reassigning a freed IP to a DIFFERENT customer's box before a stale
// deprovision job is re-claimed). Only the box whose barkpark-fqdn label matches
// the job's FQDN must be deleted — matching on IP alone would delete the wrong
// tenant's live box.
func TestDeprovisionByIP_IPReuseMatchesByFQDNLabel(t *testing.T) {
	ctx := context.Background()
	prov := NewFakeProvider()

	// Box for the instance we ARE removing (acme-1) and a DIFFERENT instance's box
	// (other-2) that has since been assigned the same IP.
	mine, _ := prov.Create(ctx, ServerSpec{Name: "mine-box"})
	other, _ := prov.Create(ctx, ServerSpec{Name: "other-box"})
	_ = prov.LabelServer(ctx, "mine-box", FQDNLabelKey, "acme-1.barkpark.cloud")
	_ = prov.LabelServer(ctx, "other-box", FQDNLabelKey, "other-2.barkpark.cloud")

	// Force IP reuse: both boxes now carry the SAME IP.
	reusedIP := mine.IP
	forceFakeServerIP(prov, "other-box", reusedIP)
	_ = other

	wp := &WarmPool{Provider: prov, DNS: NewFakeDNS()}
	// Remove the acme-1 instance. Its box and other-2's box share an IP, but only
	// acme-1's FQDN identity matches → only mine-box dies.
	if err := wp.DeprovisionByIP(ctx, reusedIP, "acme-1", "barkpark.cloud"); err != nil {
		t.Fatalf("DeprovisionByIP: %v", err)
	}

	remaining, _ := prov.List(ctx)
	if len(remaining) != 1 || remaining[0].Name != "other-box" {
		t.Errorf("IP-reuse deprovision deleted the wrong box; remaining=%+v, want only other-box", remaining)
	}
}

// forceFakeServerIP rewrites the recorded IP of a fake server in place — the only
// way to simulate Hetzner reassigning a freed IP to a different box (Create
// otherwise hands out deterministic, never-colliding IPs).
func forceFakeServerIP(prov *FakeProvider, name, ip string) {
	prov.mu.Lock()
	defer prov.mu.Unlock()
	s := prov.servers[name]
	s.IP = ip
	prov.servers[name] = s
}
