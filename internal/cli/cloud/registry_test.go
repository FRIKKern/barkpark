package cloud

import (
	"strings"
	"testing"
)

// TestRegistryResolvesKnownProviders asserts the registry wires the built-in
// slugs to real implementations: hetzner → HcloudProvider, fake → *FakeProvider,
// each a usable CloudProvider.
func TestRegistryResolvesKnownProviders(t *testing.T) {
	for _, slug := range []string{ProviderHetzner, ProviderFake} {
		p, err := ProviderFor(slug, nil)
		if err != nil {
			t.Fatalf("ProviderFor(%q): %v", slug, err)
		}
		if p == nil {
			t.Fatalf("ProviderFor(%q) returned a nil provider", slug)
		}
	}
	if _, ok := mustProvider(t, ProviderHetzner).(HcloudProvider); !ok {
		t.Errorf("hetzner factory did not yield an HcloudProvider")
	}
	if _, ok := mustProvider(t, ProviderFake).(*FakeProvider); !ok {
		t.Errorf("fake factory did not yield a *FakeProvider")
	}
}

// TestRegistryUnknownProviderErrors asserts an unregistered kind fails loud with
// a clear error that names the known slugs — never a silent nil.
func TestRegistryUnknownProviderErrors(t *testing.T) {
	p, err := ProviderFor("gcp", nil)
	if err == nil {
		t.Fatal("ProviderFor(unknown): want an error, got nil")
	}
	if p != nil {
		t.Errorf("ProviderFor(unknown): want a nil provider, got %#v", p)
	}
	if !strings.Contains(err.Error(), "gcp") || !strings.Contains(err.Error(), ProviderHetzner) {
		t.Errorf("error should name the bad kind AND the known slugs; got: %v", err)
	}
}

// TestRegistryAzureUnregisteredInThisPackage asserts azure is NOT registered in
// the cloud package's OWN test binary. That is not a regression — azure lives in
// internal/cli/cloud/azure, which imports THIS package to implement the seam, so
// this package can never import it back (an import cycle). Azure self-registers
// via its own init() when its package is linked into a binary — the `bp` CLI
// links it (proven by the cli-package wiring test), but the cloud test binary
// does not, so azure stays absent here. This keeps the seam a fork-free
// implementation point rather than a hard-wired switch.
func TestRegistryAzureUnregisteredInThisPackage(t *testing.T) {
	for _, s := range RegisteredProviders() {
		if s == ProviderAzure {
			t.Fatalf("azure is registered in the cloud test binary — it must self-register only where its package is imported (the cli binary); RegisteredProviders=%v", RegisteredProviders())
		}
	}
	if _, err := ProviderFor(ProviderAzure, nil); err == nil {
		t.Errorf("ProviderFor(azure) in the cloud package: want an unregistered error (azure package not linked here), got nil")
	}
}

// TestCapabilityFixtureParity is the cross-surface contract's Go enforcement:
// for EVERY registered provider, its fixture row must match the capabilities it
// ACTUALLY satisfies (via Go type assertions). A claimed-but-unimplemented
// capability fails here; an implemented-but-unclaimed one fails here too — so
// the fixture the Elixir/SPA sides read can never lie about the Go seam.
func TestCapabilityFixtureParity(t *testing.T) {
	fixture, err := LoadCapabilities()
	if err != nil {
		t.Fatalf("LoadCapabilities: %v", err)
	}

	registered := RegisteredProviders()
	if len(registered) == 0 {
		t.Fatal("no providers registered — the registry init() did not run")
	}

	for _, slug := range registered {
		t.Run(slug, func(t *testing.T) {
			claimed, ok := fixture[slug]
			if !ok {
				t.Fatalf("registered provider %q has NO row in providers_capabilities.json — add its honest capability row", slug)
			}
			p, err := ProviderFor(slug, nil)
			if err != nil {
				t.Fatalf("ProviderFor(%q): %v", slug, err)
			}
			actual := DetectCapabilities(slug, p)
			// Compare ONLY the embedded Capabilities — Tier is go-to-market metadata
			// the seam does not (and cannot) satisfy through an interface.
			if actual != claimed.Capabilities {
				t.Errorf("capability drift for %q:\n  fixture claims: %+v\n  Go satisfies:   %+v\n"+
					"a claim the impl does not satisfy, or a capability the impl has but the fixture omits, both fail here",
					slug, claimed.Capabilities, actual)
			}
		})
	}
}

// TestFixtureAzureRowHonest asserts the azure fixture row is the HONEST S14 shape:
// core + labels + pause + decommission + audit + RESURRECT on, but archive + adopt
// still OFF. Portable archives (charter Decision 12) make Azure a valid resurrect
// TARGET — a bundle (archived on Hetzner or Azure) is restored onto a fresh Azure
// box — so azure resurrect flips true (backed by the cli-package dispatch entry
// registered via RegisterLifecycleVerbs). Azure still cannot ARCHIVE (no snapshot
// substrate; S14b owns that flip) nor ADOPT (clone-swap needs a snapshot), so those
// stay false. The live azure-vs-fixture parity is proven in the cli package where
// the azure package + its verb registration are linked; here we only pin the
// committed claim so a drift in the JSON is caught.
func TestFixtureAzureRowHonest(t *testing.T) {
	fixture, err := LoadCapabilities()
	if err != nil {
		t.Fatalf("LoadCapabilities: %v", err)
	}
	az, ok := fixture[ProviderAzure]
	if !ok {
		t.Fatal("fixture is missing the azure row")
	}
	want := Capabilities{Core: true, Labels: true, Pause: true, Decommission: true, Audit: true, Resurrect: true}
	if az.Capabilities != want {
		t.Errorf("azure fixture row drifted:\n  got:  %+v\n  want: %+v\n(core/labels/pause/decommission/audit/resurrect on; catalog/archive/adopt off)", az.Capabilities, want)
	}
	if az.Tier != "" {
		t.Errorf("azure is a shippable provider, not dev-tier; got tier=%q", az.Tier)
	}
}

// TestFixtureFakeIsDevTier asserts the fake row carries tier=dev — the signal
// `bp cloud providers` uses to hide it from the default operator matrix.
func TestFixtureFakeIsDevTier(t *testing.T) {
	fixture, err := LoadCapabilities()
	if err != nil {
		t.Fatalf("LoadCapabilities: %v", err)
	}
	if fixture[ProviderFake].Tier != "dev" {
		t.Errorf("fake must be tier=dev so the default matrix hides it; got %q", fixture[ProviderFake].Tier)
	}
	if fixture[ProviderHetzner].Tier != "" {
		t.Errorf("hetzner is a shippable provider, not dev-tier; got %q", fixture[ProviderHetzner].Tier)
	}
}

func mustProvider(t *testing.T, slug string) CloudProvider {
	t.Helper()
	p, err := ProviderFor(slug, nil)
	if err != nil {
		t.Fatalf("ProviderFor(%q): %v", slug, err)
	}
	return p
}
