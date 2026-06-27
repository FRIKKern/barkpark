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
	Runner   cloud.StepRunner    // nil → the real shell-out runner
	Secrets  cloud.SecretGen     // nil → the real secret-gen
}

// ProvisionWith builds a one-shot WarmPool from seams and runs the cloud-6
// assign→live chain for one job, returning the live host IP. KEEP IT SIMPLE: a
// fresh per-job warm pool seeded with exactly one host (SeedPool over the
// injected provider) — a go-live pops that host, the chain provisions it, and
// the pool's self-refill creates the (single) replacement. No long-lived pool,
// no concurrency: one job at a time (YAGNI, per the worker contract).
//
// region/server_type come from the job (the Elixir side already defaulted them
// to nbg1/cax11); name/slug name the instance. The base ServerSpec seeds the
// pool AND is reused for the replacement create.
func ProvisionWith(ctx context.Context, seams Seams, job JobSpec) (string, error) {
	if seams.Provider == nil {
		return "", fmt.Errorf("provisioner: a CloudProvider must be set")
	}

	base := cloud.ServerSpec{
		Region:     job.Region,
		ServerType: job.ServerType,
		Image:      "ubuntu-22.04",
	}

	pool, err := cloud.SeedPool(ctx, seams.Provider, 1, base)
	if err != nil {
		return "", fmt.Errorf("seed warm pool for %q: %w", job.Name, err)
	}

	wp := &cloud.WarmPool{
		Pool:     pool,
		DNS:      seams.DNS,
		Registry: seams.Registry,
		Health:   seams.Health,
		Caddy:    seams.Caddy,
		Runner:   seams.Runner,
		Secrets:  seams.Secrets,
	}

	// The instance label is the slug when present (DNS-safe), else the name.
	label := job.Slug
	if label == "" {
		label = job.Name
	}

	live, err := wp.Provision(ctx, cloud.GoLiveSpec{
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
