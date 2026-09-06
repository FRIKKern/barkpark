package cloud

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/deploy"
	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// recordingRunner records every CaddyStep it is handed instead of shelling out —
// the fake step-runner seam, mirroring caddy_test.go's fakeStepRunner. It never
// touches a box and never issues an ACME cert. It ALSO implements the
// hostCommandRunner capture capability the dwb-17 freshen step type-asserts:
// RunOutput scripts the cheap-check / rebuild responses so a test can drive the
// current / behind / rebuild-fail paths.
type recordingRunner struct {
	titles []string
	cmds   []string
	argvs  [][]string

	// events is the UNIFIED ordering record across BOTH Run (CaddySteps) and
	// RunOutput (freshen scripts), so a test can assert the freshen check ran
	// BEFORE the migrate step. Run appends "run:<title>"; RunOutput appends
	// "out:freshen-check" / "out:freshen-rebuild".
	events []string

	// freshen (dwb-17) RunOutput controls. Default (zero value) → the box is CURRENT
	// (HEAD == origin/main), so freshen is a no-op and existing chain tests are
	// undisturbed. Set `behind` to drive the rebuild path; `checkErr` / `rebuildErr`
	// to drive the degrade paths.
	outScripts []string // every RunOutput script, in order
	rebuildRan bool     // the rebuild script actually ran
	behind     bool     // cheap check reports HEAD != origin/main → a rebuild is due
	checkErr   error    // cheap check errors (unreachable fetch)
	rebuildErr error    // rebuild errors / times out
	diffOut    string   // scripted `git diff --name-only` output (path-aware skip)
	diffErr    error    // diff script errors
	ffRan      bool     // the bare fast-forward script actually ran
	ffErr      error    // fast-forward errors (diverged snapshot)

	// stepErr scripts a Run failure BY STEP TITLE, so a test can drive one
	// non-fatal step's degrade path without reaching for a red health gate. Zero
	// value (nil) → every step succeeds, so existing chain tests are undisturbed.
	stepErr map[string]error
}

func (r *recordingRunner) Run(_ context.Context, s CaddyStep) error {
	r.titles = append(r.titles, s.Title)
	r.cmds = append(r.cmds, s.Cmd)
	r.argvs = append(r.argvs, s.Argv)
	r.events = append(r.events, "run:"+s.Title)
	return r.stepErr[s.Title]
}

// RunOutput implements the freshen capture capability. It scripts the cheap-check
// KEY=VALUE output (current by default, behind when r.behind) and the rebuild.
func (r *recordingRunner) RunOutput(_ context.Context, script string) (string, error) {
	r.outScripts = append(r.outScripts, script)
	if strings.Contains(script, "apply-update.sh") {
		r.rebuildRan = true
		r.events = append(r.events, "out:freshen-rebuild")
		if r.rebuildErr != nil {
			return "rebuild failed on box", r.rebuildErr
		}
		return "rebuilt", nil
	}
	if strings.Contains(script, "diff --name-only") {
		r.events = append(r.events, "out:freshen-diff")
		return r.diffOut, r.diffErr
	}
	if strings.Contains(script, "merge --ff-only") {
		// The bare fast-forward (freshenFFScript) — the rebuild script's ff line
		// never reaches here because the deploy-rebuild.sh branch matched above.
		r.ffRan = true
		r.events = append(r.events, "out:freshen-ff")
		return "", r.ffErr
	}
	r.events = append(r.events, "out:freshen-check")
	if r.checkErr != nil {
		return "fatal: unable to access origin", r.checkErr
	}
	head, remote := "abc123", "abc123"
	if r.behind {
		head, remote = "aaa111", "bbb222"
	}
	return fmt.Sprintf("FRESHEN_HEAD=%s\nFRESHEN_REMOTE=%s\nFRESHEN_FROM=v0.42\nFRESHEN_TO=v0.45\n", head, remote), nil
}

// eventIndex returns the first index in events whose entry contains sub, or -1.
func (r *recordingRunner) eventIndex(sub string) int {
	for i, e := range r.events {
		if strings.Contains(e, sub) {
			return i
		}
	}
	return -1
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
		// Poll the health gate fast so the bounded poll (F2) runs without real
		// sleeps — a red gate fails closed in ~30ms instead of the ~4m default.
		HealthPollInterval: time.Millisecond,
		HealthPollDeadline: 30 * time.Millisecond,
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
		"BARKPARK_KEK=kekSECRETvalue0000\n" +
		"BARKPARK_KEK_PREVIOUS=oldKEKvalue1111\n" +
		"BARKPARK_CLOAK_KEY=abc123xyz\n" +
		"SECRET_KEY_BASE=deadBEEF0123456789\n" +
		"PREVIEW_JWT_SECRET=jwt-shhh\n" +
		"DATABASE_URL=ecto://u:p@h:5432/d\n" +
		"postgres://admin:s3cr3t@10.0.0.1/app also here"
	out := scrubEnvSecrets(in)

	// No raw secret VALUE survives.
	for _, leaked := range []string{"kekSECRETvalue0000", "oldKEKvalue1111", "hunter2", "abc123xyz", "deadBEEF0123456789", "jwt-shhh", "s3cr3t", "u:p@h"} {
		if strings.Contains(out, leaked) {
			t.Errorf("scrubEnvSecrets leaked %q; got:\n%s", leaked, out)
		}
	}
	// The KEY names / schemes are kept so the failure is still diagnosable.
	for _, kept := range []string{"BARKPARK_KEK=[REDACTED]", "BARKPARK_KEK_PREVIOUS=[REDACTED]", "BARKPARK_CLOAK_KEY=[REDACTED]", "SECRET_KEY_BASE=[REDACTED]", "PREVIEW_JWT_SECRET=[REDACTED]", "DATABASE_URL=[REDACTED]", "ecto://[REDACTED]@", "postgres://[REDACTED]@"} {
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
		// Bounded health poll fast so the red gate fails closed promptly (F2).
		HealthPollInterval: time.Millisecond,
		HealthPollDeadline: 30 * time.Millisecond,
	}

	r, w, _ := os.Pipe()
	origStderr := os.Stderr
	os.Stderr = w
	// Drain concurrently: a darwin pipe buffers only 512 bytes (64 KiB on Linux),
	// so reading only after the call returns deadlocks once the code under test
	// writes more warning text than the buffer holds.
	stderrCh := make(chan string, 1)
	go func() { var b strings.Builder; io.Copy(&b, r); stderrCh <- b.String() }()

	_, err := wp.ProvisionOneShot(context.Background(), acmeSpec())

	w.Close()
	os.Stderr = origStderr
	logged := <-stderrCh

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

// TestDeprovisionByIP_MismatchedLabelFailsLoud is the fail-closed guard: a managed
// box occupies the target IP, but its barkpark-fqdn identity label does NOT match
// the job's FQDN (a legacy box predating the label, or a recycled IP now held by a
// different tenant's box). The old behaviour silently no-op'd the server delete and
// proceeded to delete the DNS record — which would strand a billed box AND let the
// control plane delete the registry row. DeprovisionByIP must now FAIL LOUDLY: it
// neither deletes the box nor reaches the DNS delete.
func TestDeprovisionByIP_MismatchedLabelFailsLoud(t *testing.T) {
	cases := []struct {
		name      string
		fqdnLabel string // "" → no barkpark-fqdn label at all
	}{
		{name: "different label", fqdnLabel: "other-9.barkpark.cloud"},
		{name: "missing label", fqdnLabel: ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			prov := NewFakeProvider()

			box, _ := prov.Create(ctx, ServerSpec{Name: "occupant-box"})
			if tc.fqdnLabel != "" {
				_ = prov.LabelServer(ctx, "occupant-box", FQDNLabelKey, tc.fqdnLabel)
			}

			dns := NewFakeDNS()
			_ = dns.UpsertRecord(ctx, Record{Zone: "barkpark.cloud", Name: "acme-1", Type: "A", Value: box.IP})

			wp := &WarmPool{Provider: prov, DNS: dns}
			// Remove acme-1: a box sits on this IP but its identity does not match.
			err := wp.DeprovisionByIP(ctx, box.IP, "acme-1", "barkpark.cloud")
			if err == nil {
				t.Fatalf("DeprovisionByIP on an IP/label mismatch returned nil, want a loud error")
			}

			// The occupant box must NOT have been deleted.
			remaining, _ := prov.List(ctx)
			if len(remaining) != 1 || remaining[0].Name != "occupant-box" {
				t.Errorf("the mismatched box was deleted; remaining=%+v, want only occupant-box", remaining)
			}
			// The DNS delete must NOT have been reached.
			if vals, _ := dns.Resolve(ctx, "acme-1.barkpark.cloud"); len(vals) == 0 {
				t.Errorf("the DNS record was deleted; the deprovision should fail before the DNS delete")
			}
		})
	}
}

// ─── F2: bounded health-gate poll ────────────────────────────────────────────

// flakyGate returns a HealthChecker that FAILS its first failFirst probes (as a
// cold provision does — DNS not propagated, ACME cert not issued yet → a
// connection/TLS error + a non-OK report) then passes, plus a pointer to the call
// counter so a test asserts how many probes ran. Closures capture `calls` by
// reference, so the returned *int observes every increment.
func flakyGate(failFirst int, base string) (HealthChecker, *int) {
	calls := 0
	gate := func(_ context.Context, _, _ string) (setup.HealthReport, error) {
		calls++
		if calls <= failFirst {
			// Model the cold-window failure: a non-OK report AND a transport error
			// (the https://<fqdn> dial fails / TLS not ready). pollHealth must treat
			// this as not-ready-yet and keep polling, not fail closed.
			return setup.HealthReport{
					BaseURL: base,
					OK:      false,
					Checks:  []setup.CheckResult{{Name: "tls", Pass: false, Detail: "dial tcp: connection refused (fake cold provision)"}},
				},
				fmt.Errorf("probe %s: dial tcp: connect: connection refused (fake)", base)
		}
		return setup.HealthReport{BaseURL: base, OK: true, Checks: passingChecks("capabilities", "tls")}, nil
	}
	return gate, &calls
}

// TestPollHealth_RetriesThenSucceeds asserts the bounded poll (F2) rides out the
// cold-provision window: a gate that fails 3 times then passes is retried (fast
// injected interval) and pollHealth returns the green report — exactly 4 probes.
func TestPollHealth_RetriesThenSucceeds(t *testing.T) {
	gate, calls := flakyGate(3, "https://acme.barkpark.cloud")
	wp := &WarmPool{
		Health:             gate,
		HealthPollInterval: time.Millisecond, // injected fast timing — no real sleeps
		HealthPollDeadline: 5 * time.Second,  // generous: success happens in ~3ms
	}

	report, err := wp.pollHealth(context.Background(), "https://acme.barkpark.cloud", "tok")
	if err != nil {
		t.Fatalf("pollHealth: want success after the cold window, got error: %v", err)
	}
	if !report.OK {
		t.Fatalf("pollHealth returned a non-OK report: %+v", report)
	}
	if *calls != 4 {
		t.Errorf("Health probed %d times, want 4 (3 cold failures + 1 success)", *calls)
	}
}

// TestPollHealth_FailsClosedAfterDeadline asserts the poll is BOUNDED: a gate that
// never passes makes pollHealth fail closed once the deadline elapses (not loop
// forever), and it RETRIED more than once before giving up.
func TestPollHealth_FailsClosedAfterDeadline(t *testing.T) {
	gate, calls := flakyGate(1_000_000, "https://acme.barkpark.cloud") // never passes
	wp := &WarmPool{
		Health:             gate,
		HealthPollInterval: time.Millisecond,
		HealthPollDeadline: 25 * time.Millisecond,
	}

	start := time.Now()
	_, err := wp.pollHealth(context.Background(), "https://acme.barkpark.cloud", "tok")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("pollHealth: want a fail-closed error after the deadline, got nil")
	}
	// Bounded: it stopped near the deadline rather than hanging.
	if elapsed > 2*time.Second {
		t.Errorf("pollHealth took %s — not bounded by the deadline (expected ~25ms)", elapsed)
	}
	// Retried: it didn't give up after a single shot (the whole point of the poll).
	if *calls < 2 {
		t.Errorf("Health probed %d times, want >=2 (the poll must retry before the deadline)", *calls)
	}
}

// TestPollHealth_RespectsContextCancel asserts ctx cancellation aborts the wait
// between probes promptly (so a cancelled job ctx doesn't block on the poll).
func TestPollHealth_RespectsContextCancel(t *testing.T) {
	gate, _ := flakyGate(1_000_000, "https://acme.barkpark.cloud")
	wp := &WarmPool{
		Health:             gate,
		HealthPollInterval: time.Hour, // would block forever between probes …
		HealthPollDeadline: time.Hour,
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // … but ctx is already cancelled, so the wait returns immediately

	done := make(chan error, 1)
	go func() { _, err := wp.pollHealth(ctx, "https://acme.barkpark.cloud", "tok"); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("pollHealth: want ctx.Err() on a cancelled context, got nil")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pollHealth did not honour ctx cancellation between probes")
	}
}

// TestProvision_HealthPollToleratesColdWindow is the F2 end-to-end: a cold gate
// that fails twice then passes does NOT tear the box down — the chain rides out
// the DNS/ACME warm-up and registers the server once the gate goes green.
func TestProvision_HealthPollToleratesColdWindow(t *testing.T) {
	spec := acmeSpec()
	gate, calls := flakyGate(2, spec.healthTarget())
	wp, _, _, _, reg := newFakeWarmPool(t, gate)
	// newFakeWarmPool already injects fast timing; widen the deadline a touch so the
	// 2 failures + success comfortably fit even on a slow CI box.
	wp.HealthPollDeadline = 5 * time.Second

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision should ride out a cold DNS/ACME window and succeed, got: %v", err)
	}
	if *calls != 3 {
		t.Errorf("gate probed %d times, want 3 (2 cold failures + 1 success)", *calls)
	}
	if !reg.Has("acme.barkpark.cloud") {
		t.Error("server not registered after the gate eventually passed — the poll didn't ride out the cold window")
	}
}

// ─── dwb-20: per-instance secrets install (SKB + KEK + CLOAK + PREVIEW + RCH) ─

// knownFiveSecrets is a set of five DISTINCT, shell-safe fake secret values a test
// mints so it can assert each was installed independently (no shared value, no
// baked survivor). Each is alphabet-valid so validateSecrets passes.
func knownFiveSecrets() Secrets {
	return Secrets{
		SecretKeyBase:      "TESTskb-value_0123456789ABCDEFxyz0123456789abcdefghijklmnopqrstuvwx",
		Kek:                "TESTkek+base64/value000000000000000000000000=",
		CloakKey:           "TESTcloak+base64/value1111111111111111111111=",
		PreviewJWTSecret:   "TESTpreview+base64/value22222222222222222222=",
		ReleaseCaptureHMAC: "TESTrch+base64/value333333333333333333333333=",
		AdminToken:         "bp_admin_TESTtoken0123456789ABCDEF",
	}
}

// TestSecretsInstallStep_ShapeAndRedaction asserts the secrets-install step writes
// the .env idempotently for ALL five keys + restarts Barkpark ONCE, carries each
// value ONLY via its BP_* env (never in Title/Cmd), and lists all five for output
// TestProvision_SingleAppRestart pins the single-restart contract end-to-end:
// across the WHOLE go-live chain (Caddy/TLS steps + secrets-install + migrate +
// admin-token) the app is restarted exactly ONCE — by secrets-install, which
// runs after the PHX_HOST/PHX_SCHEME env writes, so the one boot picks up both.
// A second restart (the pre-#1157-era Caddy-step restart) doubles the configure
// wall-clock for nothing; this test reds if it ever creeps back.
func TestProvision_SingleAppRestart(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, _ := newFakeWarmPool(t, greenGate(spec.healthTarget()))

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	restarts := 0
	for _, argv := range runner.argvs {
		for _, a := range argv {
			restarts += strings.Count(a, "systemctl restart barkpark")
		}
	}
	if restarts != 1 {
		t.Errorf("the go-live chain must restart barkpark exactly once (secrets-install), got %d; cmds:\n%s",
			restarts, strings.Join(runner.cmds, "\n"))
	}
	// The Caddy install probe is baked-image aware: it must short-circuit on an
	// existing caddy instead of unconditionally paying the apt round.
	found := false
	for _, c := range runner.cmds {
		if strings.Contains(c, "command -v caddy") {
			found = true
		}
	}
	if !found {
		t.Errorf("no caddy-presence probe in the chain's commands; the baked image pays a full apt round every go-live")
	}
}

// redaction.
func TestSecretsInstallStep_ShapeAndRedaction(t *testing.T) {
	sec := knownFiveSecrets()
	s := secretsInstallStep(sec, MailRelay{})

	if len(s.Argv) != 3 || s.Argv[0] != "bash" || s.Argv[1] != "-lc" {
		t.Fatalf("secretsInstallStep argv = %v, want [bash -lc <script>]", s.Argv)
	}
	script := s.Argv[2]
	for _, want := range []string{
		"export BP_SKB='" + sec.SecretKeyBase + "'", // each secret rides in via its own env
		"export BP_KEK='" + sec.Kek + "'",
		"export BP_CLOAK='" + sec.CloakKey + "'",
		"export BP_PREVIEW='" + sec.PreviewJWTSecret + "'",
		"export BP_RCH='" + sec.ReleaseCaptureHMAC + "'",
		// one grep -v strips any existing line for ALL five keys (idempotent)
		"grep -v -e '^SECRET_KEY_BASE=' -e '^BARKPARK_KEK=' -e '^BARKPARK_CLOAK_KEY=' -e '^PREVIEW_JWT_SECRET=' -e '^BARKPARK_RELEASE_CAPTURE_HMAC_SECRET='",
		`printf 'SECRET_KEY_BASE=%s\n' "$BP_SKB"`, // append each minted value from env
		`printf 'BARKPARK_KEK=%s\n' "$BP_KEK"`,
		`printf 'BARKPARK_CLOAK_KEY=%s\n' "$BP_CLOAK"`,
		`printf 'PREVIEW_JWT_SECRET=%s\n' "$BP_PREVIEW"`,
		`printf 'BARKPARK_RELEASE_CAPTURE_HMAC_SECRET=%s\n' "$BP_RCH"`,
		"systemctl restart barkpark", // restart so Phoenix re-reads them
	} {
		if !strings.Contains(script, want) {
			t.Errorf("secrets step script missing %q; script:\n%s", want, script)
		}
	}
	// Exactly ONE restart — a single restart after all env writes.
	if got := strings.Count(script, "systemctl restart barkpark"); got != 1 {
		t.Errorf("secrets step should restart Barkpark exactly once, got %d; script:\n%s", got, script)
	}
	// The narration (Title/Cmd, which may be logged) must NEVER carry any value.
	for _, v := range []string{sec.SecretKeyBase, sec.Kek, sec.CloakKey, sec.PreviewJWTSecret, sec.ReleaseCaptureHMAC} {
		if strings.Contains(s.Title, v) || strings.Contains(s.Cmd, v) {
			t.Errorf("a secret value leaked into Title/Cmd: title=%q cmd=%q", s.Title, s.Cmd)
		}
	}
	// All five values are listed for redaction of any captured failure output.
	for _, v := range []string{sec.SecretKeyBase, sec.Kek, sec.CloakKey, sec.PreviewJWTSecret, sec.ReleaseCaptureHMAC} {
		found := false
		for _, r := range s.Redact {
			if r == v {
				found = true
			}
		}
		if !found {
			t.Errorf("secrets step Redact does not list value %q: %v", v, s.Redact)
		}
	}
}

// TestSecretsInstallStep_MailRelayInjection proves the shared mail relay is
// written into the instance .env when enabled (so magic-link / reset / verify
// actually deliver), with the SASL password treated exactly like the other
// secrets: via $BP_SMTP_PASS in the Argv, never in Title/Cmd, and listed for
// redaction. Host/port/username (non-secret) appear as plain printf values.
func TestSecretsInstallStep_MailRelayInjection(t *testing.T) {
	sec := knownFiveSecrets()
	mail := MailRelay{
		Host:     "mail.barkpark.cloud",
		Username: "barkpark-cloud",
		Password: "eQorzMDR7Ki8DoKxSu3owEZdvoa0lkMP",
		// Port omitted → defaults to 587.
	}
	s := secretsInstallStep(sec, mail)
	script := s.Argv[2]

	for _, want := range []string{
		"export BP_SMTP_PASS='" + mail.Password + "'", // password rides via its own env
		// the strip list grew to cover the SMTP keys (idempotent re-run)
		"-e '^SMTP_HOST=' -e '^SMTP_PORT=' -e '^SMTP_USERNAME=' -e '^SMTP_PASSWORD=' -e '^SMTP_VERIFY_PEER='",
		`printf 'SMTP_HOST=%s\n' 'mail.barkpark.cloud'`,
		`printf 'SMTP_PORT=%s\n' '587'`, // default applied
		`printf 'SMTP_USERNAME=%s\n' 'barkpark-cloud'`,
		`printf 'SMTP_PASSWORD=%s\n' "$BP_SMTP_PASS"`, // secret from env, not script text
		`printf 'SMTP_VERIFY_PEER=%s\n' 'true'`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("mail-enabled step missing %q; script:\n%s", want, script)
		}
	}
	// Still exactly one restart.
	if got := strings.Count(script, "systemctl restart barkpark"); got != 1 {
		t.Errorf("want exactly one restart, got %d", got)
	}
	// The password must never surface in the narrated Title/Cmd.
	if strings.Contains(s.Title, mail.Password) || strings.Contains(s.Cmd, mail.Password) {
		t.Errorf("mail password leaked into Title/Cmd: title=%q cmd=%q", s.Title, s.Cmd)
	}
	// The password is listed for redaction of captured failure output.
	found := false
	for _, r := range s.Redact {
		if r == mail.Password {
			found = true
		}
	}
	if !found {
		t.Errorf("mail password not listed in Redact: %v", s.Redact)
	}
}

// TestSecretsInstallStep_NoMailWhenDisabled is the no-regression guarantee: a
// zero MailRelay injects NO SMTP lines, so an instance provisioned by a worker
// without SMTP_RELAY_* is byte-identical to the pre-mail behavior.
func TestSecretsInstallStep_NoMailWhenDisabled(t *testing.T) {
	script := secretsInstallStep(knownFiveSecrets(), MailRelay{}).Argv[2]
	for _, forbidden := range []string{"SMTP_HOST=", "SMTP_PASSWORD=", "BP_SMTP_PASS"} {
		if strings.Contains(script, forbidden) {
			t.Errorf("disabled mail relay still emitted %q; script:\n%s", forbidden, script)
		}
	}
}

// TestMailRelay_Validate covers the shape guard: a fully-empty relay is valid
// (mail simply off), a fully-specified safe relay is enabled, and partial or
// shell-unsafe values are rejected with a specific error.
func TestMailRelay_Validate(t *testing.T) {
	good := MailRelay{Host: "mail.barkpark.cloud", Username: "barkpark-cloud", Password: "aBc123+/=-_"}
	cases := []struct {
		name    string
		m       MailRelay
		wantErr bool
		enabled bool
	}{
		{"empty is valid+off", MailRelay{}, false, false},
		{"full is valid+enabled", good, false, true},
		{"partial (no password)", MailRelay{Host: "mail.barkpark.cloud", Username: "u"}, true, false},
		{"host with quote", MailRelay{Host: "m'x", Username: "u", Password: "p"}, true, false},
		{"password with space", MailRelay{Host: "mail.barkpark.cloud", Username: "u", Password: "a b"}, true, false},
		{"non-numeric port", MailRelay{Host: "mail.barkpark.cloud", Port: "5x7", Username: "u", Password: "p"}, true, false},
		{"email username ok", MailRelay{Host: "mail.barkpark.cloud", Username: "postmaster@barkpark.cloud", Password: "p"}, false, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.m.Validate()
			if (err != nil) != tc.wantErr {
				t.Fatalf("Validate() err = %v, wantErr = %v", err, tc.wantErr)
			}
			if got := tc.m.Enabled(); got != tc.enabled {
				t.Errorf("Enabled() = %v, want %v", got, tc.enabled)
			}
		})
	}
}

// TestSecretsInstallStep_RedactsKEKOnFailure proves a failing secrets-install step
// whose captured SSH output echoes the BARKPARK_KEK has it scrubbed from the
// wrapped error — the acceptance criterion that the KEK value can never reach
// logs/errors. It covers both the literal-Redact path and the shape-based env
// scrubber (BARKPARK_KEK=<run>).
func TestSecretsInstallStep_RedactsKEKOnFailure(t *testing.T) {
	sec := knownFiveSecrets()
	r := &SSHStepRunner{
		Host: "198.51.100.9",
		Key:  "/dev/null",
		Exec: func(_ context.Context, _ string, _ ...string) (string, error) {
			// The box echoes the secrets back on failure — none may reach the error,
			// both as a bare value (literal Redact) and as an env assignment (shape).
			return "restart failed; BARKPARK_KEK=" + sec.Kek + " leftover " + sec.Kek +
				"\nBARKPARK_CLOAK_KEY=" + sec.CloakKey, fmt.Errorf("exit status 1")
		},
	}
	err := r.Run(context.Background(), secretsInstallStep(sec, MailRelay{}))
	if err == nil {
		t.Fatal("SSHStepRunner.Run: want an error for the failed secrets step, got nil")
	}
	for _, v := range []string{sec.Kek, sec.CloakKey, sec.SecretKeyBase, sec.PreviewJWTSecret, sec.ReleaseCaptureHMAC} {
		if strings.Contains(err.Error(), v) {
			t.Errorf("secrets-step failure leaked a secret value; got:\n%s", err.Error())
		}
	}
	if !strings.Contains(err.Error(), "[REDACTED]") {
		t.Errorf("secrets-step failure was not scrubbed (no [REDACTED] marker); got:\n%s", err.Error())
	}
}

// TestValidateSecretKeyBase asserts the alphabet guard accepts a real minted
// secret (base64/base64url) and rejects an empty or shell-unsafe value.
func TestValidateSecretKeyBase(t *testing.T) {
	if err := validateSecretKeyBase(""); err == nil {
		t.Error("empty secret should be rejected")
	}
	pad := strings.Repeat("x", 64)
	for _, ok := range []string{"ok_base64url-Value" + pad, "with+slash/and=padding" + pad, pad} {
		if err := validateSecretKeyBase(ok); err != nil {
			t.Errorf("safe long secret should pass: %v", err)
		}
	}
	for _, bad := range []string{"has space" + pad, "has'quote" + pad, "has;semi" + pad, "has$var" + pad, "back`tick" + pad} {
		if err := validateSecretKeyBase(bad); err == nil {
			t.Errorf("unsafe secret %q should be rejected", bad)
		}
	}
	// Phoenix floor: Plug.Session's cookie store raises below 64 bytes. A short
	// draw once shipped as a 32-byte key that 500'd Studio/login on every fresh
	// instance — the validator must fail the provision chain closed instead.
	for _, short := range []string{"abc", strings.Repeat("y", 32), strings.Repeat("y", 63)} {
		if err := validateSecretKeyBase(short); err == nil {
			t.Errorf("%d-byte secret must be rejected (Phoenix needs >=64)", len(short))
		}
	}
	if err := validateSecretKeyBase(strings.Repeat("y", 64)); err != nil {
		t.Errorf("exactly 64 bytes should pass: %v", err)
	}
}

// TestValidateSecrets asserts the whole-set guard rejects when ANY of the five
// values is empty or shell-unsafe (and the release-capture HMAC additionally
// when it is under runtime.exs's 32-byte floor), and passes on a clean set.
func TestValidateSecrets(t *testing.T) {
	if err := validateSecrets(knownFiveSecrets()); err != nil {
		t.Errorf("a clean five-secret set should pass: %v", err)
	}
	for _, mut := range []func(s *Secrets){
		func(s *Secrets) { s.SecretKeyBase = "" },
		func(s *Secrets) { s.Kek = "" },
		func(s *Secrets) { s.CloakKey = "bad value" },
		func(s *Secrets) { s.PreviewJWTSecret = "has'quote" },
		func(s *Secrets) { s.ReleaseCaptureHMAC = "" },
		func(s *Secrets) { s.ReleaseCaptureHMAC = "short31bytes0000000000000000000" }, // runtime.exs needs >=32
	} {
		sec := knownFiveSecrets()
		mut(&sec)
		if err := validateSecrets(sec); err == nil {
			t.Errorf("validateSecrets should reject a malformed set: %+v", sec)
		}
	}
}

// ── charter Decision 33: the monitoring beat ──────────────────────────────

// agentSpec is acmeSpec ARMED with the per-instance agent token + control URL the
// control plane threads at claim time (Decision 33), so the configure step runs
// agentInstallStep. The token is a base64url-shaped value (what the CP mints).
func agentSpec() GoLiveSpec {
	s := acmeSpec()
	s.AgentToken = "agent-report-tok_AbC123"
	s.ControlURL = "https://api.barkpark.cloud"
	return s
}

// TestAgentInstallStep_ShapeAndRedaction pins the EXACT on-box writes + commands
// the configure step issues to light up the beat: build the binary, write the
// 0600 token file (value via $BP_AGENT_TOK, never the script text/Cmd), write
// agent.env with both URLs, install the committed unit, enable the service. The
// token is redacted and never leaks into the narrated Title/Cmd.
func TestAgentInstallStep_ShapeAndRedaction(t *testing.T) {
	const tok = "agent-report-tok_AbC123"
	s := agentInstallStep(tok, "https://api.barkpark.cloud", "https://acme.barkpark.cloud", "")

	if len(s.Argv) != 3 || s.Argv[0] != "bash" || s.Argv[1] != "-lc" {
		t.Fatalf("agentInstallStep argv = %v, want [bash -lc <script>]", s.Argv)
	}
	script := s.Argv[2]
	for _, want := range []string{
		"export BP_AGENT_TOK='" + tok + "'",                              // token rides in via env
		"go build -o /usr/local/bin/barkpark-agent ./cmd/barkpark-agent", // binary built on-box
		`printf '%s' "$BP_AGENT_TOK" > /etc/barkpark/agent.token`,        // token written from env, never the literal
		"chmod 600 /etc/barkpark/agent.token",                            // root-only token file
		`printf 'BARKPARK_CONTROL_URL=%s\nBARKPARK_HEALTH_URL=%s\n' 'https://api.barkpark.cloud' 'https://acme.barkpark.cloud' > /etc/barkpark/agent.env`, // URLs to env file
		"install -m 0644 /opt/barkpark/deploy/systemd/barkpark-agent.service /etc/systemd/system/barkpark-agent.service",                                  // committed unit installed
		"systemctl daemon-reload",
		"systemctl enable --now barkpark-agent", // enabled + started
	} {
		if !strings.Contains(script, want) {
			t.Errorf("agent step script missing %q; script:\n%s", want, script)
		}
	}
	// The token must NEVER appear literally after its single-quoted env assignment
	// (i.e. it is not printf'd into the script text) and never in the narration.
	if strings.Contains(s.Title, tok) || strings.Contains(s.Cmd, tok) {
		t.Errorf("agent token leaked into Title/Cmd: title=%q cmd=%q", s.Title, s.Cmd)
	}
	found := false
	for _, r := range s.Redact {
		if r == tok {
			found = true
		}
	}
	if !found {
		t.Errorf("agent step Redact does not list the token: %v", s.Redact)
	}
}

// TestAgentInstallStep_WritesTheHealthTokenFile pins the SOURCE-CONTROLLED half
// of the health-token fix: when the go-live hands the step the box's admin
// bearer, the step writes it to /etc/barkpark/agent.health.token at 0600 — the
// exact file the committed unit's --health-token-file names. Before this, that
// file existed on exactly ONE box, put there by a hand-added systemd drop-in, so
// every other box reported req_per_s / p95_ms / err_5xx_per_s as -1 forever.
//
// The value rides in via $BP_AGENT_HEALTH_TOK and is redacted, like the report
// token beside it: it must never land in the narrated Title/Cmd.
func TestAgentInstallStep_WritesTheHealthTokenFile(t *testing.T) {
	const (
		tok       = "agent-report-tok_AbC123"
		healthTok = "bp_admin_HealthBearer456"
	)
	s := agentInstallStep(tok, "https://api.barkpark.cloud", "https://acme.barkpark.cloud", healthTok)
	script := s.Argv[2]
	for _, want := range []string{
		"export BP_AGENT_HEALTH_TOK='" + healthTok + "'",
		`printf '%s' "$BP_AGENT_HEALTH_TOK" > /etc/barkpark/agent.health.token`,
		"chmod 600 /etc/barkpark/agent.health.token",
	} {
		if !strings.Contains(script, want) {
			t.Errorf("agent step script missing %q; script:\n%s", want, script)
		}
	}
	// Written BEFORE the unit is installed + the service enabled, so the very
	// first beat of the restarted agent is already metered.
	if strings.Index(script, "agent.health.token") > strings.Index(script, "systemctl enable --now barkpark-agent") {
		t.Error("health token must be written before the service is enabled")
	}
	if strings.Contains(s.Title, healthTok) || strings.Contains(s.Cmd, healthTok) {
		t.Errorf("health token leaked into Title/Cmd: title=%q cmd=%q", s.Title, s.Cmd)
	}
	found := false
	for _, r := range s.Redact {
		if r == healthTok {
			found = true
		}
	}
	if !found {
		t.Errorf("agent step Redact does not list the health token: %v", s.Redact)
	}
}

// TestAgentInstallStep_NoHealthTokenWritesNoFile pins the tolerant half in both
// directions. An empty health token (a resurrect, which carries only the freshly
// minted REPORT token) must write no file and — critically — must not DELETE one:
// a box that was already metered stays metered across a restore, and a box that
// was not simply keeps the -1 sentinels it has always reported. An unsafe-shaped
// value is dropped rather than interpolated: telemetry may not inject a shell
// command, and may not fail a go-live either.
func TestAgentInstallStep_NoHealthTokenWritesNoFile(t *testing.T) {
	const tok = "agent-report-tok_AbC123"
	for _, c := range []struct{ name, healthTok string }{
		{"empty (resurrect / old control plane)", ""},
		{"blank", "   "},
		{"shell metacharacters", "tok'; rm -rf /; echo '"},
		{"a command substitution", "$(cat /opt/barkpark/.env)"},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := agentInstallStep(tok, "https://api.barkpark.cloud", "https://acme.barkpark.cloud", c.healthTok)
			script := s.Argv[2]
			if strings.Contains(script, "agent.health.token") {
				t.Errorf("script writes the health token file for %q; script:\n%s", c.healthTok, script)
			}
			if strings.Contains(script, "rm ") || strings.Contains(script, "unlink") {
				t.Errorf("script must never delete an existing health token file; script:\n%s", script)
			}
			if trimmed := strings.TrimSpace(c.healthTok); trimmed != "" && strings.Contains(script, trimmed) {
				t.Errorf("rejected health token was interpolated into the script:\n%s", script)
			}
			// The report token half is untouched by any of this.
			if !strings.Contains(script, `printf '%s' "$BP_AGENT_TOK" > /etc/barkpark/agent.token`) {
				t.Errorf("report token write regressed; script:\n%s", script)
			}
		})
	}
}

// TestAgentInstallStep_HealthTokenPathMatchesTheCommittedUnit is the cross-half
// tripwire on the provisioner side: the path the step WRITES must be the path the
// committed unit READS. Two files, one string — if they ever diverge the box goes
// silently unmetered, which is precisely the failure this row names.
func TestAgentInstallStep_HealthTokenPathMatchesTheCommittedUnit(t *testing.T) {
	b, err := os.ReadFile("../../../deploy/systemd/barkpark-agent.service")
	if err != nil {
		t.Fatalf("read committed unit: %v", err)
	}
	if !strings.Contains(string(b), "--health-token-file /etc/barkpark/agent.health.token") {
		t.Fatal("committed unit does not read /etc/barkpark/agent.health.token")
	}
	s := agentInstallStep("agent-report-tok_AbC123", "https://api.barkpark.cloud", "https://acme.barkpark.cloud", "bp_admin_HealthBearer456")
	if !strings.Contains(s.Argv[2], "> /etc/barkpark/agent.health.token") {
		t.Fatal("agentInstallStep does not write /etc/barkpark/agent.health.token")
	}
}

// TestValidateAgentURL accepts a real http(s) origin and rejects an empty or
// shell-unsafe URL (the guard before the URL is single-quoted into the script).
func TestValidateAgentURL(t *testing.T) {
	for _, ok := range []string{
		"https://api.barkpark.cloud",
		"http://10.0.0.1:4000",
		"https://acme.barkpark.cloud/health?probe=1&x=2",
	} {
		if err := validateAgentURL("control-url", ok); err != nil {
			t.Errorf("safe URL %q should pass: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "has space", "has'quote", "has;semi", "has$var", "back`tick"} {
		if err := validateAgentURL("control-url", bad); err == nil {
			t.Errorf("unsafe URL %q should be rejected", bad)
		}
	}
}

// TestProvision_InstallsAgentWhenClaimed proves the end-to-end wiring: a claim
// carrying an agent token + control URL makes the go-live chain build + enable
// barkpark-agent (the monitoring beat), and the box still registers green.
func TestProvision_InstallsAgentWhenClaimed(t *testing.T) {
	spec := agentSpec()
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	ctx := context.Background()

	if _, err := wp.Provision(ctx, spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	// The agent step ran through the injected runner.
	sawAgent := false
	for _, ti := range runner.titles {
		if ti == "install + enable the on-box monitoring agent" {
			sawAgent = true
		}
	}
	if !sawAgent {
		t.Errorf("agent install step did not run; titles:\n%s", strings.Join(runner.titles, "\n"))
	}
	// The exact writes/commands reached the box (asserted on the recorded Argv).
	all := runnerArgvJoined(runner)
	for _, want := range []string{
		"go build -o /usr/local/bin/barkpark-agent ./cmd/barkpark-agent",
		"> /etc/barkpark/agent.token",
		"systemctl enable --now barkpark-agent",
	} {
		if !strings.Contains(all, want) {
			t.Errorf("agent commands missing %q; ran:\n%s", want, all)
		}
	}
	// The box still went live (agent install is part of a green go-live).
	if !reg.Has("acme.barkpark.cloud") {
		t.Errorf("box not registered; registry=%+v", reg.Registered())
	}
}

// TestProvision_SkipsAgentWhenUnclaimed proves the additive contract: a claim
// WITHOUT an agent token/control URL (an old control plane) runs the chain
// byte-for-byte as before — no agent build/install commands, box still green.
func TestProvision_SkipsAgentWhenUnclaimed(t *testing.T) {
	spec := acmeSpec() // no AgentToken / ControlURL
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	ctx := context.Background()

	if _, err := wp.Provision(ctx, spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	all := runnerArgvJoined(runner)
	for _, forbidden := range []string{"barkpark-agent", "/etc/barkpark/agent.token"} {
		if strings.Contains(all, forbidden) {
			t.Errorf("agent commands ran for an unclaimed box (should skip); found %q in:\n%s", forbidden, all)
		}
	}
	if !reg.Has("acme.barkpark.cloud") {
		t.Errorf("box not registered; registry=%+v", reg.Registered())
	}
}

// ── jpf-w1-siteplane-chain: step 7c, the site plane ───────────────────

// sitePlaneStepTitle is the narrated Title of step 7c — the handle the chain
// tests use to prove the step ran (or did not) without matching on script text.
const sitePlaneStepTitle = "install the site-hosting plane (builder + runtime)"

// TestProvision_InstallsSitePlaneWhenClaimed proves the chain closes the gap the
// row names: a claim carrying an agent token + control URL makes the go-live chain
// ALSO install the site-hosting plane, so a freshly launched box can drain its OWN
// site-deploy queue instead of waiting for a human to aim the manual per-box
// cp-ops `site-runtime-install` workflow_dispatch at its IP.
func TestProvision_InstallsSitePlaneWhenClaimed(t *testing.T) {
	spec := agentSpec()
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	if !slices.Contains(runner.titles, sitePlaneStepTitle) {
		t.Errorf("site-plane step did not run; titles:\n%s", strings.Join(runner.titles, "\n"))
	}
	// The real on-box work reached the box (asserted on the recorded Argv, where the
	// script lives — not on Cmd, which is narration only).
	all := runnerArgvJoined(runner)
	for _, want := range []string{
		"$GO build -o /usr/local/bin/barkpark-builder ./cmd/barkpark-builder",
		"$GO build -o /usr/local/bin/barkpark-runtime ./cmd/barkpark-runtime",
		"systemctl enable --now barkpark-builder barkpark-runtime",
		// The plane authenticates with the box's OWN agent identity — the token FILE
		// step 7b wrote, never a second credential threaded through the spec.
		"--token-file /etc/barkpark/agent.token",
	} {
		if !strings.Contains(all, want) {
			t.Errorf("site-plane install missing %q; ran:\n%s", want, all)
		}
	}
	// Step 7c lands strictly BETWEEN 7b (agent) and the step-8 health poll, so the
	// verify gate — which runs after configureHost — can never probe ahead of it.
	agentAt := slices.Index(runner.titles, "install + enable the on-box monitoring agent")
	planeAt := slices.Index(runner.titles, sitePlaneStepTitle)
	if agentAt < 0 || planeAt < 0 || planeAt < agentAt {
		t.Errorf("site plane must run after the agent step: agent=%d plane=%d; titles:\n%s",
			agentAt, planeAt, strings.Join(runner.titles, "\n"))
	}
	if !reg.Has("acme.barkpark.cloud") {
		t.Errorf("box not registered; registry=%+v", reg.Registered())
	}
}

// TestProvision_SkipsSitePlaneWhenUnclaimed proves the additive contract: a claim
// from an old control plane (no agent token / control URL) runs the chain
// byte-for-byte as before — no site-plane commands at all, box still green. The
// plane shares 7b's gate because it reuses 7b's token file.
func TestProvision_SkipsSitePlaneWhenUnclaimed(t *testing.T) {
	for _, tc := range []struct {
		name string
		spec GoLiveSpec
	}{
		{"neither", acmeSpec()},
		{"token only", func() GoLiveSpec { s := agentSpec(); s.ControlURL = ""; return s }()},
		{"control-url only", func() GoLiveSpec { s := agentSpec(); s.AgentToken = ""; return s }()},
	} {
		t.Run(tc.name, func(t *testing.T) {
			wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(tc.spec.healthTarget()))
			if _, err := wp.Provision(context.Background(), tc.spec); err != nil {
				t.Fatalf("Provision: %v", err)
			}
			if slices.Contains(runner.titles, sitePlaneStepTitle) {
				t.Errorf("site-plane step ran for an unclaimed box (should skip); titles:\n%s",
					strings.Join(runner.titles, "\n"))
			}
			all := runnerArgvJoined(runner)
			for _, forbidden := range []string{"barkpark-builder", "barkpark-runtime", "nixpacks"} {
				if strings.Contains(all, forbidden) {
					t.Errorf("site-plane commands ran for an unclaimed box; found %q in:\n%s", forbidden, all)
				}
			}
			if !reg.Has("acme.barkpark.cloud") {
				t.Errorf("box not registered; registry=%+v", reg.Registered())
			}
		})
	}
}

// TestProvision_SitePlaneFailureDoesNotFailGoLive is the degrade-loudly contract:
// a box that serves its CMS perfectly must not be thrown away because apt/nixpacks
// hiccuped. The step fails, the go-live still returns a LiveServer and a nil
// error, the box registers — and the failure is SHOUTED to stderr so it is visible
// in the worker journal (the queue-age alarm is the standing backstop).
func TestProvision_SitePlaneFailureDoesNotFailGoLive(t *testing.T) {
	spec := agentSpec()
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	runner.stepErr = map[string]error{sitePlaneStepTitle: fmt.Errorf("nixpacks install failed (fake)")}

	r, w, _ := os.Pipe()
	origStderr := os.Stderr
	os.Stderr = w
	// Drain concurrently: a darwin pipe buffers only 512 bytes (64 KiB on Linux),
	// so reading only after the call returns deadlocks once the code under test
	// writes more warning text than the buffer holds.
	stderrCh := make(chan string, 1)
	go func() { var b strings.Builder; io.Copy(&b, r); stderrCh <- b.String() }()

	live, err := wp.Provision(context.Background(), spec)

	w.Close()
	os.Stderr = origStderr
	warning := <-stderrCh

	if err != nil {
		t.Fatalf("a failed site-plane install must NOT fail the go-live, got err: %v", err)
	}
	if live.FQDN != "acme.barkpark.cloud" {
		t.Errorf("go-live must still return the LiveServer; got %+v", live)
	}
	if !reg.Has("acme.barkpark.cloud") {
		t.Errorf("box not registered; registry=%+v", reg.Registered())
	}
	// The step really did run and really did fail — without this the test would pass
	// vacuously if the step were silently skipped.
	if !slices.Contains(runner.titles, sitePlaneStepTitle) {
		t.Fatalf("site-plane step never ran, so its failure path was never exercised; titles:\n%s",
			strings.Join(runner.titles, "\n"))
	}
	if !strings.Contains(warning, "site-plane install on") || !strings.Contains(warning, "WARNING") {
		t.Errorf("a degraded site-plane install must warn loudly on stderr; got:\n%s", warning)
	}
	if !strings.Contains(warning, "nixpacks install failed (fake)") {
		t.Errorf("the warning must carry the underlying error; got:\n%s", warning)
	}
}

// TestSiteRuntimeInstallScript_EmbedParity proves the bytes the chain ships are
// the bytes the shell harness gates. deploy/site-runtime-install_test.sh
// (.github/workflows/shell-harnesses.yml) tests deploy/site-runtime-install.sh;
// this asserts the embedded copy consumed by step 7c is BYTE-IDENTICAL to that
// file, so a gated script and a shipped script can never be two different things.
//
// Parity here is by CONSTRUCTION — deploy.SiteRuntimeInstallScript is a
// same-directory //go:embed of that one committed file, so there is no second
// copy to drift. This test is the tripwire on the embed DIRECTIVE (repointed at
// another file, or the file renamed away) rather than a drift detector, and the
// marker assertions below keep it from passing over a gutted script.
func TestSiteRuntimeInstallScript_EmbedParity(t *testing.T) {
	// cwd is the package dir under `go test`, so walk up to the repo root.
	const rel = "../../../deploy/site-runtime-install.sh"
	onDisk, err := os.ReadFile(rel)
	if err != nil {
		t.Fatalf("read %s (path must resolve from the package dir): %v", rel, err)
	}
	if string(onDisk) != deploy.SiteRuntimeInstallScript {
		t.Errorf("embedded script drifted from %s: embedded %d bytes, on disk %d bytes",
			rel, len(deploy.SiteRuntimeInstallScript), len(onDisk))
	}
	// Non-vacuity: two EMPTY or gutted files would also be "identical". Pin the
	// load-bearing lines so parity over a hollowed-out script fails.
	if len(deploy.SiteRuntimeInstallScript) < 1000 {
		t.Fatalf("embedded script is implausibly short (%d bytes) — parity is vacuous",
			len(deploy.SiteRuntimeInstallScript))
	}
	for _, want := range []string{
		"$GO build -o /usr/local/bin/barkpark-builder ./cmd/barkpark-builder",
		"$GO build -o /usr/local/bin/barkpark-runtime ./cmd/barkpark-runtime",
		"--token-file /etc/barkpark/agent.token",
		"systemctl enable --now barkpark-builder barkpark-runtime",
	} {
		if !strings.Contains(deploy.SiteRuntimeInstallScript, want) {
			t.Errorf("embedded script missing load-bearing line %q", want)
		}
	}
}

// TestSiteRuntimeInstallStep_Shape pins the step's delivery contract: the script
// rides as Argv[2] of `bash -lc` (sshStepArgv base64s that string and decodes it
// to a tempfile on the box, so the script's own quoting survives), the narration
// never carries the script body, and no redaction is claimed — the script sources
// no .env and carries no secret VALUE, only a token FILE reference.
func TestSiteRuntimeInstallStep_Shape(t *testing.T) {
	s := siteRuntimeInstallStep()

	if len(s.Argv) != 3 || s.Argv[0] != "bash" || s.Argv[1] != "-lc" {
		t.Fatalf("siteRuntimeInstallStep argv = %v, want [bash -lc <script>]", s.Argv)
	}
	if s.Argv[2] != deploy.SiteRuntimeInstallScript {
		t.Errorf("step must ship the embedded script verbatim, not a rewrite of it")
	}
	if strings.Contains(s.Cmd, "systemctl") || len(s.Cmd) > 200 {
		t.Errorf("Cmd is narration, not the script body; got %q", s.Cmd)
	}
	// The script sources no /opt/barkpark/.env, so pattern-scrubbing would be a
	// false claim. This assertion is the tripwire: if the script ever starts
	// sourcing .env, it fails and RedactEnvSecrets must be turned on.
	if strings.Contains(deploy.SiteRuntimeInstallScript, "/opt/barkpark/.env") {
		t.Errorf("the script now sources /opt/barkpark/.env — set RedactEnvSecrets on this step")
	}
	if s.RedactEnvSecrets {
		t.Errorf("RedactEnvSecrets claims an .env-sourcing step that this is not")
	}
	if len(s.Redact) != 0 {
		t.Errorf("no secret value is interpolated into this step; Redact should be empty, got %v", s.Redact)
	}
}

// runnerArgvJoined flattens every recorded step's Argv into one string so a test
// can assert on the on-box script content (the writes live in the Argv, not Cmd).
func runnerArgvJoined(r *recordingRunner) string {
	var b strings.Builder
	for _, argv := range r.argvs {
		for _, a := range argv {
			b.WriteString(a)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

// TestDefaultSecretGen_FiveIndependentDraws asserts the default generator mints a
// KEK/cloak/preview/release-capture HMAC that are each base64 of EXACTLY 32 bytes
// (the KEK's hard requirement — runtime.exs Base.decode64's it to 32 bytes; the
// 44-char encoding also clears runtime.exs's 32-byte floor on the release-capture
// HMAC STRING) and that all five secret values are DISTINCT (independent draws,
// no shared entropy).
func TestDefaultSecretGen_FiveIndependentDraws(t *testing.T) {
	sec, err := defaultSecretGen()
	if err != nil {
		t.Fatalf("defaultSecretGen: %v", err)
	}
	for _, kv := range []struct{ name, val string }{
		{"BARKPARK_KEK", sec.Kek},
		{"BARKPARK_CLOAK_KEY", sec.CloakKey},
		{"PREVIEW_JWT_SECRET", sec.PreviewJWTSecret},
		{"BARKPARK_RELEASE_CAPTURE_HMAC_SECRET", sec.ReleaseCaptureHMAC},
	} {
		raw, err := base64.StdEncoding.DecodeString(kv.val)
		if err != nil {
			t.Errorf("%s = %q is not standard base64: %v", kv.name, kv.val, err)
			continue
		}
		if len(raw) != 32 {
			t.Errorf("%s decodes to %d bytes, want 32", kv.name, len(raw))
		}
	}
	// SECRET_KEY_BASE: dedicated 64-byte base64url draw (~86 chars). The old
	// admin-token reuse minted 32 chars and 500'd every session-backed route.
	if raw, err := base64.RawURLEncoding.DecodeString(sec.SecretKeyBase); err != nil {
		t.Errorf("SECRET_KEY_BASE %q is not base64url: %v", sec.SecretKeyBase, err)
	} else if len(raw) != 64 {
		t.Errorf("SECRET_KEY_BASE decodes to %d bytes, want 64", len(raw))
	}
	if err := validateSecretKeyBase(sec.SecretKeyBase); err != nil {
		t.Errorf("minted SECRET_KEY_BASE must pass its own validator: %v", err)
	}

	// All five values must be distinct — no shared entropy across keys.
	vals := []string{sec.SecretKeyBase, sec.Kek, sec.CloakKey, sec.PreviewJWTSecret, sec.ReleaseCaptureHMAC}
	seen := map[string]bool{}
	for _, v := range vals {
		if v == "" {
			t.Error("a minted secret value is empty")
		}
		if seen[v] {
			t.Errorf("duplicate secret value %q — draws are not independent", v)
		}
		seen[v] = true
	}
}

// TestProvision_InstallsAllFiveSecretsBeforeMigrate is the dwb-20 end-to-end: the
// go-live chain installs ALL five MINTED per-instance secrets on the box (each
// carried via its own BP_* env) BEFORE the migrate step — so `mix ecto.migrate`
// sees BARKPARK_KEK (and the release-capture HMAC runtime.exs raises without)
// when it sources .env — and every value reaches the install script's Argv but
// NEVER a narrated Cmd.
func TestProvision_InstallsAllFiveSecretsBeforeMigrate(t *testing.T) {
	sec := knownFiveSecrets()
	spec := acmeSpec()
	wp, _, _, runner, _ := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	// Mint KNOWN per-instance secrets so the test can assert they were installed.
	wp.Secrets = func() (Secrets, error) { return sec, nil }

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	// Locate the secrets-install step and the migrate step by their recorded order.
	secretsIdx, migrateIdx, script := -1, -1, ""
	for i, argv := range runner.argvs {
		if len(argv) != 3 {
			continue
		}
		if strings.Contains(argv[2], "BARKPARK_KEK=") && strings.Contains(argv[2], "systemctl restart barkpark") {
			secretsIdx, script = i, argv[2]
		}
		if strings.Contains(argv[2], "ecto.migrate") {
			migrateIdx = i
		}
	}
	if secretsIdx == -1 {
		t.Fatalf("no secrets-install (BARKPARK_KEK + restart) step ran; cmds:\n%s", runner.joined())
	}
	if migrateIdx == -1 {
		t.Fatalf("no migrate step ran; cmds:\n%s", runner.joined())
	}
	// CHAIN ORDER: secrets install must run BEFORE migrate so the KEK exists when
	// migrate sources .env (the blocker this task fixes).
	if secretsIdx >= migrateIdx {
		t.Errorf("secrets-install ran at step %d, migrate at %d — secrets MUST precede migrate", secretsIdx, migrateIdx)
	}
	// All five minted values reach the install Argv, each via its own env export.
	for _, want := range []string{
		"export BP_SKB='" + sec.SecretKeyBase + "'",
		"export BP_KEK='" + sec.Kek + "'",
		"export BP_CLOAK='" + sec.CloakKey + "'",
		"export BP_PREVIEW='" + sec.PreviewJWTSecret + "'",
		"export BP_RCH='" + sec.ReleaseCaptureHMAC + "'",
	} {
		if !strings.Contains(script, want) {
			t.Errorf("secrets step did not install %q; script:\n%s", want, script)
		}
	}
	// The narrated Cmds must never carry any value (only the Argv installs them).
	for _, v := range []string{sec.SecretKeyBase, sec.Kek, sec.CloakKey, sec.PreviewJWTSecret, sec.ReleaseCaptureHMAC} {
		if strings.Contains(runner.joined(), v) {
			t.Errorf("a minted secret leaked into a narrated Cmd:\n%s", runner.joined())
		}
	}
}

// TestSecretsInstallStep_Idempotent asserts a re-run never duplicates a .env line:
// the single grep -v strips the prior line for each key before the append, so
// running the step twice over the same file yields exactly one line per key.
func TestSecretsInstallStep_Idempotent(t *testing.T) {
	sec := knownFiveSecrets()
	script := secretsInstallStep(sec, MailRelay{}).Argv[2]
	// The grep -v must strip a prior line for EACH of the five keys (the anchored
	// '^KEY=' patterns) — that is what makes append-then-swap idempotent.
	for _, key := range []string{"SECRET_KEY_BASE", "BARKPARK_KEK", "BARKPARK_CLOAK_KEY", "PREVIEW_JWT_SECRET", "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"} {
		if !strings.Contains(script, "-e '^"+key+"='") {
			t.Errorf("idempotent grep -v does not strip a prior %s= line; script:\n%s", key, script)
		}
		// Exactly one printf-append per key (no accidental double-write).
		if got := strings.Count(script, "'"+key+"=%s\\n'"); got != 1 {
			t.Errorf("key %s is appended %d times, want exactly 1; script:\n%s", key, got, script)
		}
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

// TestProvisionOneShot_ReapsLeakedPredecessor proves the dwb-11 crashed-worker
// recovery: a half-built box a prior attempt's DEAD worker left behind (managed +
// same barkpark-fqdn label, never orphan-labeled because no teardown ran) is
// deleted when the re-claimed job's fresh attempt provisions its new box —
// closing the only leak path where a box billed forever (SweepOrphans skips it,
// DeprovisionByIP never learns its IP).
func TestProvisionOneShot_ReapsLeakedPredecessor(t *testing.T) {
	ctx := context.Background()
	spec := acmeSpec()
	prov := NewFakeProvider()

	// The leaked predecessor: created by the crashed prior attempt, fqdn-labeled
	// at create (labelFQDN is fail-closed, so any surviving box carries it), but
	// NOT orphan-labeled — the crash meant cleanupHost never ran.
	leaked, err := prov.Create(ctx, ServerSpec{Name: "bp-acme-deadcafe"})
	if err != nil {
		t.Fatalf("create leaked predecessor: %v", err)
	}
	if err := prov.LabelServer(ctx, leaked.Name, FQDNLabelKey, spec.fqdn()); err != nil {
		t.Fatalf("label leaked predecessor: %v", err)
	}
	// A bystander instance on a DIFFERENT fqdn must never be touched.
	other, err := prov.Create(ctx, ServerSpec{Name: "bp-other-11223344"})
	if err != nil {
		t.Fatalf("create bystander: %v", err)
	}
	if err := prov.LabelServer(ctx, other.Name, FQDNLabelKey, "other.barkpark.cloud"); err != nil {
		t.Fatalf("label bystander: %v", err)
	}

	wp := &WarmPool{
		Provider:           prov,
		DNS:                NewFakeDNS(),
		Runner:             &recordingRunner{},
		Health:             greenGate(spec.healthTarget()),
		Registry:           NewFakeRegistry(),
		HealthPollInterval: time.Millisecond,
		HealthPollDeadline: 30 * time.Millisecond,
	}

	live, err := wp.ProvisionOneShot(ctx, spec)
	if err != nil {
		t.Fatalf("ProvisionOneShot: %v", err)
	}

	remaining, _ := prov.List(ctx)
	names := map[string]bool{}
	for _, s := range remaining {
		names[s.Name] = true
	}
	if names[leaked.Name] {
		t.Errorf("the leaked predecessor %q survived — it bills forever (no sweep can reach it)", leaked.Name)
	}
	if !names[other.Name] {
		t.Errorf("the bystander box %q (different fqdn) was deleted — reap hit the wrong box!", other.Name)
	}
	if !names[live.Server.Name] {
		t.Errorf("the freshly-provisioned box %q is gone — reap deleted its own attempt", live.Server.Name)
	}
	if len(remaining) != 2 {
		t.Errorf("after the reap %d boxes remain, want 2 (new + bystander): %+v", len(remaining), names)
	}
}

// TestReapLeakedPredecessors_DeleteFailureMarksOrphaned proves the double-failure
// fallback: when the predecessor's Delete persistently fails, the box is marked
// barkpark-orphaned=true so SweepOrphans recovers it on a later cycle (the same
// ladder cleanupHost uses), and the aggregated error surfaces for the log.
func TestReapLeakedPredecessors_DeleteFailureMarksOrphaned(t *testing.T) {
	ctx := context.Background()
	prov := &deleteErrProvider{FakeProvider: NewFakeProvider()}

	leaked, err := prov.Create(ctx, ServerSpec{Name: "bp-acme-feedface"})
	if err != nil {
		t.Fatalf("create leaked predecessor: %v", err)
	}
	if err := prov.LabelServer(ctx, leaked.Name, FQDNLabelKey, "acme.barkpark.cloud"); err != nil {
		t.Fatalf("label leaked predecessor: %v", err)
	}

	wp := &WarmPool{Provider: prov, DeleteRetryBackoff: time.Millisecond}
	rerr := wp.reapLeakedPredecessors(ctx, "acme.barkpark.cloud", "bp-acme-current")
	if rerr == nil {
		t.Fatal("reapLeakedPredecessors: want the aggregated delete error, got nil")
	}
	if !strings.Contains(rerr.Error(), "ORPHAN") {
		t.Errorf("reap error does not surface the billed orphan: %v", rerr)
	}

	// The box could not be deleted but IS now orphan-labeled for the sweep.
	orphaned, _ := prov.ListByLabel(ctx, OrphanedLabelKey, "true")
	found := false
	for _, s := range orphaned {
		if s.Name == leaked.Name {
			found = true
		}
	}
	if !found {
		t.Errorf("undeletable predecessor %q was not marked orphaned for the sweep", leaked.Name)
	}
}

// TestDeprovisionByIP_SweepIsNarrowedWhenTheIPIsShared — the co-tenant half of
// the DNS story, made load-bearing by cch-w54-s6's by-value sweep (wave review).
//
// TestDeprovisionByIP_IPReuseMatchesByFQDNLabel above pins the SERVER half: on a
// recycled IP, only the box whose identity label matches is deleted. Nothing
// pinned the DNS half, and the sweep is by VALUE — so a job running at a shared
// address would delete EVERY A record pointing there, including the live
// co-tenant's. The by-name delete it replaced could not do that.
//
// Two things are asserted, and the second is the one that would have been a
// customer outage:
//
//  1. our own platform record still dies (the job still does its job), and
//  2. the co-tenant's record SURVIVES — at a shared address the step degrades
//     to the by-name delete rather than sweeping an address we do not hold
//     exclusively.
//
// Both list orders are exercised, because the identity scan used to `break` on
// the first match and therefore only ever noticed a stranger listed FIRST.
func TestDeprovisionByIP_SweepIsNarrowedWhenTheIPIsShared(t *testing.T) {
	for _, order := range []string{"ours-created-first", "stranger-created-first"} {
		t.Run(order, func(t *testing.T) {
			ctx := context.Background()
			prov := NewFakeProvider()

			first, second := "mine-box", "other-box"
			if order == "stranger-created-first" {
				first, second = "other-box", "mine-box"
			}
			a, _ := prov.Create(ctx, ServerSpec{Name: first})
			if _, err := prov.Create(ctx, ServerSpec{Name: second}); err != nil {
				t.Fatalf("seed %s: %v", second, err)
			}
			// Force IP reuse: both managed boxes now carry the SAME address.
			forceFakeServerIP(prov, second, a.IP)

			_ = prov.LabelServer(ctx, "mine-box", FQDNLabelKey, "acme-1.barkpark.cloud")
			_ = prov.LabelServer(ctx, "other-box", FQDNLabelKey, "other-2.barkpark.cloud")

			dns := NewFakeDNS()
			_ = dns.UpsertRecord(ctx, Record{Zone: "barkpark.cloud", Name: "acme-1", Type: "A", Value: a.IP})
			_ = dns.UpsertRecord(ctx, Record{Zone: "barkpark.cloud", Name: "other-2", Type: "A", Value: a.IP})

			wp := &WarmPool{Provider: prov, DNS: dns}
			if err := wp.DeprovisionByIP(ctx, a.IP, "acme-1", "barkpark.cloud"); err != nil {
				t.Fatalf("DeprovisionByIP: %v", err)
			}

			// The server half is unchanged: only our box died.
			remaining, _ := prov.List(ctx)
			if len(remaining) != 1 || remaining[0].Name != "other-box" {
				t.Fatalf("IP-reuse deprovision deleted the wrong box; remaining=%+v, want only other-box", remaining)
			}
			// Our platform record is gone…
			if vals, _ := dns.Resolve(ctx, "acme-1.barkpark.cloud"); len(vals) != 0 {
				t.Errorf("our own A record survived the deprovision: %v", vals)
			}
			// …and the CO-TENANT'S record — the live box's — is untouched. A
			// by-value sweep at this address would have taken it.
			vals, _ := dns.Resolve(ctx, "other-2.barkpark.cloud")
			if len(vals) == 0 {
				t.Errorf("the co-tenant's live A record was swept away by a by-value delete at a shared IP")
			}
		})
	}
}

// The one-click-apply arm flag (fleet-health, 2026-08-14): every managed box
// must ship with BARKPARK_SELF_UPDATE_APPLY=1, or the control plane's
// autoupdate rollout gets feature_not_configured (503) from the box and
// CONTAINS it — the v0.2.26 wave proved a fleet of unarmed boxes lands zero
// installs. Asserted on the script itself (append + strip idempotency) so the
// flag cannot silently fall out of the go-live chain.
func TestSecretsInstallStepArmsSelfUpdateApply(t *testing.T) {
	secrets := Secrets{
		SecretKeyBase:      strings.Repeat("s", 64),
		Kek:                strings.Repeat("k", 44),
		CloakKey:           strings.Repeat("c", 44),
		PreviewJWTSecret:   strings.Repeat("p", 44),
		ReleaseCaptureHMAC: strings.Repeat("r", 44),
	}

	for name, mail := range map[string]MailRelay{
		"without mail": {},
		"with mail":    {Host: "smtp.example.com", Username: "mailer@example.com", Password: strings.Repeat("m", 20)},
	} {
		t.Run(name, func(t *testing.T) {
			step := secretsInstallStep(secrets, mail)
			script := strings.Join(step.Argv, " ")

			if !strings.Contains(script, `printf 'BARKPARK_SELF_UPDATE_APPLY=%s\n' '1'`) {
				t.Fatalf("go-live script no longer arms one-click apply:\n%s", script)
			}
			if !strings.Contains(script, `-e '^BARKPARK_SELF_UPDATE_APPLY='`) {
				t.Fatalf("strip list misses the arm flag — a re-run would duplicate the line:\n%s", script)
			}
		})
	}
}

// enabledTestRelay is a fully-specified, shell-safe relay — the ENABLED arm of the
// per-provision mail narration (task-6c815cd398a99534). It must satisfy
// MailRelay.Validate (host/user/password alphabets) or Enabled() is false and the
// "enabled" arm would silently test the disabled path instead.
func enabledTestRelay() MailRelay {
	return MailRelay{Host: "smtp.relay.example", Port: "587", Username: "bp@example.com", Password: "relaypassword123"}
}

// captureProgress collects every Progress detail a chain narrates. The chain tees
// these to the provisioner's console emitter, which POSTs each one to the job's
// APPEND-ONLY persisted console — so what is captured here is exactly what a
// later reader of the provision record sees.
func captureProgress(wp *WarmPool) *[]string {
	var lines []string
	wp.Progress = func(step, status, detail string) {
		if detail != "" {
			lines = append(lines, step+": "+status+" — "+detail)
		}
	}
	return &lines
}

// assignWithMail runs one full AssignWarm go-live with the given relay and returns
// every narrated progress detail. Uses the AssignWarm path because it drives the
// REAL configureHost chain (secrets-install included), so a narration that is never
// CALLED fails here — a pure-function test of the string would not.
func assignWithMail(t *testing.T, mail MailRelay) []string {
	t.Helper()
	spec := acmeSpec()
	wp, prov, _, _, _ := warmAssignPool(greenGate(spec.healthTarget()))
	wp.Mail = mail
	lines := captureProgress(wp)

	ctx := context.Background()
	host, err := CreateWarmServer(ctx, prov, warmSpec())
	if err != nil {
		t.Fatalf("seed warm box: %v", err)
	}
	if _, err := wp.AssignWarm(ctx, host, spec); err != nil {
		t.Fatalf("AssignWarm: %v", err)
	}
	return *lines
}

// TestGoLive_NarratesMailRelayDisabled is the DEFECT arm: SMTP_RELAY_* unset is a
// valid worker config that provisions a mail-DEAD instance (magic-link,
// password-reset and verify-email answer OK and deliver nothing). Before this
// signal existed the go-live said NOTHING about it — the only statement was one
// worker-startup stderr line in a journal the provisioning operator never reads.
// The go-live must SAY it, per provision, and name what to set.
func TestGoLive_NarratesMailRelayDisabled(t *testing.T) {
	lines := assignWithMail(t, MailRelay{})
	joined := strings.Join(lines, "\n")

	if !strings.Contains(joined, "Mail relay NOT CONFIGURED") {
		t.Fatalf("a mail-DEAD go-live narrated no mail-relay signal; narration:\n%s", joined)
	}
	// The signal is only useful if it names the fix — an operator reading the
	// console must not have to go find which env vars are missing.
	for _, want := range []string{"SMTP_RELAY_HOST", "SMTP_RELAY_USERNAME", "SMTP_RELAY_PASSWORD"} {
		if !strings.Contains(joined, want) {
			t.Errorf("the disabled-mail narration does not name %s (what to set); narration:\n%s", want, joined)
		}
	}
	// It must not claim the opposite.
	if strings.Contains(joined, "Mail relay ENABLED") {
		t.Errorf("an unset relay narrated ENABLED; narration:\n%s", joined)
	}
}

// TestGoLive_NarratesMailRelayEnabled is the NEGATIVE-DIRECTION arm: the signal
// must not be a blanket "no mail" warning stapled onto every provision. A
// configured relay narrates ENABLED, names the relay host, and NEVER emits the
// mail-dead wording — otherwise an operator learns to ignore the line.
func TestGoLive_NarratesMailRelayEnabled(t *testing.T) {
	mail := enabledTestRelay()
	if !mail.Enabled() {
		t.Fatalf("fixture relay is not Enabled() — the enabled arm would test the disabled path: %v", mail.Validate())
	}
	lines := assignWithMail(t, mail)
	joined := strings.Join(lines, "\n")

	if !strings.Contains(joined, "Mail relay ENABLED via smtp.relay.example:587") {
		t.Fatalf("a mail-enabled go-live did not narrate the relay; narration:\n%s", joined)
	}
	if strings.Contains(joined, "NOT CONFIGURED") || strings.Contains(joined, "deliver NOTHING") {
		t.Errorf("a configured relay narrated the mail-dead wording; narration:\n%s", joined)
	}
	// The SASL password is not a console value.
	if strings.Contains(joined, mail.Password) {
		t.Errorf("the relay password leaked into the narration:\n%s", joined)
	}
}
