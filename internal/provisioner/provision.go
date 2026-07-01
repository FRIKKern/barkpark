package provisioner

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/FRIKKern/barkpark/internal/bootstrap"
	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/provisioner/catalog"
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

	// HealthPollInterval / HealthPollDeadline tune the bounded health-gate poll the
	// chain runs after configuring a box (cloud F2). Production leaves both ZERO so
	// the cloud package picks its defaults (~10s interval, ~4m deadline) — generous
	// enough to ride out the cold-provision window where DNS has not propagated and
	// Caddy has not yet obtained the ACME cert. Tests set tiny values so the
	// retry-then-succeed / fail-closed paths run without real sleeps.
	HealthPollInterval time.Duration
	HealthPollDeadline time.Duration

	// Bootstrap runs the post-health-gate CONTENT bootstrap (dwb-4) for a job
	// that carries a template: workspace → schemas → seed+publish → read token →
	// env values, driven by the embedded catalog manifest. nil → the real HTTPS
	// bootstrap against the instance FQDN (DefaultBootstrap). Tests inject a fake
	// so no instance is touched.
	Bootstrap BootstrapFunc
}

// BootstrapOutputs is what a template bootstrap produced — reported to the
// control plane on /succeed (stored encrypted) for the dashboard/deploy target.
type BootstrapOutputs = bootstrap.Outputs

// BootstrapRequest is one bootstrap invocation: the fresh instance's public
// origin + admin bearer, and the job's template/workspace identity.
type BootstrapRequest struct {
	// BaseURL is the instance origin, e.g. https://acme.barkpark.cloud.
	BaseURL string
	// AdminToken is the per-instance admin bearer the chain installed. NEVER logged.
	AdminToken string
	// Template is the catalog slug the control plane validated at launch.
	Template string
	// WorkspaceName / WorkspaceSlug are the workspace identity to bootstrap
	// (display name + slug — the job's name/slug).
	WorkspaceName string
	WorkspaceSlug string
}

// BootstrapFunc is the injected bootstrap seam — tests pass a fake; production
// uses DefaultBootstrap (real HTTPS against the fresh box).
type BootstrapFunc func(ctx context.Context, req BootstrapRequest) (*BootstrapOutputs, error)

// DefaultBootstrap resolves the template from the embedded catalog and runs the
// real internal/bootstrap chain over HTTPS against the instance. Sub-steps are
// narrated to stderr (the worker journal); tokens are never logged.
func DefaultBootstrap(ctx context.Context, req BootstrapRequest) (*BootstrapOutputs, error) {
	entry, ok := catalog.Get(req.Template)
	if !ok {
		return nil, fmt.Errorf("unknown template %q (known: %v)", req.Template, catalog.Names())
	}
	schemas, err := entry.SchemaBytes()
	if err != nil {
		return nil, err
	}
	seed, err := entry.SeedBytes()
	if err != nil {
		return nil, err
	}
	c := bootstrap.Client{
		BaseURL:    req.BaseURL,
		AdminToken: req.AdminToken,
		HTTPClient: &http.Client{Timeout: 60 * time.Second},
		Logf: func(format string, args ...any) {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: "+format+"\n", args...)
		},
	}
	return bootstrap.Run(ctx, c, bootstrap.Spec{
		Template:      entry.Manifest,
		SchemaFiles:   schemas,
		SeedFile:      seed,
		WorkspaceName: req.WorkspaceName,
		WorkspaceSlug: req.WorkspaceSlug,
	})
}

// Teardown deletes a successfully-provisioned host (server + DNS A record). It is
// returned by ProvisionWith ONLY on success and is the worker's lever for the one
// money edge ProvisionOneShot's own cleanup cannot reach: a box is live but the
// control-plane succeed-report then fails, so the box is real, billed, and unknown
// to the control plane. The worker calls this to leave ZERO orphans, then leaves
// the job re-claimable for a fresh attempt. It runs on a FRESH bounded context
// (reusing WarmPool.cleanupHost), so the worker can pass a cancelled ctx and the
// teardown still completes. nil error == clean teardown.
type Teardown func(ctx context.Context) error

// ProvisionWith runs the cloud-6 create→live chain for ONE job and returns the
// live host IP plus a Teardown that deletes that host. It is a ONE-SHOT
// create-then-provision, NOT a warm-pool pop: each job creates exactly ONE server
// with a globally-unique NAME (bp-<sanitized slug>-<crypto/rand suffix> — the
// suffix makes the name globally unique even when two teams share a slug),
// provisions it through the chain (dns → caddy/TLS → migrate → admin-token →
// health → register), and — on ANY failure after the server exists — tears the
// server + DNS A record down itself so no orphan is billed.
//
// On SUCCESS the returned Teardown is non-nil: the box is live but NOT yet known
// to the control plane (the in-chain RegistryClient is a no-op; the authoritative
// "this box exists" signal is the worker's succeed POST). The worker holds the
// Teardown so that if its succeed POST fails — a live box the control plane will
// never learn about — it can delete the orphan. On FAILURE the returned Teardown
// is nil: ProvisionOneShot already tore the half-built box down on its way out.
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
// SUBDOMAIN NOTE: the subdomain arriving in the job (job.Slug) is ALREADY globally
// unique — the control plane now allocates a <slug>-<teamid> provisioning_subdomain
// before the job is queued, so two teams that picked the same slug get distinct
// FQDNs. The server NAME is additionally made unique by ProvisionOneShot's
// crypto/rand suffix (oneShotServerName), guarding the Hetzner duplicate-name path
// even if two jobs ever carried an identical subdomain.
func ProvisionWith(ctx context.Context, seams Seams, job JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
	if seams.Provider == nil {
		return "", "", nil, nil, fmt.Errorf("provisioner: a CloudProvider must be set")
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
		Provider:           seams.Provider,
		DNS:                seams.DNS,
		Registry:           seams.Registry,
		Health:             seams.Health,
		Caddy:              seams.Caddy,
		RunnerFor:          seams.RunnerFor,
		Runner:             seams.Runner,
		Secrets:            seams.Secrets,
		HealthPollInterval: seams.HealthPollInterval,
		HealthPollDeadline: seams.HealthPollDeadline,
	}

	// The instance label is the slug when present (DNS-safe), else the name.
	label := job.Slug
	if label == "" {
		label = job.Name
	}

	spec := cloud.GoLiveSpec{
		Name: label,
		Zone: Zone,
		App:  AppPort,
		Spec: base,
	}
	live, err := wp.ProvisionOneShot(ctx, spec)
	if err != nil {
		// ProvisionOneShot already tore down its half-built box on the way out — no
		// orphan to clean up here, so the teardown handle is nil.
		return "", "", nil, nil, err
	}

	// dwb-4: when the job carries a template, bootstrap the fresh instance's
	// CONTENT (workspace → schemas → seed+publish → read token → env) so the
	// owner lands in a working site+Studio, not an empty box. It runs AFTER the
	// health gate + admin-token install (both inside ProvisionOneShot), against
	// the instance's public FQDN with the per-instance admin token. A bootstrap
	// FAILURE fails the whole provision through the EXISTING machinery: the box
	// is torn down here (never silently half-alive) and the error flows to the
	// worker's fail path (retry / attempts-cap). No template → the current
	// behavior, byte-for-byte.
	var boot *BootstrapOutputs
	if job.Template != "" {
		bootstrapFn := seams.Bootstrap
		if bootstrapFn == nil {
			bootstrapFn = DefaultBootstrap
		}
		boot, err = bootstrapFn(ctx, BootstrapRequest{
			BaseURL:       "https://" + label + "." + Zone,
			AdminToken:    live.Secrets.AdminToken,
			Template:      job.Template,
			WorkspaceName: job.Name,
			WorkspaceSlug: label,
		})
		if err != nil {
			// Tear the half-bootstrapped box down on the same cleanup path the chain
			// uses, so — like every other in-chain failure — the returned teardown is
			// nil and no orphan bills. A cleanup failure is surfaced alongside.
			if cerr := wp.CleanupHost(live.Server, spec); cerr != nil {
				return "", "", nil, nil, fmt.Errorf("bootstrap failed (%v) AND box cleanup failed: %w", err, cerr)
			}
			return "", "", nil, nil, fmt.Errorf("bootstrap %s: %w", job.Template, err)
		}
	}

	// SUCCESS: the box is live but the control plane does NOT yet know it (the
	// in-chain registry is a no-op). Hand the worker a teardown bound to THIS host
	// so that if its succeed POST fails — a live box the control plane will never
	// learn about — it can delete the orphan. Reuses the SAME WarmPool.cleanupHost
	// path ProvisionOneShot uses on failure, on a fresh bounded context.
	teardown := func(context.Context) error {
		return wp.CleanupHost(live.Server, spec)
	}
	// instance-admin-token: surface the admin bearer the chain minted + installed on
	// the box so the worker can report it on /succeed (stored encrypted for the
	// owner). NEVER logged here — it rides back only in the succeed request body.
	return live.IP, live.Secrets.AdminToken, boot, teardown, nil
}

// DefaultProvision returns a ProvisionFunc bound to seams — the value the Worker
// calls per job. It is the bridge between the transport-only Worker and the
// cloud-package chain: tests bind it to the fakes, main() binds it to the real
// providers.
func DefaultProvision(seams Seams) ProvisionFunc {
	return func(ctx context.Context, job JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
		return ProvisionWith(ctx, seams, job)
	}
}

// SweepFunc lists every box labeled barkpark-orphaned=true and deletes it (plus
// its stranded DNS record). It is the auto-recovery half of the double-failure
// edge: a worker that tore a box down but whose provider.Delete persistently
// failed marked the box orphaned; this routine, run on a later cycle, deletes it
// and recovers the spend. It returns the count swept and an aggregated error.
// Injected like ProvisionFunc so the worker stays transport-only and tests drive
// it against the fakes.
type SweepFunc func(ctx context.Context) (swept int, err error)

// SweepWith runs one orphan sweep over the seams' provider+DNS. It is SAFE — it
// deletes ONLY boxes carrying barkpark-orphaned=true, a label set EXCLUSIVELY in
// the teardown path after the worker already decided a box must die; a managed
// (not orphaned) box and any unlabeled/live box are never touched (see
// cloud.WarmPool.SweepOrphans).
func SweepWith(ctx context.Context, seams Seams) (int, error) {
	if seams.Provider == nil {
		return 0, fmt.Errorf("provisioner: a CloudProvider must be set to sweep orphans")
	}
	wp := &cloud.WarmPool{Provider: seams.Provider, DNS: seams.DNS}
	return wp.SweepOrphans(ctx)
}

// DefaultSweep returns a SweepFunc bound to seams — the value the Worker runs on
// startup (and optionally every N cycles) to recover leaked orphan boxes.
func DefaultSweep(seams Seams) SweepFunc {
	return func(ctx context.Context) (int, error) {
		return SweepWith(ctx, seams)
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
