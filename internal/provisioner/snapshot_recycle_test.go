package provisioner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"

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
