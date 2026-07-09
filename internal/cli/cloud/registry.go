package cloud

// registry.go is the provider registry — the seam's slug→implementation table
// (charter Decision 3). ProviderFor resolves a provider kind + credentials to a
// CloudProvider; Register wires a slug to a factory. The core seam
// (CloudProvider) and its optional capability interfaces live in provider.go;
// this file is only the lookup and the committed capability fixture that
// declares, per slug, what each provider HONESTLY supports.
//
// A new provider lands as a Register call, not a new switch arm or a fork.

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
)

// Provider slugs the registry knows beyond ProviderHetzner (provider.go). Fake
// is the in-memory provider every provisioning test runs against; Azure is a
// DECLARED slug (it appears in providers_capabilities.json as an all-false
// placeholder) that is NOT registered here yet — see the init() note below.
const (
	ProviderFake  = "fake"
	ProviderAzure = "azure"
)

// ProviderFactory builds a CloudProvider from a provider's credentials (the
// per-kind creds map the control plane's providers row carries — e.g.
// {token:…} for Hetzner, {tenant_id,client_id,client_secret,subscription_id}
// for Azure). A factory may ignore creds when the provider reads auth from the
// environment (HcloudProvider does today). It returns a clear error when the
// creds are unusable.
type ProviderFactory func(creds map[string]string) (CloudProvider, error)

// registry is the slug→factory table, guarded for concurrent use (the worker
// registers at init and resolves from many goroutines).
var registry = struct {
	mu        sync.RWMutex
	factories map[string]ProviderFactory
}{factories: map[string]ProviderFactory{}}

// Register wires a provider slug to its factory. It is idempotent-by-overwrite:
// the last registration for a slug wins (a provider package self-registering in
// its init() replaces any placeholder). Called from init() here for the
// built-in providers and, later, from the azure package's own init().
func Register(slug string, f ProviderFactory) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	registry.factories[slug] = f
}

// ProviderFor resolves a provider kind + creds to a live CloudProvider through
// the registered factory, or a clear error naming the known slugs when the kind
// is unregistered — so a typo or an un-wired provider fails loud, never silent.
func ProviderFor(kind string, creds map[string]string) (CloudProvider, error) {
	registry.mu.RLock()
	f, ok := registry.factories[kind]
	registry.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("cloud: unknown provider %q (known: %s)", kind, strings.Join(RegisteredProviders(), ", "))
	}
	return f(creds)
}

// RegisteredProviders returns the registered slugs, sorted, for help text,
// the `bp cloud providers` matrix, and the parity test. It reports what is
// actually wired — NOT every slug in the fixture (azure is declared there but
// unregistered until S5).
func RegisteredProviders() []string {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	slugs := make([]string, 0, len(registry.factories))
	for s := range registry.factories {
		slugs = append(slugs, s)
	}
	sort.Strings(slugs)
	return slugs
}

func init() {
	// Hetzner — the existing shell-out impl. It reads auth from HCLOUD_TOKEN /
	// an active `hcloud context`, so the creds map is unused today (the native
	// hcloud-go cutover is a later, env-gated slice, Decision 11).
	Register(ProviderHetzner, func(map[string]string) (CloudProvider, error) {
		return HcloudProvider{}, nil
	})
	// Fake — the in-memory provider for tests. All capabilities honoured.
	Register(ProviderFake, func(map[string]string) (CloudProvider, error) {
		return NewFakeProvider(), nil
	})
	// Azure slots in HERE once S2 ships internal/cli/cloud/azure (implementing
	// the CloudProvider + capability interfaces on azure-sdk-for-go) and S5
	// wires it. It is intentionally NOT registered now: registering it here
	// would pull the Azure SDK into every `bp` build and risk an import cycle,
	// so the azure package self-registers via its own init() when imported —
	//
	//     Register(ProviderAzure, azure.Factory)
	//
	// Until then azure is a fixture-declared, all-false placeholder that
	// `bp cloud providers` surfaces as "planned", and the parity test only
	// checks REGISTERED providers.
}

//go:embed providers_capabilities.json
var capabilitiesFixture []byte

// LoadCapabilities decodes the committed providers_capabilities.json fixture —
// the cross-surface capability contract (Decision 8). The map is keyed by
// provider slug; each value is the honest capability row that provider claims
// today. This is the SAME file the Elixir control plane and the SPA read, so
// its shape is an API: change it here and every surface (plus the parity test)
// re-checks in CI.
func LoadCapabilities() (map[string]Capabilities, error) {
	var m map[string]Capabilities
	if err := json.Unmarshal(capabilitiesFixture, &m); err != nil {
		return nil, fmt.Errorf("cloud: decode providers_capabilities.json: %w", err)
	}
	return m, nil
}
