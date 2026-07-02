package cloud

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// warmSpec is the uniform spec a warm-pool box is created from in these tests.
func warmSpec() ServerSpec {
	return ServerSpec{Region: "nbg1", ServerType: "cx23", Image: "snap-123"}
}

// redGate is a HealthChecker that reports NOT ready — drives the AssignWarm
// fail-closed → teardown path.
func redGate(_ context.Context, base, _ string) (setup.HealthReport, error) {
	return setup.HealthReport{
		BaseURL: base,
		OK:      false,
		Checks:  []setup.CheckResult{{Name: "capabilities", Pass: false, Detail: "down (fake)"}},
	}, nil
}

// warmAssignPool wires a WarmPool for the AssignWarm path: a Provider (so the box
// can be labelled/torn down), FakeDNS, a recording runner, FakeRegistry, and the
// supplied health checker. No Pool — AssignWarm operates on an already-acquired host.
func warmAssignPool(health HealthChecker) (*WarmPool, *FakeProvider, *FakeDNS, *recordingRunner, *FakeRegistry) {
	prov := NewFakeProvider()
	dns := NewFakeDNS()
	runner := &recordingRunner{}
	reg := NewFakeRegistry()
	wp := &WarmPool{
		Provider:           prov,
		DNS:                dns,
		Runner:             runner,
		Health:             health,
		Registry:           reg,
		HealthPollInterval: time.Millisecond,
		HealthPollDeadline: 30 * time.Millisecond,
		DeleteRetryBackoff: time.Millisecond,
	}
	return wp, prov, dns, runner, reg
}

func TestCreateWarmServer_UniqueNameAndWarmLabel(t *testing.T) {
	prov := NewFakeProvider()
	ctx := context.Background()

	a, err := CreateWarmServer(ctx, prov, warmSpec())
	if err != nil {
		t.Fatalf("CreateWarmServer: %v", err)
	}
	if !strings.HasPrefix(a.Name, "warm-") {
		t.Errorf("warm name = %q, want a warm-<rand> prefix", a.Name)
	}
	if a.Labels[WarmLabelKey] != warmLabelVal {
		t.Errorf("warm box missing %s=%s label: %+v", WarmLabelKey, warmLabelVal, a.Labels)
	}
	if a.Labels[ManagedLabelKey] != managedLabelVal {
		t.Errorf("warm box missing managed label: %+v", a.Labels)
	}

	b, err := CreateWarmServer(ctx, prov, warmSpec())
	if err != nil {
		t.Fatalf("CreateWarmServer #2: %v", err)
	}
	if a.Name == b.Name {
		t.Errorf("two warm boxes share the name %q — names must be unique (the old warm-1 collision)", a.Name)
	}

	// Both are listable by the warm label.
	warm, _ := prov.ListByLabel(ctx, WarmLabelKey, warmLabelVal)
	if len(warm) != 2 {
		t.Errorf("want 2 warm-labelled boxes, got %d: %+v", len(warm), warm)
	}
}

// failLabelProvider is a CloudProvider whose LabelServer always errors — proves
// CreateWarmServer tears the just-created box down rather than leak an
// unidentifiable billed warm box.
type failLabelProvider struct{ *FakeProvider }

func (failLabelProvider) LabelServer(context.Context, string, string, string) error {
	return fmt.Errorf("label boom")
}

func TestCreateWarmServer_LabelFailureTearsDownBox(t *testing.T) {
	prov := failLabelProvider{NewFakeProvider()}
	ctx := context.Background()

	_, err := CreateWarmServer(ctx, prov, warmSpec())
	if err == nil {
		t.Fatal("CreateWarmServer: want an error when the box cannot be labelled warm")
	}
	// The box was created then deleted — zero leaked spend.
	hosts, _ := prov.List(ctx)
	if len(hosts) != 0 {
		t.Errorf("an unlabelable warm box was leaked: %d hosts remain: %+v", len(hosts), hosts)
	}
}

func TestAssignWarm_HappyPathSkipsCreateAndFlipsLabels(t *testing.T) {
	spec := acmeSpec()
	wp, prov, dns, runner, reg := warmAssignPool(greenGate(spec.healthTarget()))
	ctx := context.Background()

	// A claimed warm box already exists (created + warm-labelled ahead of time).
	host, err := CreateWarmServer(ctx, prov, warmSpec())
	if err != nil {
		t.Fatalf("seed warm box: %v", err)
	}
	beforeCount, _ := prov.List(ctx)

	live, err := wp.AssignWarm(ctx, host, spec)
	if err != nil {
		t.Fatalf("AssignWarm: %v", err)
	}

	// ── NO new server created: the assigned box IS the warm box (same IP) ──
	if live.IP != host.IP {
		t.Errorf("assigned IP = %q, want the warm box's IP %q (no new create)", live.IP, host.IP)
	}
	afterCount, _ := prov.List(ctx)
	if len(afterCount) != len(beforeCount) {
		t.Errorf("host count changed %d→%d — AssignWarm must NOT create a server", len(beforeCount), len(afterCount))
	}

	// ── label transition: barkpark-fqdn stamped, barkpark-warm removed ──
	fq, _ := prov.ListByLabel(ctx, FQDNLabelKey, "acme.barkpark.cloud")
	if len(fq) != 1 {
		t.Errorf("assigned box missing %s=acme.barkpark.cloud label: %+v", FQDNLabelKey, fq)
	}
	stillWarm, _ := prov.ListByLabel(ctx, WarmLabelKey, warmLabelVal)
	if len(stillWarm) != 0 {
		t.Errorf("assigned box still carries %s (should be stripped): %+v", WarmLabelKey, stillWarm)
	}

	// ── the shared chain ran (DNS + migrate + register) ──
	values, _ := dns.Resolve(ctx, "acme.barkpark.cloud")
	if len(values) != 1 || values[0] != host.IP {
		t.Errorf("DNS for acme.barkpark.cloud = %v, want [%s]", values, host.IP)
	}
	if !strings.Contains(runner.joined(), "ecto.migrate") {
		t.Errorf("migrate step did not run in the assign chain; ran:\n%s", runner.joined())
	}
	if !reg.Has("acme.barkpark.cloud") {
		t.Errorf("assigned server was not registered: %+v", reg.Registered())
	}
}

// TestSweepOrphans_LeavesWarmBoxesAlone proves the orphan sweep NEVER touches a
// warm-pool box (requirement: exclude barkpark-warm from the sweep). The sweep is
// allowlist-based — it deletes ONLY barkpark-orphaned=true — so a warm box (managed
// + warm, never orphaned) is left standing while a genuinely-orphaned box is swept.
func TestSweepOrphans_LeavesWarmBoxesAlone(t *testing.T) {
	prov := NewFakeProvider()
	dns := NewFakeDNS()
	ctx := context.Background()

	warm, err := CreateWarmServer(ctx, prov, warmSpec())
	if err != nil {
		t.Fatalf("seed warm box: %v", err)
	}
	// A genuinely-orphaned box (the double-failure path stamped it).
	orphan, _ := prov.Create(ctx, ServerSpec{Name: "bp-orphan-1", Image: "x"})
	_ = prov.LabelServer(ctx, orphan.Name, OrphanedLabelKey, orphanedLabelVal)

	wp := &WarmPool{Provider: prov, DNS: dns}
	swept, err := wp.SweepOrphans(ctx)
	if err != nil {
		t.Fatalf("SweepOrphans: %v", err)
	}
	if swept != 1 {
		t.Errorf("swept = %d, want 1 (only the orphaned box)", swept)
	}
	if _, err := prov.IP(ctx, warm.Name); err != nil {
		t.Errorf("the warm box %q was swept — it must be excluded: %v", warm.Name, err)
	}
	if _, err := prov.IP(ctx, orphan.Name); err == nil {
		t.Errorf("the orphaned box %q should have been swept", orphan.Name)
	}
}

func TestAssignWarm_HealthFailureTearsDownBoxAndDNS(t *testing.T) {
	spec := acmeSpec()
	wp, prov, dns, _, reg := warmAssignPool(redGate)
	ctx := context.Background()

	host, err := CreateWarmServer(ctx, prov, warmSpec())
	if err != nil {
		t.Fatalf("seed warm box: %v", err)
	}

	_, err = wp.AssignWarm(ctx, host, spec)
	if err == nil {
		t.Fatal("AssignWarm: want a fail-closed error when the health gate is red")
	}

	// The box + its DNS record were torn down — no orphan, so the caller can fall
	// back to one-shot cleanly.
	hosts, _ := prov.List(ctx)
	if len(hosts) != 0 {
		t.Errorf("failed assign left %d box(es) — want 0 (torn down): %+v", len(hosts), hosts)
	}
	values, _ := dns.Resolve(ctx, "acme.barkpark.cloud")
	if len(values) != 0 {
		t.Errorf("failed assign left DNS records: %v", values)
	}
	if reg.Has("acme.barkpark.cloud") {
		t.Errorf("a failed assign must NOT register the server")
	}
}
