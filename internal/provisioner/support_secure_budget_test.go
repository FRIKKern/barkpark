package provisioner

// support_secure_budget_test.go proves the ONE property criterion 1 of
// pdf-w1-secure-stall-diagnosis asks for: the secure leg always reaches a
// TERMINAL state. The live P1 refire (job 4d7be1c2, 2026-07-28) reached
// create:done, reported secure:started, and then produced NO terminal state at
// all inside an 1800s watch — while the chain-wide DefaultSupportProvisionTimeout
// (worker.go, 30m) was already in force. That is the tell: a ctx deadline is a
// REQUEST to the callee, and the secure leg's two callees are exec-backed seams
// that can outlive their own ctx. So these tests inject seams that IGNORE ctx
// ENTIRELY — the honest model of the observed stall — and assert the chain still
// fails honestly, tears the box down, and sweeps the DNS record.
//
// Both arms carry the discriminator the assertion needs: each records WHICH
// call it blocked on, and each asserts the OTHER secure call reached its normal
// outcome. An injector armed on the wrong call site goes green while the hole
// under test never runs.

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// secureStallDNS is a DNSProvider whose UpsertRecord blocks until release is
// closed, IGNORING ctx — the exec-backed seam that outlives its own deadline.
// stallUpsert=false makes the upsert succeed so the SAME double can serve the
// caddy arm, where the upsert MUST complete for the assertion to discriminate.
type secureStallDNS struct {
	mu          sync.Mutex
	upserts     []cloud.Record
	deletes     []string
	stallUpsert bool
	entered     chan struct{} // closed the first time UpsertRecord is entered
	enteredOnce sync.Once
	release     <-chan struct{}
}

func (d *secureStallDNS) UpsertRecord(_ context.Context, rec cloud.Record) error {
	d.enteredOnce.Do(func() { close(d.entered) })
	d.mu.Lock()
	d.upserts = append(d.upserts, rec)
	d.mu.Unlock()
	if d.stallUpsert {
		<-d.release // NEVER honors ctx — the whole point.
	}
	return nil
}

func (d *secureStallDNS) DeleteRecord(_ context.Context, zone, name, typ string) error {
	d.mu.Lock()
	d.deletes = append(d.deletes, name+"."+zone+"/"+typ)
	d.mu.Unlock()
	return nil
}

func (d *secureStallDNS) Resolve(context.Context, string) ([]string, error) { return nil, nil }

func (d *secureStallDNS) snapshot() (upserts []cloud.Record, deletes []string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]cloud.Record(nil), d.upserts...), append([]string(nil), d.deletes...)
}

var _ cloud.DNSProvider = (*secureStallDNS)(nil)

// secureStallRunner is a SupportRunner whose Run blocks forever, IGNORING ctx —
// the Caddy/TLS half of the same stall shape (the real one shells ssh out
// through exec.CommandContext, whose Wait can outlive the killed child).
type secureStallRunner struct {
	*supportFakeRunner
	entered     chan struct{}
	enteredOnce sync.Once
	release     <-chan struct{}
	mu          sync.Mutex
	blockedOn   []string // step titles Run was entered with
}

func (r *secureStallRunner) Run(_ context.Context, s cloud.CaddyStep) error {
	r.enteredOnce.Do(func() { close(r.entered) })
	r.mu.Lock()
	r.blockedOn = append(r.blockedOn, s.Title)
	r.mu.Unlock()
	<-r.release
	return nil
}

func (r *secureStallRunner) titles() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.blockedOn...)
}

var _ cloud.SupportRunner = (*secureStallRunner)(nil)

// runSupportUnderWatchdog runs one RunOnceSupport and FAILS THE TEST if it does
// not return — the honest RED for this defect. Without the per-step budget the
// chain hangs on the injected seam and this watchdog is what fires; with it,
// the chain returns in ~budget.
func runSupportUnderWatchdog(t *testing.T, w *Worker, watch time.Duration) time.Duration {
	t.Helper()
	type res struct {
		claimed bool
		err     error
	}
	out := make(chan res, 1)
	start := time.Now()
	go func() {
		claimed, err := w.RunOnceSupport(context.Background())
		out <- res{claimed, err}
	}()
	select {
	case r := <-out:
		if r.err != nil {
			t.Fatalf("RunOnceSupport should consume the job cleanly (fail reported), got: %v", r.err)
		}
		if !r.claimed {
			t.Fatal("the job should have been claimed + consumed")
		}
		return time.Since(start)
	case <-time.After(watch):
		t.Fatalf("THE CHAIN NEVER REACHED A TERMINAL STATE: RunOnceSupport did not return within %s "+
			"(this is the pdf-w1 stall reproduced — secure:started with no terminal report)", watch)
		return 0
	}
}

const secureTestBudget = 60 * time.Millisecond

// TestSupportSecure_DNSUpsertStalls_ReachesTerminalState — arm A. The DNS
// upsert never returns; the chain must still fail honestly and sweep.
func TestSupportSecure_DNSUpsertStalls_ReachesTerminalState(t *testing.T) {
	release := make(chan struct{})
	t.Cleanup(func() { close(release) }) // let the abandoned goroutine exit.

	h := newSupportHarness(t)
	runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	var deleted []string
	w := h.worker(runner, &deleted)

	dns := &secureStallDNS{stallUpsert: true, entered: make(chan struct{}), release: release}
	seams := SupportSeams{
		CreateServer: func(_ context.Context, name string) (cloud.Server, error) {
			return cloud.Server{Name: "support-box-" + name, IP: "203.0.113.9"}, nil
		},
		DeleteServer: func(_ context.Context, serverName string) error {
			deleted = append(deleted, serverName)
			return nil
		},
		RunnerFor:        func(string) cloud.SupportRunner { return runner },
		DNS:              dns,
		Caddy:            h.caddy,
		SecureStepBudget: secureTestBudget,
		StepReporter:     (&HTTPStepReporter{ControlURL: h.cp.URL, Token: "wtok"}).Report,
	}
	w.SupportProvision = DefaultSupportProvision(seams)

	elapsed := runSupportUnderWatchdog(t, w, 5*time.Second)

	// THE INJECTOR ACTUALLY FIRED, AND ON THE CALL THIS ARM NAMES.
	select {
	case <-dns.entered:
	default:
		t.Fatal("the stalling DNS upsert was NEVER entered — this arm proved nothing")
	}
	if len(runner.steps) != 0 {
		t.Fatalf("the block must be the DNS upsert, not a caddy step; runner saw %d steps", len(runner.steps))
	}
	if elapsed > 3*time.Second {
		t.Fatalf("the chain took %s to go terminal on a %s per-step budget", elapsed, secureTestBudget)
	}

	h.mu.Lock()
	fails, succeeds, steps := append([]string(nil), h.fails...), len(h.succeeds), append([]string(nil), h.steps...)
	h.mu.Unlock()

	if succeeds != 0 {
		t.Fatalf("a stalled secure must never succeed; succeeds=%d", succeeds)
	}
	if len(fails) != 1 || !strings.Contains(fails[0], "the DNS upsert for helper.barkpark.cloud did not return within") {
		t.Fatalf("want ONE fail naming the budgeted DNS upsert, got: %v", fails)
	}
	if !strings.Contains(fails[0], "context deadline exceeded") {
		t.Fatalf("the terminal error must carry the deadline cause, got: %v", fails[0])
	}
	assertSecureFailedReported(t, steps)
	if len(deleted) != 1 || deleted[0] != "support-box-helper" {
		t.Fatalf("the half-born box must be torn down, deleted: %v", deleted)
	}
	// The record was written before the stall — the terminal path must sweep it.
	upserts, deletes := dns.snapshot()
	if len(upserts) != 1 || upserts[0].Name != "helper" {
		t.Fatalf("want the A record written before the stall, got %v", upserts)
	}
	if len(deletes) != 1 || deletes[0] != "helper.barkpark.cloud/A" {
		t.Fatalf("the terminal path must delete the leaked A record, got %v", deletes)
	}
}

// TestSupportSecure_CaddyStepStalls_ReachesTerminalState — arm B. The DNS
// upsert SUCCEEDS (so the record really is in the zone) and a Caddy/TLS step
// never returns. This is the exact live shape: DNS written, then the stall.
func TestSupportSecure_CaddyStepStalls_ReachesTerminalState(t *testing.T) {
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })

	h := newSupportHarness(t)
	base := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	runner := &secureStallRunner{supportFakeRunner: base, entered: make(chan struct{}), release: release}
	var deleted []string
	w := h.worker(base, &deleted)

	dns := &secureStallDNS{entered: make(chan struct{}), release: release} // upsert SUCCEEDS
	seams := SupportSeams{
		CreateServer: func(_ context.Context, name string) (cloud.Server, error) {
			return cloud.Server{Name: "support-box-" + name, IP: "203.0.113.9"}, nil
		},
		DeleteServer: func(_ context.Context, serverName string) error {
			deleted = append(deleted, serverName)
			return nil
		},
		RunnerFor:        func(string) cloud.SupportRunner { return runner },
		DNS:              dns,
		Caddy:            h.caddy,
		SecureStepBudget: secureTestBudget,
		StepReporter:     (&HTTPStepReporter{ControlURL: h.cp.URL, Token: "wtok"}).Report,
	}
	w.SupportProvision = DefaultSupportProvision(seams)

	elapsed := runSupportUnderWatchdog(t, w, 5*time.Second)

	// THE INJECTOR FIRED ON THE CADDY STEP — and the DNS upsert, the OTHER
	// secure call, reached its normal outcome. Opposite outcomes on the two
	// call sites is what makes this arm discriminate.
	select {
	case <-runner.entered:
	default:
		t.Fatal("the stalling caddy step was NEVER entered — this arm proved nothing")
	}
	upserts, deletes := dns.snapshot()
	if len(upserts) != 1 {
		t.Fatalf("the DNS upsert must have COMPLETED in this arm (else the block was elsewhere), got %v", upserts)
	}
	if titles := runner.titles(); len(titles) != 1 || !strings.Contains(titles[0], "fake caddy/TLS step for helper.barkpark.cloud") {
		t.Fatalf("want exactly the first caddy step blocked, got %v", titles)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("the chain took %s to go terminal on a %s per-step budget", elapsed, secureTestBudget)
	}

	h.mu.Lock()
	fails, succeeds, steps := append([]string(nil), h.fails...), len(h.succeeds), append([]string(nil), h.steps...)
	h.mu.Unlock()

	if succeeds != 0 {
		t.Fatalf("a stalled secure must never succeed; succeeds=%d", succeeds)
	}
	// The fail body is JSON, so the step title's quotes arrive escaped — match
	// the pieces, not the rendered quoting.
	if len(fails) != 1 ||
		!strings.Contains(fails[0], `caddy step`) ||
		!strings.Contains(fails[0], `fake caddy/TLS step for helper.barkpark.cloud`) ||
		!strings.Contains(fails[0], `did not return within the 60ms secure-step budget: context deadline exceeded`) {
		t.Fatalf("want ONE fail naming the budgeted caddy step, got: %v", fails)
	}
	assertSecureFailedReported(t, steps)
	if len(deleted) != 1 || deleted[0] != "support-box-helper" {
		t.Fatalf("the half-born box must be torn down, deleted: %v", deleted)
	}
	// THE LEAK CLASS: secure wrote the A record and then stalled. Because the
	// leg is now terminal, failStep's fresh-context teardown sweeps the record
	// the by-value census could never see (no IP is on the CP row).
	if len(deletes) != 1 || deletes[0] != "helper.barkpark.cloud/A" {
		t.Fatalf("the terminal path must delete the A record secure wrote before stalling, got %v", deletes)
	}
}

func assertSecureFailedReported(t *testing.T, steps []string) {
	t.Helper()
	for _, s := range steps {
		if s == "secure/failed" {
			return
		}
	}
	t.Fatalf("secure/failed never reported — no terminal state on the step stream; steps: %v", steps)
}

// TestSupportSeams_SecureStepBudgetDefault pins the named budget: an unset
// SecureStepBudget resolves to DefaultSupportSecureStepBudget, and it stays
// well inside the chain budget it lives under.
func TestSupportSeams_SecureStepBudgetDefault(t *testing.T) {
	got := SupportSeams{DNS: cloud.NewFakeDNS()}.withSupportDefaults()
	if got.SecureStepBudget != DefaultSupportSecureStepBudget {
		t.Fatalf("SecureStepBudget default = %s, want %s", got.SecureStepBudget, DefaultSupportSecureStepBudget)
	}
	if DefaultSupportSecureStepBudget >= DefaultSupportProvisionTimeout {
		t.Fatalf("the per-step budget (%s) must stay under the chain budget (%s)",
			DefaultSupportSecureStepBudget, DefaultSupportProvisionTimeout)
	}
	explicit := SupportSeams{DNS: cloud.NewFakeDNS(), SecureStepBudget: time.Second}.withSupportDefaults()
	if explicit.SecureStepBudget != time.Second {
		t.Fatalf("an explicit budget must be honored, got %s", explicit.SecureStepBudget)
	}
}
