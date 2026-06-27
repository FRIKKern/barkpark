package provisioner

import (
	"context"
	"fmt"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// Zone is the apex every managed Barkpark hangs under: <slug>.barkpark.cloud.
// The control plane stores only the per-instance slug; the worker pins the zone.
const Zone = "barkpark.cloud"

// AppPort is the local port Phoenix listens on, on each provisioned host (the
// same 4000 the warm-pool Caddy steps front with TLS).
const AppPort = 4000

// Seams bundles the cloud-package injectables a Provision needs. In production
// main() fills it with the REAL Hetzner provider/DNS + a green-by-real-gate; in
// tests it is filled with the FAKES (FakeProvider/FakeDNS/recording runner/
// greenGate/FakeRegistry) so NO real cloud is touched. Leaving a field nil lets
// WarmPool.withDefaults pick its default (real Caddy stepper/runner/secret-gen),
// except Provider/DNS/Registry/Health which have no safe default and MUST be set.
type Seams struct {
	Provider cloud.CloudProvider
	DNS      cloud.DNSProvider
	Registry cloud.RegistryClient
	Health   cloud.HealthChecker // nil → the real health gate
	Caddy    cloud.CaddyStepper  // nil → the canonical setup.CaddySteps
	// RunnerFor builds the StepRunner for an assigned host's IP. nil → the cloud
	// package's default per-host SSH runner factory (NewSSHStepRunner), which runs
	// the Caddy/TLS + migrate steps ON the provisioned instance over SSH. Tests
	// inject a factory returning a recording runner; production leaves it nil.
	RunnerFor func(host string) cloud.StepRunner
	// Runner is the LEGACY host-agnostic runner seam, kept for back-compat. When
	// set and RunnerFor is nil, the cloud package wraps it in a host-ignoring
	// factory. New wiring should use RunnerFor.
	Runner  cloud.StepRunner
	Secrets cloud.SecretGen // nil → the real secret-gen
}

// ProvisionWith runs the cloud-6 create→live chain for ONE job and returns the
// live host IP. It is a ONE-SHOT create-then-provision, NOT a warm-pool pop:
// each job creates exactly ONE server with a globally-unique NAME
// (bp-<sanitized slug>-<crypto/rand suffix> — the suffix makes the name globally
// unique even when two teams share a slug), provisions it through the chain (dns
// → caddy/TLS → migrate → admin-token → health → register), and — on ANY failure
// after the server exists — tears the server + DNS A record down so no orphan is
// billed.
//
// Why not a per-job warm pool? A pool seeded fresh per job names hosts warm-1,
// warm-2, … starting at warm-1 EVERY time, so job #2 re-creates warm-1 and
// Hetzner rejects the duplicate name; and the pool's self-refill creates a
// replacement that nothing ever cleans up (a leaked paid server per job). The
// warm-pool-for-instant-servers code (WarmPool.Provision + Pool) remains for a
// future long-lived pool, but it is NOT on this per-job path.
//
// region/server_type come from the job (the Elixir side already defaulted them
// to nbg1/cax11); slug/name name the instance subdomain.
//
// SCOPE NOTE: only the SERVER NAME is made globally unique here. The DNS FQDN
// (<slug>.barkpark.cloud) is still only per-team-unique — see the
// TODO(multi-tenant) note at the DNS step in WarmPool.configureHost; the control
// plane must allocate globally-unique subdomains before a 2nd customer.
func ProvisionWith(ctx context.Context, seams Seams, job JobSpec) (string, error) {
	if seams.Provider == nil {
		return "", fmt.Errorf("provisioner: a CloudProvider must be set")
	}

	base := cloud.ServerSpec{
		Region:     job.Region,
		ServerType: job.ServerType,
		// Image resolves via DefaultSpec so BARKPARK_SERVER_IMAGE points instances
		// at the baked warm-pool snapshot (Barkpark pre-installed); without it,
		// falls back to bare ubuntu-22.04.
		Image: cloud.DefaultSpec(cloud.ProviderHetzner).Image,
	}

	wp := &cloud.WarmPool{
		Provider:  seams.Provider,
		DNS:       seams.DNS,
		Registry:  seams.Registry,
		Health:    seams.Health,
		Caddy:     seams.Caddy,
		RunnerFor: seams.RunnerFor,
		Runner:    seams.Runner,
		Secrets:   seams.Secrets,
	}

	// The instance label is the slug when present (DNS-safe), else the name.
	label := job.Slug
	if label == "" {
		label = job.Name
	}

	live, err := wp.ProvisionOneShot(ctx, cloud.GoLiveSpec{
		Name: label,
		Zone: Zone,
		App:  AppPort,
		Spec: base,
	})
	if err != nil {
		return "", err
	}
	return live.IP, nil
}

// DefaultProvision returns a ProvisionFunc bound to seams — the value the Worker
// calls per job. It is the bridge between the transport-only Worker and the
// cloud-package chain: tests bind it to the fakes, main() binds it to the real
// providers.
func DefaultProvision(seams Seams) ProvisionFunc {
	return func(ctx context.Context, job JobSpec) (string, error) {
		return ProvisionWith(ctx, seams, job)
	}
}

// NopRegistry satisfies cloud.RegistryClient as an in-chain no-op. The
// AUTHORITATIVE registration is the worker's HTTP POST .../:id/succeed back to
// the Elixir control plane (which runs Registry.upsert_health → barkpark "up").
// The cloud-6 chain still requires a non-nil RegistryClient, so production wires
// this no-op rather than a second, divergent source of truth.
type NopRegistry struct{}

// Register does nothing — registration is the control plane's job via /succeed.
func (NopRegistry) Register(context.Context, cloud.LiveServer) error { return nil }

var _ cloud.RegistryClient = NopRegistry{}
