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

// TestRegistryAzureNotRegisteredYet asserts azure is a DECLARED-but-unregistered
// slug (S5 wires it): it is not in RegisteredProviders and resolving it errors.
// This is the tripwire that flips green the moment the azure package self-registers.
func TestRegistryAzureNotRegisteredYet(t *testing.T) {
	for _, s := range RegisteredProviders() {
		if s == ProviderAzure {
			t.Fatalf("azure is registered — this slice must NOT wire it (that is S5); RegisteredProviders=%v", RegisteredProviders())
		}
	}
	if _, err := ProviderFor(ProviderAzure, nil); err == nil {
		t.Errorf("ProviderFor(azure): want an unregistered error until S5, got nil")
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
			actual := DetectCapabilities(p)
			if actual != claimed {
				t.Errorf("capability drift for %q:\n  fixture claims: %+v\n  Go satisfies:   %+v\n"+
					"a claim the impl does not satisfy, or a capability the impl has but the fixture omits, both fail here",
					slug, claimed, actual)
			}
		})
	}
}

// TestFixtureAzurePlaceholderAllFalse asserts the azure row is the honest
// all-false placeholder S2/S5 will flip — so the SPA/CLI render azure as
// "planned", not as a provider with phantom abilities.
func TestFixtureAzurePlaceholderAllFalse(t *testing.T) {
	fixture, err := LoadCapabilities()
	if err != nil {
		t.Fatalf("LoadCapabilities: %v", err)
	}
	az, ok := fixture[ProviderAzure]
	if !ok {
		t.Fatal("fixture is missing the azure placeholder row")
	}
	if (az != Capabilities{}) {
		t.Errorf("azure placeholder must be all-false until S2/S5 flip it; got %+v", az)
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
