package provisioner

import (
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// specRecordingProvider wraps a FakeProvider and records the ServerSpec of every
// Create — so a test can prove the one-shot path created the box with the PINNED
// region/server_type (the FakeProvider itself does not retain the spec). Embedding
// the *FakeProvider promotes all of its methods (List/IP/Delete plus the label
// and catalog capability interfaces), so the wrapper satisfies exactly the same
// seam interfaces; only Create is overridden to record.
type specRecordingProvider struct {
	*cloud.FakeProvider
	mu      sync.Mutex
	created []cloud.ServerSpec
}

func (p *specRecordingProvider) Create(ctx context.Context, spec cloud.ServerSpec) (cloud.Server, error) {
	p.mu.Lock()
	p.created = append(p.created, spec)
	p.mu.Unlock()
	return p.FakeProvider.Create(ctx, spec)
}

func (p *specRecordingProvider) createdSpecs() []cloud.ServerSpec {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]cloud.ServerSpec(nil), p.created...)
}

// TestWarmSpecCompatible pins the pure pin-guard predicate: an unpinned request
// (both fields empty) or a pin that EQUALS the pool base is pool-compatible; any
// set field that DIFFERS from base is not. Image never participates.
func TestWarmSpecCompatible(t *testing.T) {
	base := cloud.ServerSpec{Region: "nbg1", ServerType: "cx23", Image: "snap-base"}
	for _, tc := range []struct {
		name string
		req  cloud.ServerSpec
		want bool
	}{
		{"unpinned (both empty) is pool-compatible", cloud.ServerSpec{}, true},
		{"pin equal to base is compatible", cloud.ServerSpec{Region: "nbg1", ServerType: "cx23"}, true},
		{"differing region is incompatible", cloud.ServerSpec{Region: "fsn1", ServerType: "cx23"}, false},
		{"differing server_type is incompatible", cloud.ServerSpec{Region: "nbg1", ServerType: "cx32"}, false},
		{"both differing is incompatible", cloud.ServerSpec{Region: "fsn1", ServerType: "cx32"}, false},
		{"only region pinned and equal is compatible", cloud.ServerSpec{Region: "nbg1"}, true},
		{"only server_type pinned and differing is incompatible", cloud.ServerSpec{ServerType: "cx32"}, false},
		{"image alone is ignored (pool-compatible)", cloud.ServerSpec{Image: "snap-whatever"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := warmSpecCompatible(tc.req, base); got != tc.want {
				t.Errorf("warmSpecCompatible(%+v, %+v) = %v, want %v", tc.req, base, got, tc.want)
			}
		})
	}
}

// TestProvisionWith_PinnedDifferingRegionSkipsWarmAssign is the core azh-w3
// contract: a go-live pinned to a region/size the uniform warm pool was NOT baked
// for must NEVER consume a warm box (it would be the wrong region/size) — it falls
// through to a one-shot create that HONORS the pin. Proof is threefold: the ready
// warm row is untouched, a one-shot bp-acme box stands up, and its recorded create
// spec carries the pin.
func TestProvisionWith_PinnedDifferingRegionSkipsWarmAssign(t *testing.T) {
	// Force a deterministic pool base so the pin is unambiguously different
	// regardless of the host's BARKPARK_SERVER_* env.
	t.Setenv("BARKPARK_SERVER_LOCATION", "nbg1")
	t.Setenv("BARKPARK_SERVER_TYPE", "cx23")

	seams, hetznerProv, dns, _ := fakeSeams(t)
	ctx := context.Background()

	// Wrap the provider so we can prove the one-shot create carried the pin.
	rec := &specRecordingProvider{FakeProvider: hetznerProv}
	seams.Provider = rec

	// A genuinely-ready warm box + an ENABLED pool. If the pin were ignored,
	// tryWarmAssign would consume this row and hand back a nbg1/cx23 warm box.
	wc := &fakeWarmClient{}
	warmBox := seedWarmBox(t, ctx, hetznerProv, wc)
	seams.WarmPoolSize = 3
	seams.WarmClient = wc
	seams.WarmRefill = func(context.Context) {} // no-op → no racing create

	// Pin a region + size the pool was not baked for (base is nbg1/cx23).
	job := JobSpec{JobID: "job-pin", Name: "Acme Co", Slug: "acme", Region: "fsn1", ServerType: "cx32"}
	ip, _, _, teardown, err := ProvisionWith(ctx, seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith (pinned-differing): %v", err)
	}
	if ip == "" || teardown == nil {
		t.Fatal("pinned-differing go-live did not produce a live one-shot host")
	}

	// ── the warm box was NEVER claimed (still ready) ──
	if st := wc.statusOf(warmBox.Name); st != "ready" {
		t.Errorf("warm row %q status = %q after a pinned-differing launch, want \"ready\" (the pin must not consume a warm box)", warmBox.Name, st)
	}

	// ── a one-shot bp-acme box stood up, and it carried the PIN ──
	var pinnedCreate *cloud.ServerSpec
	for _, s := range rec.createdSpecs() {
		if strings.HasPrefix(s.Name, "bp-acme-") {
			cp := s
			pinnedCreate = &cp
		}
	}
	if pinnedCreate == nil {
		t.Fatalf("no one-shot bp-acme- create was recorded; creates=%+v", rec.createdSpecs())
	}
	if pinnedCreate.Region != "fsn1" || pinnedCreate.ServerType != "cx32" {
		t.Errorf("one-shot create spec = %s/%s, want the pinned fsn1/cx32", pinnedCreate.Region, pinnedCreate.ServerType)
	}
	// The one-shot completed the shared chain (DNS landed for the instance).
	if v, _ := dns.Resolve(ctx, "acme.barkpark.cloud"); len(v) != 1 || v[0] != ip {
		t.Errorf("DNS for acme = %v, want [%s]", v, ip)
	}
}

// TestProvisionWith_UnpinnedTakesWarmAssign proves the fast path is preserved: an
// UNPINNED hetzner go-live (the post-azh-w3 claim emits empty region/type) still
// takes the ≤15s warm assign. The hetzner branch fills the empties from the pool's
// own warmBaseSpec, so the pin-guard sees a pool-compatible spec.
func TestProvisionWith_UnpinnedTakesWarmAssign(t *testing.T) {
	seams, prov, _, _ := fakeSeams(t)
	wc := &fakeWarmClient{}
	ctx := context.Background()
	box := seedWarmBox(t, ctx, prov, wc)

	seams.WarmPoolSize = 1
	seams.WarmClient = wc
	seams.WarmRefill = func(context.Context) {} // no-op → deterministic

	// Neither region nor server_type pinned — the real unpinned-claim shape.
	job := JobSpec{JobID: "job-unpinned", Name: "Acme Co", Slug: "acme"}
	ip, _, _, _, err := ProvisionWith(ctx, seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith (unpinned warm): %v", err)
	}
	if ip != box.IP {
		t.Errorf("unpinned assigned IP = %q, want the warm box IP %q (unpinned must stay warm)", ip, box.IP)
	}
	for _, h := range mustList(t, prov) {
		if strings.HasPrefix(h.Name, "bp-acme-") {
			t.Errorf("a one-shot box %q was created for an unpinned launch — it should have assigned the warm box", h.Name)
		}
	}
	if wc.statusOf(box.Name) != "" {
		t.Errorf("warm row for %q not consumed after an unpinned assign (status=%q)", box.Name, wc.statusOf(box.Name))
	}
}
