package provisioner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// TestMain makes the WHOLE provisioner package hermetic against the dynamic
// warm-image resolution (snapshot-management): the default listers shell out to
// `hcloud`, which must never happen in a test — on a dev box with a real token
// it would hit the live API. Every test runs with erroring listers (resolution
// falls back to the env image and the recycle phase skips, byte-for-byte the
// pre-feature behavior); the recycle tests below install fixtures explicitly.
func TestMain(m *testing.M) {
	cloud.WarmImageLister = func(context.Context) (string, error) {
		return "", errors.New("no hcloud in tests")
	}
	cloud.WarmServerImageLister = func(context.Context) (string, error) {
		return "", errors.New("no hcloud in tests")
	}
	cloud.ResetWarmImageCache()
	os.Exit(m.Run())
}

// installGenerationFixtures points the resolve + listing seams at fixtures:
// `imageID` is the newest baked snapshot, `serverImages` maps warm box name →
// the image it was created from. Restores the hermetic defaults on cleanup.
func installGenerationFixtures(t *testing.T, imageID string, serverImages map[string]string) {
	t.Helper()
	cloud.ResetWarmImageCache()
	cloud.WarmImageLister = func(context.Context) (string, error) {
		return fmt.Sprintf(`[{"id": %s, "status": "available", "created": "2026-07-06T03:30:00Z"}]`, imageID), nil
	}
	cloud.WarmServerImageLister = func(context.Context) (string, error) {
		var entries []string
		for name, img := range serverImages {
			entries = append(entries, fmt.Sprintf(`{"name": %q, "image": {"id": %s}}`, name, img))
		}
		return "[" + strings.Join(entries, ",") + "]", nil
	}
	t.Cleanup(func() {
		cloud.WarmImageLister = func(context.Context) (string, error) {
			return "", errors.New("no hcloud in tests")
		}
		cloud.WarmServerImageLister = func(context.Context) (string, error) {
			return "", errors.New("no hcloud in tests")
		}
		cloud.ResetWarmImageCache()
	})
}

// poolNames lists the fake provider's live warm boxes.
func poolNames(t *testing.T, prov *cloud.FakeProvider) []string {
	t.Helper()
	warm, err := prov.ListByLabel(context.Background(), cloud.WarmLabelKey, "true")
	if err != nil {
		t.Fatalf("ListByLabel: %v", err)
	}
	names := make([]string, 0, len(warm))
	for _, s := range warm {
		names = append(names, s.Name)
	}
	return names
}

func TestReconcileWarmPool_RecyclesStaleGenerationOnePerPass(t *testing.T) {
	seams, prov, _, _ := fakeSeams(t)
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	// Seed a settled pool of 2.
	if _, _, err := ReconcileWarmPoolWith(ctx, seams, 2); err != nil {
		t.Fatalf("seed grow: %v", err)
	}
	seeded := poolNames(t, prov)
	if len(seeded) != 2 {
		t.Fatalf("seeded pool = %v, want 2 boxes", seeded)
	}

	// Both boxes were created from image 100; a fresh bake published image 999.
	installGenerationFixtures(t, "999", map[string]string{
		seeded[0]: "100",
		seeded[1]: "100",
	})

	created, deleted, err := ReconcileWarmPoolWith(ctx, seams, 2)
	if err != nil {
		t.Fatalf("recycle pass: %v", err)
	}
	if created != 1 || deleted != 1 {
		t.Errorf("recycle pass: created=%d deleted=%d, want 1/1 (ONE box per pass)", created, deleted)
	}
	if got, _ := wc.CountReady(ctx); got != 2 {
		t.Errorf("pool size after recycle = %d, want 2 (retire + immediate replacement)", got)
	}
	// Exactly one of the seeded boxes was replaced by a new create.
	after := poolNames(t, prov)
	if len(after) != 2 {
		t.Fatalf("provider boxes after recycle = %v, want 2", after)
	}
	kept := 0
	for _, n := range after {
		if n == seeded[0] || n == seeded[1] {
			kept++
		}
	}
	if kept != 1 {
		t.Errorf("want exactly 1 seeded box kept this pass (gradual rollover), got %d of %v", kept, after)
	}
}

func TestReconcileWarmPool_NoRecycleWhenPoolIsCurrent(t *testing.T) {
	seams, prov, _, _ := fakeSeams(t)
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	if _, _, err := ReconcileWarmPoolWith(ctx, seams, 2); err != nil {
		t.Fatalf("seed grow: %v", err)
	}
	seeded := poolNames(t, prov)

	// Every box already runs the newest image → the pass is a no-op.
	installGenerationFixtures(t, "999", map[string]string{
		seeded[0]: "999",
		seeded[1]: "999",
	})

	created, deleted, err := ReconcileWarmPoolWith(ctx, seams, 2)
	if err != nil {
		t.Fatalf("settled pass: %v", err)
	}
	if created != 0 || deleted != 0 {
		t.Errorf("settled pass: created=%d deleted=%d, want 0/0", created, deleted)
	}
}

func TestReconcileWarmPool_RecycleSkipsWhenGenerationUnknown(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	if _, _, err := ReconcileWarmPoolWith(ctx, seams, 2); err != nil {
		t.Fatalf("seed grow: %v", err)
	}

	// Default hermetic listers: no labeled bake resolvable, listing errors.
	// Recycling must SKIP silently — never invent work on uncertain data, and
	// never fail the reconcile.
	created, deleted, err := ReconcileWarmPoolWith(ctx, seams, 2)
	if err != nil {
		t.Fatalf("unknown-generation pass must not error: %v", err)
	}
	if created != 0 || deleted != 0 {
		t.Errorf("unknown-generation pass: created=%d deleted=%d, want 0/0", created, deleted)
	}
}

func TestReconcileWarmPool_RecycleSkipsOnServerListingError(t *testing.T) {
	seams, prov, _, _ := fakeSeams(t)
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	if _, _, err := ReconcileWarmPoolWith(ctx, seams, 1); err != nil {
		t.Fatalf("seed grow: %v", err)
	}
	_ = poolNames(t, prov)

	// A resolvable bake but a failed server listing → skip, no error, no churn.
	installGenerationFixtures(t, "999", nil)
	cloud.WarmServerImageLister = func(context.Context) (string, error) {
		return "", errors.New("hcloud flake")
	}

	created, deleted, err := ReconcileWarmPoolWith(ctx, seams, 1)
	if err != nil {
		t.Fatalf("listing-error pass must not error: %v", err)
	}
	if created != 0 || deleted != 0 {
		t.Errorf("listing-error pass: created=%d deleted=%d, want 0/0", created, deleted)
	}
}

// ctxSensitiveProvider fails Delete when the PASSED context is already dead —
// modelling the real hcloud shell-out, which the in-memory FakeProvider ignores.
// The regression seam for the warm-dbebde03 leak: a teardown that inherits a
// dying caller ctx (worker shutdown mid-grow) must still complete, because an
// unregistered warm box has no other recovery path.
type ctxSensitiveProvider struct {
	cloud.CloudProvider
}

func (p ctxSensitiveProvider) Delete(ctx context.Context, name string) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("hcloud server delete %q: %w", name, err)
	}
	return p.CloudProvider.Delete(ctx, name)
}

func TestGrowWarmBox_TeardownSurvivesDyingContext(t *testing.T) {
	seams, prov, _, runner := fakeSeams(t)
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	seams.Provider = ctxSensitiveProvider{CloudProvider: prov}
	// The freshen fails (any reason) AND the caller's ctx is already cancelled —
	// the worker-shutdown-mid-grow shape that leaked warm-dbebde03.
	runner.checkErr = fmt.Errorf("git fetch: interrupted by shutdown")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if err := growWarmBox(ctx, seams); err == nil {
		t.Fatal("growWarmBox must report the freshen failure")
	}

	// The teardown ran on a FRESH context, so the box is GONE despite the dead
	// caller ctx — no silent, unbounded spend.
	warm, _ := prov.ListByLabel(context.Background(), cloud.WarmLabelKey, "true")
	if len(warm) != 0 {
		t.Errorf("box leaked through a dying-ctx teardown: %d warm boxes remain", len(warm))
	}
	if got, _ := wc.CountReady(context.Background()); got != 0 {
		t.Errorf("a failed grow registered a row: %d", got)
	}
}

// ── Self-refresh loop (snapshot-management: keep idle pool boxes current) ──────

// TestRefreshOneStalePoolBox_HappyPathReturnsBoxToReady proves the self-refresh
// runner claims the stalest ready box, freshens it, and RELEASES it back to ready
// with refreshed=true — the box never leaves the pool.
func TestRefreshOneStalePoolBox_HappyPathReturnsBoxToReady(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	wc := &fakeWarmClient{rows: []fakeWarmRow{{name: "warm-a", ip: "10.0.0.1", status: "ready"}}}
	seams.WarmClient = wc

	refreshOneStalePoolBox(context.Background(), seams)

	if got := wc.statusOf("warm-a"); got != "ready" {
		t.Errorf("box status after refresh = %q, want ready (returned to the pool)", got)
	}
	if len(wc.refreshClaims) != 1 || wc.refreshClaims[0] != "warm-a" {
		t.Errorf("refresh claims = %v, want [warm-a]", wc.refreshClaims)
	}
	if len(wc.markRefreshedCalls) != 1 || !wc.markRefreshedCalls[0].refreshed {
		t.Errorf("markRefreshed calls = %v, want one with refreshed=true", wc.markRefreshedCalls)
	}
}

// TestRefreshOneStalePoolBox_FreshenFailureIsFailOpen proves a freshen failure
// does NOT tear the box down (unlike grow) — it returns to ready with
// refreshed=false (retry sooner), still serving working code.
func TestRefreshOneStalePoolBox_FreshenFailureIsFailOpen(t *testing.T) {
	seams, _, _, runner := fakeSeams(t)
	runner.checkErr = fmt.Errorf("git fetch: transient network")
	wc := &fakeWarmClient{rows: []fakeWarmRow{{name: "warm-a", ip: "10.0.0.1", status: "ready"}}}
	seams.WarmClient = wc

	refreshOneStalePoolBox(context.Background(), seams)

	if got := wc.statusOf("warm-a"); got != "ready" {
		t.Errorf("a failed refresh must return the box to ready (fail-open), got %q", got)
	}
	if len(wc.markRefreshedCalls) != 1 || wc.markRefreshedCalls[0].refreshed {
		t.Errorf("a failed refresh must release with refreshed=false; got %v", wc.markRefreshedCalls)
	}
}

// TestRefreshOneStalePoolBox_NothingDueIsANoOp proves the runner is a no-op when
// no box is due (all already refreshed) — no freshen, no release.
func TestRefreshOneStalePoolBox_NothingDueIsANoOp(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	wc := &fakeWarmClient{rows: []fakeWarmRow{{name: "warm-a", ip: "10.0.0.1", status: "ready", refreshed: true}}}
	seams.WarmClient = wc

	refreshOneStalePoolBox(context.Background(), seams)

	if len(wc.refreshClaims) != 0 || len(wc.markRefreshedCalls) != 0 {
		t.Errorf("nothing-due refresh must be a no-op; claims=%v marks=%v", wc.refreshClaims, wc.markRefreshedCalls)
	}
}

// TestDefaultRefresh_OneInFlight proves DefaultRefresh runs at most one refresh at
// a time — a second call while one is running is skipped (the guard that keeps the
// single-threaded worker from stacking rebuilds).
func TestDefaultRefresh_OneInFlight(t *testing.T) {
	seams, _, _, runner := fakeSeams(t)
	// A blocking runner so the first refresh is still "in flight" when the second
	// DefaultRefresh call lands.
	release := make(chan struct{})
	runner.checkGate = release
	wc := &fakeWarmClient{rows: []fakeWarmRow{
		{name: "warm-a", ip: "10.0.0.1", status: "ready"},
		{name: "warm-b", ip: "10.0.0.2", status: "ready"},
	}}
	seams.WarmClient = wc

	refresh := DefaultRefresh(seams)
	refresh(context.Background()) // launches an async refresh, blocks in freshen
	// Give the goroutine a moment to claim + block.
	waitFor(t, func() bool { return len(wc.claimsSnapshot()) == 1 }, time.Second)
	refresh(context.Background()) // should be skipped (one in flight)
	// Still exactly one claim.
	if n := len(wc.claimsSnapshot()); n != 1 {
		t.Errorf("second DefaultRefresh call must be skipped while one is in flight; claims=%d", n)
	}
	close(release) // let the first finish
	waitFor(t, func() bool { return len(wc.marksSnapshot()) == 1 }, 2*time.Second)
}

func (f *fakeWarmClient) claimsSnapshot() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.refreshClaims...)
}

func (f *fakeWarmClient) marksSnapshot() []markRefreshedCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]markRefreshedCall(nil), f.markRefreshedCalls...)
}

func waitFor(t *testing.T, cond func() bool, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("condition not met within timeout")
}
