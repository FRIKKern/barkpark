package provisioner

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// attachEventLog is a shared ordered event log the fake DNS + fake runner both
// append to, so a test can assert the DNS upsert strictly PRECEDES every SSH
// step (DNS-then-SSH — Caddy's on-demand issuance needs the record in place).
type attachEventLog struct {
	mu     sync.Mutex
	events []string
}

func (l *attachEventLog) add(e string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, e)
}

func (l *attachEventLog) all() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.events...)
}

// recordingAttachDNS is the ordered-log DNS fake: it records each upsert (and
// its exact Record) without any network. err, when set, fails the upsert.
//
// It models a ZONE, not just a call log: an upsert adds the record and a delete
// removes it, so a test can ask the question that actually matters — "what A
// records does the zone hold at the end?" — instead of only "was DeleteRecord
// called?". The orphan hazard is a record that SURVIVES, so the assertion has to
// read residue, not calls. deleteErr, when set, fails the delete.
type recordingAttachDNS struct {
	log       *attachEventLog
	mu        sync.Mutex
	upserts   []cloud.Record
	deletes   []string // "<fqdn> <type>", in call order
	zone      map[string]cloud.Record
	err       error
	deleteErr error
}

func (d *recordingAttachDNS) UpsertRecord(_ context.Context, rec cloud.Record) error {
	d.mu.Lock()
	d.upserts = append(d.upserts, rec)
	if d.err == nil {
		if d.zone == nil {
			d.zone = map[string]cloud.Record{}
		}
		d.zone[cloud.Fqdn(rec.Name, rec.Zone)+" "+rec.Type] = rec
	}
	d.mu.Unlock()
	if d.log != nil {
		d.log.add("dns:upsert " + cloud.Fqdn(rec.Name, rec.Zone) + "→" + rec.Value)
	}
	return d.err
}

func (d *recordingAttachDNS) DeleteRecord(_ context.Context, zone, name, typ string) error {
	fqdn := cloud.Fqdn(name, zone)
	d.mu.Lock()
	d.deletes = append(d.deletes, fqdn+" "+typ)
	if d.deleteErr == nil {
		delete(d.zone, fqdn+" "+typ)
	}
	d.mu.Unlock()
	if d.log != nil {
		d.log.add("dns:delete " + fqdn + " " + typ)
	}
	return d.deleteErr
}

// aRecordsAt returns the fqdns of every A record the zone still holds pointing
// at ip — the residue an orphan audit would find.
func (d *recordingAttachDNS) aRecordsAt(ip string) []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []string
	for key, rec := range d.zone {
		if rec.Type == "A" && rec.Value == ip {
			out = append(out, strings.TrimSuffix(key, " A"))
		}
	}
	sort.Strings(out)
	return out
}

// stubAttachProvider is a CloudProvider whose box list a test controls, so the
// attach path's liveness re-check can be driven against "the box is gone" and,
// via onList, against the RACE — a deprovision that lands between the re-check
// and the upsert.
type stubAttachProvider struct {
	mu      sync.Mutex
	servers []cloud.Server
	err     error
	calls   int
	// onList fires after each List call with the 1-based call count, letting a
	// test mutate the fleet mid-flight.
	onList func(call int)
}

func (p *stubAttachProvider) List(context.Context) ([]cloud.Server, error) {
	p.mu.Lock()
	p.calls++
	call := p.calls
	servers := append([]cloud.Server(nil), p.servers...)
	err := p.err
	hook := p.onList
	p.mu.Unlock()
	if hook != nil {
		hook(call)
	}
	return servers, err
}

// removeServersAt drops every box holding ip — a deprovision, as the attach
// worker would observe it.
func (p *stubAttachProvider) removeServersAt(ip string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	kept := p.servers[:0]
	for _, s := range p.servers {
		if s.IP != ip {
			kept = append(kept, s)
		}
	}
	p.servers = kept
}

func (p *stubAttachProvider) Create(context.Context, cloud.ServerSpec) (cloud.Server, error) {
	return cloud.Server{}, errBoom
}
func (p *stubAttachProvider) IP(context.Context, string) (string, error) { return "", errBoom }
func (p *stubAttachProvider) Delete(context.Context, string) error       { return errBoom }

var _ cloud.CloudProvider = (*stubAttachProvider)(nil)

func (d *recordingAttachDNS) Resolve(context.Context, string) ([]string, error) { return nil, nil }

var _ cloud.DNSProvider = (*recordingAttachDNS)(nil)

// recordingAttachRunner is the ordered-log StepRunner fake: it records each step
// without touching a box. A non-empty failOn errors the first step whose Title
// contains it (the SSH-failure path).
type recordingAttachRunner struct {
	log    *attachEventLog
	mu     sync.Mutex
	steps  []cloud.CaddyStep
	failOn string
}

func (r *recordingAttachRunner) Run(_ context.Context, s cloud.CaddyStep) error {
	r.mu.Lock()
	r.steps = append(r.steps, s)
	r.mu.Unlock()
	if r.log != nil {
		r.log.add("ssh:" + s.Title)
	}
	if r.failOn != "" && strings.Contains(s.Title, r.failOn) {
		return errBoom
	}
	return nil
}

// attachFakeSeams wires DefaultAttachDomain entirely from the recording fakes —
// no real DNS, no real box. The provider holds ONE live box at validAttachSpec's
// IP, because the platform branch re-checks box liveness before it writes DNS:
// seams with no Provider are a refusal, not a happy path.
func attachFakeSeams() (Seams, *recordingAttachDNS, *recordingAttachRunner, *attachEventLog) {
	seams, dns, runner, log, _ := attachFakeSeamsWithProvider()
	return seams, dns, runner, log
}

// attachFakeSeamsWithProvider is attachFakeSeams plus a handle on the provider
// stub, for the tests that drive the box out from under the job.
func attachFakeSeamsWithProvider() (Seams, *recordingAttachDNS, *recordingAttachRunner, *attachEventLog, *stubAttachProvider) {
	log := &attachEventLog{}
	dns := &recordingAttachDNS{log: log}
	runner := &recordingAttachRunner{log: log}
	provider := &stubAttachProvider{
		servers: []cloud.Server{{ID: "srv-1", Name: "bp-gyldendal", IP: validAttachSpec().IP}},
	}
	seams := Seams{
		Provider:  provider,
		DNS:       dns,
		RunnerFor: func(string) cloud.StepRunner { return runner },
	}
	return seams, dns, runner, log, provider
}

// validAttachSpec is the pinned-contract claim payload the tests drive.
func validAttachSpec() AttachDomainSpec {
	return AttachDomainSpec{
		JobID:      "adjob-1",
		IP:         "203.0.113.9",
		CustomHost: "gyldendal.barkpark.cloud",
		DNSLabel:   "gyldendal",
		DNSZone:    "barkpark.cloud",
		AppPort:    4000,
	}
}

// fakeAttachDomainControlPlane is an httptest-backed stand-in for the Elixir
// control plane's internal ATTACH-DOMAIN-jobs endpoints — the attach-domain twin
// of fakeDeprovisionControlPlane. It serves one queued spec on claim (then 204
// once drained) and records the succeed/fail report.
type fakeAttachDomainControlPlane struct {
	mu sync.Mutex

	spec *AttachDomainSpec // served on the next claim; nil → 204

	claimCount  int
	claimAuth   string
	succeededID string
	succeedAuth string
	failedID    string
	failedError string
	failAuth    string
}

func (f *fakeAttachDomainControlPlane) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/internal/attach-domain-jobs/claim", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.claimCount++
		f.claimAuth = r.Header.Get("Authorization")
		if f.spec == nil {
			w.WriteHeader(http.StatusNoContent) // 204 — nothing pending
			return
		}
		// 200 {job_id, claim_token, ip, custom_host, dns_label, dns_zone, app_port}
		_ = json.NewEncoder(w).Encode(f.spec)
		f.spec = nil // serve it once; subsequent claims are 204
	})

	// /v1/internal/attach-domain-jobs/:id/succeed and /fail — route on the trailing verb.
	mux.HandleFunc("/v1/internal/attach-domain-jobs/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		id, verb := parseAttachDomainJobPath(r.URL.Path)
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		_ = json.Unmarshal(body, &payload)

		switch verb {
		case "succeed":
			f.succeededID = id
			f.succeedAuth = r.Header.Get("Authorization")
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "fail":
			f.failedID = id
			f.failedError = payload["error"]
			f.failAuth = r.Header.Get("Authorization")
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	})

	return mux
}

// parseAttachDomainJobPath splits /v1/internal/attach-domain-jobs/<id>/<verb>.
func parseAttachDomainJobPath(p string) (id, verb string) {
	const prefix = "/v1/internal/attach-domain-jobs/"
	rest := p[len(prefix):]
	for i := 0; i < len(rest); i++ {
		if rest[i] == '/' {
			return rest[:i], rest[i+1:]
		}
	}
	return rest, ""
}

// TestRunOnceAttachDomainHappyPath is the full happy path through the worker:
// the control plane hands back an attach-domain spec → the executor upserts the
// DNS A record FIRST, then runs the four SSH steps in order (env merge → vhost
// append → caddy validate+reload → app restart) → the worker POSTs succeed with
// the Bearer WORKER_TOKEN.
func TestRunOnceAttachDomainHappyPath(t *testing.T) {
	spec := validAttachSpec()
	cp := &fakeAttachDomainControlPlane{spec: &spec}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	seams, dns, runner, log := attachFakeSeams()
	w := &Worker{
		ControlURL:   srv.URL,
		Token:        testToken,
		HTTPClient:   srv.Client(),
		AttachDomain: DefaultAttachDomain(seams),
	}

	claimed, err := w.RunOnceAttachDomain(context.Background())
	if err != nil {
		t.Fatalf("RunOnceAttachDomain: %v", err)
	}
	if !claimed {
		t.Fatal("RunOnceAttachDomain claimed=false, want true (an attach-domain job was queued)")
	}

	// ── DNS: exactly one A upsert, label→ip in the platform zone ──
	if len(dns.upserts) != 1 {
		t.Fatalf("DNS upserts = %d, want 1 (%v)", len(dns.upserts), dns.upserts)
	}
	rec := dns.upserts[0]
	if rec.Zone != "barkpark.cloud" || rec.Name != "gyldendal" || rec.Type != "A" || rec.Value != "203.0.113.9" {
		t.Errorf("DNS upsert = %+v, want gyldendal.barkpark.cloud A → 203.0.113.9", rec)
	}

	// ── ordering: the DNS upsert strictly precedes every SSH step ──
	events := log.all()
	if len(events) != 5 {
		t.Fatalf("events = %v, want 1 dns + 4 ssh", events)
	}
	if !strings.HasPrefix(events[0], "dns:upsert gyldendal.barkpark.cloud") {
		t.Errorf("first event = %q, want the DNS upsert before any SSH step", events[0])
	}
	for i, want := range []string{"BARKPARK_EXTRA_ORIGINS", "Caddy vhost", "validate + reload", "restart Barkpark"} {
		if !strings.Contains(events[i+1], want) {
			t.Errorf("event[%d] = %q, want an ssh step containing %q", i+1, events[i+1], want)
		}
	}

	// ── the rendered steps carry the pinned config ──
	envScript := runner.steps[0].Argv[2]
	if !strings.Contains(envScript, "BARKPARK_EXTRA_ORIGINS") || !strings.Contains(envScript, "https://gyldendal.barkpark.cloud") {
		t.Errorf("env-merge script missing the origin merge: %q", envScript)
	}
	vhostScript := runner.steps[1].Argv[2]
	for _, want := range []string{"gyldendal.barkpark.cloud {", "on_demand", "reverse_proxy 127.0.0.1:4000", "handle_errors"} {
		if !strings.Contains(vhostScript, want) {
			t.Errorf("vhost script missing %q:\n%s", want, vhostScript)
		}
	}

	// ── claim + succeed carried the Bearer WORKER_TOKEN; fail was NOT called ──
	if cp.claimAuth != "Bearer "+testToken {
		t.Errorf("claim Authorization = %q, want Bearer %s", cp.claimAuth, testToken)
	}
	if cp.succeededID != "adjob-1" {
		t.Errorf("succeed job id = %q, want adjob-1", cp.succeededID)
	}
	if cp.succeedAuth != "Bearer "+testToken {
		t.Errorf("succeed Authorization = %q, want Bearer %s", cp.succeedAuth, testToken)
	}
	if cp.failedID != "" {
		t.Errorf("fail was called (id=%q) on the happy path, want none", cp.failedID)
	}
}

// TestAttachDomainHostileSpecAborts is the fail-closed gate: a hostile or
// inconsistent claim payload (the worker NEVER trusts the control plane) must
// abort with NO DNS upsert and NO remote command — the values reach a Caddyfile
// and a shell script, so nothing may run before validation passes.
func TestAttachDomainHostileSpecAborts(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*AttachDomainSpec)
	}{
		{"shell metachars in custom_host", func(s *AttachDomainSpec) { s.CustomHost = "evil; rm -rf /.barkpark.cloud" }},
		{"command substitution in custom_host", func(s *AttachDomainSpec) { s.CustomHost = "$(reboot).barkpark.cloud" }},
		{"foreign zone", func(s *AttachDomainSpec) { s.CustomHost = "gyldendal.evil.com"; s.DNSZone = "evil.com" }},
		{"multi-label host", func(s *AttachDomainSpec) { s.CustomHost = "a.b.barkpark.cloud"; s.DNSLabel = "a.b" }},
		{"uppercase host", func(s *AttachDomainSpec) { s.CustomHost = "Gyldendal.barkpark.cloud"; s.DNSLabel = "Gyldendal" }},
		{"newline injection in dns_label", func(s *AttachDomainSpec) { s.DNSLabel = "gyldendal\nmalicious" }},
		{"label/host mismatch", func(s *AttachDomainSpec) { s.DNSLabel = "other" }},
		{"zone not the platform zone", func(s *AttachDomainSpec) { s.DNSZone = "barkpark.dev" }},
		{"hostile ip", func(s *AttachDomainSpec) { s.IP = "203.0.113.9; reboot" }},
		{"empty ip", func(s *AttachDomainSpec) { s.IP = "" }},
		{"zero app_port", func(s *AttachDomainSpec) { s.AppPort = 0 }},
		{"out-of-range app_port", func(s *AttachDomainSpec) { s.AppPort = 70000 }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			seams, dns, runner, _ := attachFakeSeams()
			spec := validAttachSpec()
			tc.mutate(&spec)

			err := DefaultAttachDomain(seams)(context.Background(), spec)
			if err == nil {
				t.Fatalf("DefaultAttachDomain accepted a hostile spec %+v, want an error", spec)
			}
			if len(dns.upserts) != 0 {
				t.Errorf("DNS was touched (%v) for a hostile spec, want NO side effects", dns.upserts)
			}
			if len(runner.steps) != 0 {
				t.Errorf("the runner ran %d step(s) for a hostile spec, want NO side effects", len(runner.steps))
			}
		})
	}
}

// TestRunOnceAttachDomainHostileSpecReportsFail proves the worker loop reports
// a validation abort to /fail (the job is failed, not silently dropped) and
// never POSTs succeed.
func TestRunOnceAttachDomainHostileSpecReportsFail(t *testing.T) {
	spec := validAttachSpec()
	spec.JobID = "adjob-evil"
	spec.CustomHost = "$(reboot).barkpark.cloud"
	cp := &fakeAttachDomainControlPlane{spec: &spec}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	seams, dns, runner, _ := attachFakeSeams()
	w := &Worker{
		ControlURL:   srv.URL,
		Token:        testToken,
		HTTPClient:   srv.Client(),
		AttachDomain: DefaultAttachDomain(seams),
	}

	claimed, err := w.RunOnceAttachDomain(context.Background())
	if err != nil {
		t.Fatalf("RunOnceAttachDomain returned an error for a validation abort, want nil (reported to /fail): %v", err)
	}
	if !claimed {
		t.Error("RunOnceAttachDomain claimed=false, want true (the job was drained even though it failed)")
	}
	if cp.failedID != "adjob-evil" {
		t.Errorf("fail job id = %q, want adjob-evil", cp.failedID)
	}
	if !strings.Contains(cp.failedError, "custom_host") {
		t.Errorf("fail error = %q, want the validation message", cp.failedError)
	}
	if cp.succeededID != "" {
		t.Errorf("succeed was called (id=%q) for a hostile spec, want none", cp.succeededID)
	}
	if len(dns.upserts) != 0 || len(runner.steps) != 0 {
		t.Errorf("side effects ran for a hostile spec: dns=%v steps=%d", dns.upserts, len(runner.steps))
	}
}

// TestRunOnceAttachDomainEmptyQueueNoCall proves a 204 claim is a clean no-op.
func TestRunOnceAttachDomainEmptyQueueNoCall(t *testing.T) {
	cp := &fakeAttachDomainControlPlane{spec: nil} // 204 on claim
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	calls := 0
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		AttachDomain: func(context.Context, AttachDomainSpec) error {
			calls++
			return nil
		},
	}

	claimed, err := w.RunOnceAttachDomain(context.Background())
	if err != nil {
		t.Fatalf("RunOnceAttachDomain: %v", err)
	}
	if claimed {
		t.Error("RunOnceAttachDomain claimed=true on a 204, want false")
	}
	if calls != 0 {
		t.Errorf("AttachDomain ran %d times on an empty queue, want 0", calls)
	}
	if cp.succeededID != "" || cp.failedID != "" {
		t.Errorf("a report was posted on an empty queue: succeed=%q fail=%q", cp.succeededID, cp.failedID)
	}
}

// TestRunOnceAttachDomainSSHFailureReportsFail proves a remote-step FAILURE is
// reported to /fail (not /succeed) and the cycle still counts as a handled
// claim. The DNS A record upserted BEFORE the failing step is ACCEPTABLE
// residue by design: it points the custom host at the box the instance already
// lives on, and the retry's upsert (create-or-replace) is an idempotent no-op —
// there is no orphan to clean up, so the executor does not roll DNS back.
func TestRunOnceAttachDomainSSHFailureReportsFail(t *testing.T) {
	spec := validAttachSpec()
	spec.JobID = "adjob-2"
	cp := &fakeAttachDomainControlPlane{spec: &spec}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	seams, dns, runner, _ := attachFakeSeams()
	runner.failOn = "validate + reload"
	w := &Worker{
		ControlURL:   srv.URL,
		Token:        testToken,
		HTTPClient:   srv.Client(),
		AttachDomain: DefaultAttachDomain(seams),
	}

	claimed, err := w.RunOnceAttachDomain(context.Background())
	if err != nil {
		t.Fatalf("RunOnceAttachDomain returned an error for a step failure, want nil (reported to /fail): %v", err)
	}
	if !claimed {
		t.Error("RunOnceAttachDomain claimed=false, want true (the job was drained even though it failed)")
	}
	if cp.failedID != "adjob-2" {
		t.Errorf("fail job id = %q, want adjob-2", cp.failedID)
	}
	if !strings.Contains(cp.failedError, errBoom.Error()) {
		t.Errorf("fail error = %q, want it to carry %q", cp.failedError, errBoom.Error())
	}
	if cp.succeededID != "" {
		t.Errorf("succeed was called (id=%q) on a step failure, want none", cp.succeededID)
	}
	// The DNS upsert had already run — acceptable (see the test comment above).
	if len(dns.upserts) != 1 {
		t.Errorf("DNS upserts = %d, want 1 (the upsert precedes the failing SSH step)", len(dns.upserts))
	}
	// The failing step aborted the remainder: restart never ran.
	if got := len(runner.steps); got != 3 {
		t.Errorf("runner ran %d steps, want 3 (env merge, vhost append, failing reload — no restart)", got)
	}
}

// runAttachScript executes one rendered remote step's script locally with bash
// against the temp files attachDomainSteps was pointed at. The Argv is
// ["bash","-lc",script]; the test drops -l (no login profile noise) — the
// script itself is identical.
func runAttachScript(t *testing.T, s cloud.CaddyStep) {
	t.Helper()
	out, err := exec.Command("bash", "-c", s.Argv[2]).CombinedOutput()
	if err != nil {
		t.Fatalf("step %q failed: %v\n%s", s.Title, err, out)
	}
}

// TestAttachDomainStepsIdempotent proves the two mutating box steps are
// idempotent by EXECUTING their rendered scripts (real bash, temp files) twice:
// the origin is merged into BARKPARK_EXTRA_ORIGINS exactly once (an existing
// list entry from another host is preserved, unrelated keys untouched) and the
// Caddy vhost block is appended exactly once.
func TestAttachDomainStepsIdempotent(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "app.env")
	caddyFile := filepath.Join(dir, "Caddyfile")

	// Seed the files the way a provisioned box looks: PHX_* pair + a prior
	// extra origin in the env, and the provision-time single-FQDN site block.
	if err := os.WriteFile(envFile, []byte("PHX_HOST=acme.barkpark.cloud\nPHX_SCHEME=https\nBARKPARK_EXTRA_ORIGINS=https://other.barkpark.cloud\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(caddyFile, []byte("acme.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	spec := validAttachSpec()
	steps := attachDomainSteps(spec, envFile, caddyFile)
	if len(steps) != 4 {
		t.Fatalf("attachDomainSteps returned %d steps, want 4", len(steps))
	}

	// Run the env-merge and vhost-append steps TWICE — the re-run must change nothing.
	for i := 0; i < 2; i++ {
		runAttachScript(t, steps[0])
		runAttachScript(t, steps[1])
	}

	env, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(env), "https://gyldendal.barkpark.cloud"); got != 1 {
		t.Errorf("origin appears %d times in the env after a re-run, want exactly 1:\n%s", got, env)
	}
	if got := strings.Count(string(env), "BARKPARK_EXTRA_ORIGINS="); got != 1 {
		t.Errorf("BARKPARK_EXTRA_ORIGINS appears %d times, want exactly 1:\n%s", got, env)
	}
	if !strings.Contains(string(env), "BARKPARK_EXTRA_ORIGINS=https://other.barkpark.cloud,https://gyldendal.barkpark.cloud") {
		t.Errorf("the prior origin was not preserved in the merged list:\n%s", env)
	}
	if !strings.Contains(string(env), "PHX_HOST=acme.barkpark.cloud") || !strings.Contains(string(env), "PHX_SCHEME=https") {
		t.Errorf("unrelated env keys were disturbed:\n%s", env)
	}

	caddy, err := os.ReadFile(caddyFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(caddy), "gyldendal.barkpark.cloud {"); got != 1 {
		t.Errorf("custom-host site block appears %d times after a re-run, want exactly 1:\n%s", got, caddy)
	}
	if !strings.Contains(string(caddy), "acme.barkpark.cloud {") {
		t.Errorf("the provision-time site block was disturbed:\n%s", caddy)
	}
	for _, want := range []string{"on_demand", "reverse_proxy 127.0.0.1:4000", "handle_errors"} {
		if !strings.Contains(string(caddy), want) {
			t.Errorf("appended vhost missing %q:\n%s", want, caddy)
		}
	}
}

// TestAttachDomainMergeCreatesKeyWhenAbsent proves the env merge on a box with
// NO existing BARKPARK_EXTRA_ORIGINS creates the key with the single origin —
// and stays single after a re-run.
func TestAttachDomainMergeCreatesKeyWhenAbsent(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "app.env")
	caddyFile := filepath.Join(dir, "Caddyfile")
	if err := os.WriteFile(envFile, []byte("PHX_HOST=acme.barkpark.cloud\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	steps := attachDomainSteps(validAttachSpec(), envFile, caddyFile)
	runAttachScript(t, steps[0])
	runAttachScript(t, steps[0])

	env, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(env), "BARKPARK_EXTRA_ORIGINS=https://gyldendal.barkpark.cloud"); got != 1 {
		t.Errorf("BARKPARK_EXTRA_ORIGINS=<origin> appears %d times, want exactly 1:\n%s", got, env)
	}
	if !strings.Contains(string(env), "PHX_HOST=acme.barkpark.cloud") {
		t.Errorf("PHX_HOST was disturbed:\n%s", env)
	}
}

// TestRunOnceAttachDomainNilFuncIsNoOp mirrors the deprovision contract: a
// worker without the AttachDomain seam quietly skips the queue.
func TestRunOnceAttachDomainNilFuncIsNoOp(t *testing.T) {
	w := &Worker{ControlURL: "http://127.0.0.1:1", Token: testToken}
	claimed, err := w.RunOnceAttachDomain(context.Background())
	if err != nil {
		t.Fatalf("RunOnceAttachDomain with a nil func: %v", err)
	}
	if claimed {
		t.Error("claimed=true with a nil AttachDomain, want false")
	}
}

// ── attach-domain V2: arbitrary EXTERNAL customer domains ──

// validExternalAttachSpec is the V2 external-domain claim payload: a
// customer-owned FQDN outside the platform zone. dns_label/dns_zone are EMPTY
// by contract — the customer owns DNS, so there is no platform record to
// upsert.
func validExternalAttachSpec() AttachDomainSpec {
	return AttachDomainSpec{
		JobID:      "adjob-ext-1",
		IP:         "203.0.113.9",
		CustomHost: "barkpark.jarl.no",
		AppPort:    4000,
	}
}

// recordingLookup is the system-resolver fake for the V2 ownership re-check:
// it records each lookup (and logs it into the shared event log, so ordering
// against the SSH steps is assertable) and returns a fixed address set/error.
type recordingLookup struct {
	log   *attachEventLog
	mu    sync.Mutex
	calls []string
	addrs []string
	err   error
}

func (l *recordingLookup) lookup(_ context.Context, host string) ([]string, error) {
	l.mu.Lock()
	l.calls = append(l.calls, host)
	l.mu.Unlock()
	if l.log != nil {
		l.log.add("resolve:" + host)
	}
	return l.addrs, l.err
}

// attachFakeSeamsWithLookup extends attachFakeSeams with the injectable
// system-resolver seam the external path re-verifies through.
func attachFakeSeamsWithLookup(addrs []string, lookupErr error) (Seams, *recordingAttachDNS, *recordingAttachRunner, *recordingLookup, *attachEventLog) {
	seams, dns, runner, log := attachFakeSeams()
	lk := &recordingLookup{log: log, addrs: addrs, err: lookupErr}
	seams.LookupHost = lk.lookup
	return seams, dns, runner, lk, log
}

// TestRunOnceAttachDomainExternalHappyPath is the V2 happy path: an external
// customer FQDN that already resolves to the box → the worker SKIPS the
// platform-DNS upsert entirely (customer owns DNS), re-verifies resolution →
// box IP FIRST, then runs the same four SSH steps as the platform path, and
// reports succeed.
func TestRunOnceAttachDomainExternalHappyPath(t *testing.T) {
	spec := validExternalAttachSpec()
	cp := &fakeAttachDomainControlPlane{spec: &spec}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	seams, dns, runner, lk, log := attachFakeSeamsWithLookup([]string{"2001:db8::7", "203.0.113.9"}, nil)
	w := &Worker{
		ControlURL:   srv.URL,
		Token:        testToken,
		HTTPClient:   srv.Client(),
		AttachDomain: DefaultAttachDomain(seams),
	}

	claimed, err := w.RunOnceAttachDomain(context.Background())
	if err != nil {
		t.Fatalf("RunOnceAttachDomain: %v", err)
	}
	if !claimed {
		t.Fatal("RunOnceAttachDomain claimed=false, want true (an external attach-domain job was queued)")
	}

	// ── the platform DNS zone is NEVER touched for an external host ──
	if len(dns.upserts) != 0 {
		t.Errorf("DNS upserts = %v, want NONE (the customer owns external DNS)", dns.upserts)
	}

	// ── ordering: the ownership re-check strictly precedes every SSH step ──
	events := log.all()
	if len(events) != 5 {
		t.Fatalf("events = %v, want 1 resolve + 4 ssh", events)
	}
	if events[0] != "resolve:barkpark.jarl.no" {
		t.Errorf("first event = %q, want the resolution re-check before any SSH step", events[0])
	}
	if got := lk.calls; len(got) != 1 || got[0] != "barkpark.jarl.no" {
		t.Errorf("lookup calls = %v, want exactly one for barkpark.jarl.no", got)
	}
	for i, want := range []string{"BARKPARK_EXTRA_ORIGINS", "Caddy vhost", "validate + reload", "restart Barkpark"} {
		if !strings.Contains(events[i+1], want) {
			t.Errorf("event[%d] = %q, want an ssh step containing %q", i+1, events[i+1], want)
		}
	}

	// ── the rendered steps carry the external host verbatim ──
	envScript := runner.steps[0].Argv[2]
	if !strings.Contains(envScript, "https://barkpark.jarl.no") {
		t.Errorf("env-merge script missing the external origin: %q", envScript)
	}
	vhostScript := runner.steps[1].Argv[2]
	for _, want := range []string{"barkpark.jarl.no {", "on_demand", "reverse_proxy 127.0.0.1:4000", "handle_errors"} {
		if !strings.Contains(vhostScript, want) {
			t.Errorf("vhost script missing %q:\n%s", want, vhostScript)
		}
	}

	if cp.succeededID != "adjob-ext-1" {
		t.Errorf("succeed job id = %q, want adjob-ext-1", cp.succeededID)
	}
	if cp.failedID != "" {
		t.Errorf("fail was called (id=%q) on the external happy path, want none", cp.failedID)
	}
}

// TestAttachDomainExternalHostileSpecAborts is the V2 fail-closed regex gate:
// an external host is interpolated into a Caddyfile and a shell script, so the
// well-formed-FQDN regex must exclude EVERY shell/Caddy metacharacter (dots,
// hyphens, alphanumerics only) plus the RFC length caps. Any miss aborts with
// no lookup, no DNS write, and no remote command.
func TestAttachDomainExternalHostileSpecAborts(t *testing.T) {
	overlong := strings.TrimSuffix(strings.Repeat(strings.Repeat("a", 63)+".", 4), ".") + ".no" // 259 chars

	cases := []struct {
		name   string
		mutate func(*AttachDomainSpec)
	}{
		{"shell metachars", func(s *AttachDomainSpec) { s.CustomHost = "foo.bar;rm -rf" }},
		{"command substitution", func(s *AttachDomainSpec) { s.CustomHost = "$(x).evil.com" }},
		{"backticks", func(s *AttachDomainSpec) { s.CustomHost = "`x`.evil.com" }},
		{"unicode label", func(s *AttachDomainSpec) { s.CustomHost = "bärkpark.jarl.no" }},
		{"uppercase", func(s *AttachDomainSpec) { s.CustomHost = "Barkpark.Jarl.No" }},
		{"254+ chars", func(s *AttachDomainSpec) { s.CustomHost = overlong }},
		{"single label", func(s *AttachDomainSpec) { s.CustomHost = "intranet" }},
		{"trailing dot", func(s *AttachDomainSpec) { s.CustomHost = "barkpark.jarl.no." }},
		{"empty label", func(s *AttachDomainSpec) { s.CustomHost = "a..no" }},
		{"leading hyphen", func(s *AttachDomainSpec) { s.CustomHost = "-bad.jarl.no" }},
		{"underscore", func(s *AttachDomainSpec) { s.CustomHost = "foo_bar.jarl.no" }},
		{"space", func(s *AttachDomainSpec) { s.CustomHost = "foo bar.jarl.no" }},
		{"newline", func(s *AttachDomainSpec) { s.CustomHost = "foo\n.jarl.no" }},
		{"bare IP shape (numeric TLD)", func(s *AttachDomainSpec) { s.CustomHost = "203.0.113.9" }},
		{"the platform apex itself", func(s *AttachDomainSpec) { s.CustomHost = "barkpark.cloud" }},
		{"over-63-char label", func(s *AttachDomainSpec) { s.CustomHost = strings.Repeat("a", 64) + ".jarl.no" }},
		{"external claim smuggling platform DNS halves", func(s *AttachDomainSpec) {
			s.DNSLabel = "barkpark"
			s.DNSZone = "jarl.no"
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			seams, dns, runner, lk, _ := attachFakeSeamsWithLookup([]string{"203.0.113.9"}, nil)
			spec := validExternalAttachSpec()
			tc.mutate(&spec)

			err := DefaultAttachDomain(seams)(context.Background(), spec)
			if err == nil {
				t.Fatalf("DefaultAttachDomain accepted a hostile external spec %+v, want an error", spec)
			}
			if len(lk.calls) != 0 {
				t.Errorf("the resolver was consulted (%v) for a hostile spec, want validation to abort first", lk.calls)
			}
			if len(dns.upserts) != 0 {
				t.Errorf("DNS was touched (%v) for a hostile spec, want NO side effects", dns.upserts)
			}
			if len(runner.steps) != 0 {
				t.Errorf("the runner ran %d step(s) for a hostile spec, want NO side effects", len(runner.steps))
			}
		})
	}
}

// TestAttachDomainExternalResolutionGate is the worker-side half of the V2
// ownership moat (defense in depth — the worker cannot trust the control
// plane): an external host that does NOT currently resolve to the box aborts
// with NO remote command and NO DNS write.
func TestAttachDomainExternalResolutionGate(t *testing.T) {
	cases := []struct {
		name  string
		addrs []string
		err   error
	}{
		{"resolves elsewhere", []string{"198.51.100.7"}, nil},
		{"resolves nowhere", nil, nil},
		{"resolver error (fail closed)", nil, errBoom},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			seams, dns, runner, lk, _ := attachFakeSeamsWithLookup(tc.addrs, tc.err)
			spec := validExternalAttachSpec()

			err := DefaultAttachDomain(seams)(context.Background(), spec)
			if err == nil {
				t.Fatal("DefaultAttachDomain succeeded for an un-pointed external host, want an error")
			}
			if got := lk.calls; len(got) != 1 || got[0] != spec.CustomHost {
				t.Errorf("lookup calls = %v, want exactly one for %s", got, spec.CustomHost)
			}
			if len(dns.upserts) != 0 {
				t.Errorf("DNS was touched (%v), want NO side effects", dns.upserts)
			}
			if len(runner.steps) != 0 {
				t.Errorf("the runner ran %d step(s), want NO side effects before the resolution gate passes", len(runner.steps))
			}
		})
	}
}

// TestRunOnceAttachDomainExternalMismatchReportsFail proves the worker loop
// reports a resolution-gate abort to /fail (the job fails visibly, never
// silently) and never POSTs succeed.
func TestRunOnceAttachDomainExternalMismatchReportsFail(t *testing.T) {
	spec := validExternalAttachSpec()
	spec.JobID = "adjob-ext-2"
	cp := &fakeAttachDomainControlPlane{spec: &spec}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	seams, _, runner, _, _ := attachFakeSeamsWithLookup([]string{"198.51.100.7"}, nil)
	w := &Worker{
		ControlURL:   srv.URL,
		Token:        testToken,
		HTTPClient:   srv.Client(),
		AttachDomain: DefaultAttachDomain(seams),
	}

	claimed, err := w.RunOnceAttachDomain(context.Background())
	if err != nil {
		t.Fatalf("RunOnceAttachDomain returned an error for a resolution abort, want nil (reported to /fail): %v", err)
	}
	if !claimed {
		t.Error("RunOnceAttachDomain claimed=false, want true (the job was drained even though it failed)")
	}
	if cp.failedID != "adjob-ext-2" {
		t.Errorf("fail job id = %q, want adjob-ext-2", cp.failedID)
	}
	if !strings.Contains(cp.failedError, "resolve") {
		t.Errorf("fail error = %q, want the resolution-gate message", cp.failedError)
	}
	if cp.succeededID != "" {
		t.Errorf("succeed was called (id=%q) for an un-pointed host, want none", cp.succeededID)
	}
	if len(runner.steps) != 0 {
		t.Errorf("the runner ran %d step(s) for an un-pointed host, want NO side effects", len(runner.steps))
	}
}

// TestAttachDomainPlatformPathSkipsResolutionGate pins the V1 platform path
// UNTOUCHED by V2: a platform-zone host still upserts platform DNS (we own the
// zone — pointing it IS the attach) and never consults the system resolver.
func TestAttachDomainPlatformPathSkipsResolutionGate(t *testing.T) {
	seams, dns, runner, lk, _ := attachFakeSeamsWithLookup(nil, errBoom)

	if err := DefaultAttachDomain(seams)(context.Background(), validAttachSpec()); err != nil {
		t.Fatalf("DefaultAttachDomain (platform host): %v", err)
	}
	if len(lk.calls) != 0 {
		t.Errorf("the system resolver was consulted (%v) for a platform host, want never", lk.calls)
	}
	if len(dns.upserts) != 1 {
		t.Errorf("DNS upserts = %d, want 1 (the platform A-record upsert is the attach)", len(dns.upserts))
	}
	if got := len(runner.steps); got != 4 {
		t.Errorf("runner ran %d steps, want 4", got)
	}
}

// ─── The orphaned-A-record class (task-c1014bb6c82298c2) ────────────────────
//
// Every orphan backstop in the fleet is keyed on a BOX: SweepOrphans lists boxes
// labelled barkpark-orphaned=true and deletes each one AND its stranded DNS
// record, and the deprovision teardown sweeps a box's records BY VALUE. Both
// reach a record only THROUGH a box. A record written when the box is already
// gone therefore carries no label and no owner, and is unreachable by
// construction — invisible to everything except a zone-level audit.
//
// attach_domain is the path that can write one. Deprovision deletes the box
// FIRST, so an attach job already CLAIMED when the teardown drains upserts its A
// record AFTER the by-value sweep meant to prevent exactly this. The tests below
// drive that ordering and assert on the ZONE's residue, not on call counts.

// TestAttachDomainRefusesWhenTheBoxIsAlreadyGone is the simple half: the box was
// deprovisioned before the worker got to the DNS write at all. The upsert is
// idempotent and would "succeed" — which is the trap. It must not run.
func TestAttachDomainRefusesWhenTheBoxIsAlreadyGone(t *testing.T) {
	spec := validAttachSpec()
	seams, dns, runner, _, provider := attachFakeSeamsWithProvider()
	provider.removeServersAt(spec.IP) // the deprovision already ran

	err := AttachDomainWith(context.Background(), seams, spec)
	if err == nil {
		t.Fatal("attach must FAIL when no box holds the IP — an idempotent upsert onto a freed address is an orphan, not a no-op")
	}
	if !strings.Contains(err.Error(), "no managed box holds") {
		t.Errorf("error must name the missing box, got %q", err)
	}
	if len(dns.upserts) != 0 {
		t.Errorf("refusal must precede EVERY side effect, got upserts %+v", dns.upserts)
	}
	if got := dns.aRecordsAt(spec.IP); len(got) != 0 {
		t.Errorf("zone must hold no A record at the freed address, got %v", got)
	}
	if len(runner.steps) != 0 {
		t.Errorf("no remote command may run against a box that is gone, got %d steps", len(runner.steps))
	}
}

// TestAttachDomainDeprovisionedMidUpsertLeavesNoRecord drives the ORDERING the
// row's acceptance names: attach claimed → deprovision succeeds (box deleted,
// zone swept by value) → the attach worker runs its DNS write. The pre-check
// alone cannot close this: the box is still live when it is consulted and gone a
// moment later. What closes it is the edge AFTER the write — re-check, and
// delete the record we just created. The assertion is the zone's residue.
func TestAttachDomainDeprovisionedMidUpsertLeavesNoRecord(t *testing.T) {
	spec := validAttachSpec()
	seams, dns, _, log, provider := attachFakeSeamsWithProvider()

	// The deprovision lands between the pre-check and the upsert: call 1 observes
	// a live box, and the teardown drains the instant it has answered.
	provider.onList = func(call int) {
		if call == 1 {
			provider.removeServersAt(spec.IP)
		}
	}

	err := AttachDomainWith(context.Background(), seams, spec)

	// The defect FIRST, so a red run prints the leaked record itself.
	if got := dns.aRecordsAt(spec.IP); len(got) != 0 {
		t.Errorf("ORPHAN: zone still holds %v at the freed address %s — the box is gone, so no box-keyed backstop (SweepOrphans, the by-value teardown sweep) can ever reach it", got, spec.IP)
	}
	if err == nil {
		t.Fatal("attach must FAIL when the box is deprovisioned mid-write — a silent success leaves a record nothing can reach")
	}
	if len(dns.deletes) != 1 {
		t.Errorf("the record written must be deleted again exactly once, got deletes %v", dns.deletes)
	}
	if provider.calls < 2 {
		t.Errorf("liveness must be re-checked AFTER the upsert too, got %d List calls", provider.calls)
	}
	// The record has to be created before it can be cleaned up — pin the order so
	// a future refactor cannot satisfy this test by never writing at all.
	events := log.all()
	var upsertAt, deleteAt = -1, -1
	for i, e := range events {
		if strings.HasPrefix(e, "dns:upsert") && upsertAt < 0 {
			upsertAt = i
		}
		if strings.HasPrefix(e, "dns:delete") && deleteAt < 0 {
			deleteAt = i
		}
	}
	if upsertAt < 0 || deleteAt < 0 || deleteAt < upsertAt {
		t.Errorf("expected an upsert then its delete, got %v", events)
	}
}

// TestAttachDomainNamesTheOrphanWhenCleanupFails is the honesty edge. When the
// record cannot be deleted again, the one thing that must NOT happen is a
// generic failure: nothing else in the fleet can find this record, so the error
// is the only artefact naming it. It must carry the FQDN and the address.
func TestAttachDomainNamesTheOrphanWhenCleanupFails(t *testing.T) {
	spec := validAttachSpec()
	seams, dns, _, _, provider := attachFakeSeamsWithProvider()
	dns.deleteErr = errBoom
	provider.onList = func(call int) {
		if call == 1 {
			provider.removeServersAt(spec.IP)
		}
	}

	err := AttachDomainWith(context.Background(), seams, spec)
	if err == nil {
		t.Fatal("a surviving orphan must fail the job")
	}
	msg := err.Error()
	if !strings.Contains(msg, "ORPHANED A RECORD") {
		t.Errorf("error must announce the orphan in words an operator can grep, got %q", msg)
	}
	if !strings.Contains(msg, cloud.Fqdn(spec.DNSLabel, spec.DNSZone)) {
		t.Errorf("error must name the FQDN %q — nothing else can find it, got %q", cloud.Fqdn(spec.DNSLabel, spec.DNSZone), msg)
	}
	if !strings.Contains(msg, spec.IP) {
		t.Errorf("error must name the freed address %q, got %q", spec.IP, msg)
	}
}

// TestAttachDomainLivenessCheckFailsClosed: an unreadable fleet is not a licence
// to write DNS. Same posture the EXTERNAL branch already takes on a resolver
// error ("refusing before any side effect").
func TestAttachDomainLivenessCheckFailsClosed(t *testing.T) {
	spec := validAttachSpec()
	seams, dns, _, _, provider := attachFakeSeamsWithProvider()
	provider.err = errBoom

	err := AttachDomainWith(context.Background(), seams, spec)
	if err == nil {
		t.Fatal("a provider error must abort the attach, not proceed on assumption")
	}
	if !strings.Contains(err.Error(), "fail closed") {
		t.Errorf("error must say it failed closed, got %q", err)
	}
	if len(dns.upserts) != 0 {
		t.Errorf("no DNS write may happen when liveness is unknown, got %+v", dns.upserts)
	}
}

// TestAttachDomainPlatformRequiresProvider pins the seam as MANDATORY on the
// platform branch. A nil Provider used to mean "skip the check"; that is the
// shape that lets the guard quietly stop existing in some wiring.
func TestAttachDomainPlatformRequiresProvider(t *testing.T) {
	spec := validAttachSpec()
	seams, dns, _, _, _ := attachFakeSeamsWithProvider()
	seams.Provider = nil

	err := AttachDomainWith(context.Background(), seams, spec)
	if err == nil {
		t.Fatal("a platform attach with no CloudProvider must refuse — the liveness re-check is not optional")
	}
	if !strings.Contains(err.Error(), "CloudProvider") {
		t.Errorf("error must name the missing seam, got %q", err)
	}
	if len(dns.upserts) != 0 {
		t.Errorf("no DNS write without the guard, got %+v", dns.upserts)
	}
}

// TestAttachDomainExternalPathNeedsNoProvider proves the widening did not reach
// the EXTERNAL branch. A customer-owned FQDN gets no platform upsert at all, so
// there is no record for us to orphan and no reason to demand a provider — its
// own resolve gate is already the fail-closed moat.
func TestAttachDomainExternalPathNeedsNoProvider(t *testing.T) {
	spec := validAttachSpec()
	spec.CustomHost = "barkpark.jarl.no"
	spec.DNSLabel = ""
	spec.DNSZone = ""

	seams, dns, runner, _, _ := attachFakeSeamsWithProvider()
	seams.Provider = nil
	seams.LookupHost = func(context.Context, string) ([]string, error) { return []string{spec.IP}, nil }

	if err := AttachDomainWith(context.Background(), seams, spec); err != nil {
		t.Fatalf("external attach must not require a CloudProvider: %v", err)
	}
	if len(dns.upserts) != 0 {
		t.Errorf("the external branch must never upsert platform DNS, got %+v", dns.upserts)
	}
	if len(runner.steps) == 0 {
		t.Error("the external attach should still run its on-box steps")
	}
}
