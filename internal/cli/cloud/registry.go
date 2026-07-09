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
// real provider (internal/cli/cloud/azure) that self-registers via its own
// init() when its package is linked — see the init() note below.
const (
	ProviderFake  = "fake"
	ProviderAzure = "azure"
)

// The fleet-lifecycle facet verbs (charter Decision 20). They name both the
// `bp cloud instance <verb>` surface and the per-slug capability the fixture
// claims, so one vocabulary spans the CLI dispatch, the seam registration, and
// the honest-degradation matrix.
const (
	VerbArchive      = "archive"
	VerbResurrect    = "resurrect"
	VerbDecommission = "decommission"
	VerbAdopt        = "adopt"
	VerbAudit        = "audit"
)

// HetznerLifecycleVerbs is the canonical set of fleet-lifecycle facets the
// hetzner CLI implements as free functions (internal/cli/hetzner_instance_cmd.go),
// NOT as methods on the credential-less HcloudProvider struct — so
// DetectCapabilities can only learn them through RegisterLifecycleVerbs, the
// second detection source (Decision 21). The cloud package registers this set in
// init() so its own test binary (which never links the cli package) sees the
// honest hetzner truth for the parity test; the cli package re-registers the
// identical set derived from its dispatch table (a cli test pins the two equal),
// so a claim can only be satisfied by a real dispatch entry.
var HetznerLifecycleVerbs = []string{VerbArchive, VerbResurrect, VerbDecommission, VerbAdopt, VerbAudit}

// lifecycleVerbs is the second capability-detection source: kind → the set of
// lifecycle verbs that kind dispatches at the CLI level. Guarded for concurrent
// use like the factory registry.
var lifecycleVerbs = struct {
	mu sync.RWMutex
	m  map[string]map[string]bool
}{m: map[string]map[string]bool{}}

// RegisterLifecycleVerbs records that provider `kind` honours `verbs`
// (archive/resurrect/decommission/adopt/audit) at the CLI-dispatch level —
// exactly the facets DetectCapabilities cannot learn from the provider struct
// because hetzner/azure implement their lifecycle in free/CLI-level functions.
// Idempotent-by-union: repeated calls merge, so the cloud-package baseline and
// the cli-package dispatch-derived registration coexist without clobbering.
func RegisterLifecycleVerbs(kind string, verbs ...string) {
	lifecycleVerbs.mu.Lock()
	defer lifecycleVerbs.mu.Unlock()
	set := lifecycleVerbs.m[kind]
	if set == nil {
		set = map[string]bool{}
		lifecycleVerbs.m[kind] = set
	}
	for _, v := range verbs {
		set[v] = true
	}
}

// lifecycleVerbRegistered reports whether kind registered verb — the OR side of
// DetectCapabilities' two-source facet merge.
func lifecycleVerbRegistered(kind, verb string) bool {
	lifecycleVerbs.mu.RLock()
	defer lifecycleVerbs.mu.RUnlock()
	return lifecycleVerbs.m[kind][verb]
}

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
	// Fake — the in-memory provider for tests. All capabilities honoured. It is
	// dev-tier (providers_capabilities.json marks it tier=dev), so `bp cloud
	// providers` hides it from the default matrix (a real operator never picks
	// the fake) — `--all` reveals it.
	Register(ProviderFake, func(map[string]string) (CloudProvider, error) {
		return NewFakeProvider(), nil
	})
	// Hetzner's fleet-lifecycle facets live in free CLI functions, not on the
	// HcloudProvider struct, so they can only reach DetectCapabilities through this
	// registration (Decision 21). Registered here — not only from the cli package's
	// dispatch table — so the cloud package's OWN test binary (which never links
	// cli) still sees hetzner's honest all-true lifecycle for the parity test.
	RegisterLifecycleVerbs(ProviderHetzner, HetznerLifecycleVerbs...)
	// Azure is NOT registered here — registering it in this package would pull
	// the Azure SDK into every `bp` build and, worse, create an import cycle
	// (the azure package imports THIS package to implement the seam). Instead
	// the azure package self-registers in its OWN init():
	//
	//     func init() { cloud.Register(cloud.ProviderAzure, Factory) }
	//
	// so the registry is populated whenever the azure package is linked into a
	// binary (the `bp` CLI imports it; the cloud package's own test binary does
	// NOT, so azure stays unregistered here — see TestRegistryAzureWiredByImport).
}

//go:embed providers_capabilities.json
var capabilitiesFixture []byte

// ProviderRow is one entry of the providers_capabilities.json fixture: a
// provider's honest capability set PLUS its go-to-market Tier (charter
// Decision 16). Capabilities is EMBEDDED — its json fields (core/catalog/…) are
// promoted, so a fixture row is one flat object `{"tier":"dev","core":true,…}`
// and the parity test compares row.Capabilities against the provider's ACTUAL
// interface-OR-registration satisfaction while Tier rides alongside untouched.
//
// Tier is deliberately a field on THIS wrapper and NOT on Capabilities: putting
// it on Capabilities would red the parity test (DetectCapabilities can't report
// a tier), and a bare fixture key with no struct field is silently dropped by
// the plain unmarshal — the wrapper is the only shape that carries tier without
// lying about capabilities. Tier is "" for the shippable providers and "dev" for
// the in-memory fake, which `bp cloud providers` hides unless `--all` is passed.
type ProviderRow struct {
	Tier         string `json:"tier,omitempty"`
	Capabilities        // embedded: core/catalog/archive/…/pause/labels promote to the row
}

// LoadCapabilities decodes the committed providers_capabilities.json fixture —
// the cross-surface capability contract (Decision 8). The map is keyed by
// provider slug; each value is the honest capability row (+ tier) that provider
// claims today. This file is the CANONICAL Go source of that contract; the Elixir
// control plane and the SPA consume a byte-COPY kept in lockstep by a byte-drift
// gate (charter Decision 22), so its shape is an API: change it here and the
// drift gate forces every surface (plus the parity test) to re-check in CI.
func LoadCapabilities() (map[string]ProviderRow, error) {
	var m map[string]ProviderRow
	if err := json.Unmarshal(capabilitiesFixture, &m); err != nil {
		return nil, fmt.Errorf("cloud: decode providers_capabilities.json: %w", err)
	}
	return m, nil
}
