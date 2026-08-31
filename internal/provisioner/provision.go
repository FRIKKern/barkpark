package provisioner

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/bootstrap"
	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/cli/setup"
	"github.com/FRIKKern/barkpark/internal/provisioner/catalog"
)

// Zone is the apex every managed Barkpark hangs under: <slug>.barkpark.cloud.
// The control plane stores only the per-instance slug; the worker pins the zone.
const Zone = "barkpark.cloud"

// AppPort is the local port Phoenix listens on, on each provisioned host (the
// same 4000 the warm-pool Caddy steps front with TLS).
const AppPort = 4000

// envAzureSSHPubKey is the env var carrying the SSH public key the worker installs
// on every Azure VM so it can SSH in and run the configure chain (a VM created
// without it is unreachable). It MIRRORS azure.EnvSSHPublicKey — duplicated as a
// literal on purpose so ProvisionWith's kind-routing (and its offline fake-provider
// tests) never import the Azure SDK. The prereq is enforced BEFORE any box is
// created (S2 carry) so the failure lands as an honest job error, not a billed,
// login-dead orphan.
const envAzureSSHPubKey = "BARKPARK_AZURE_SSH_PUBKEY"

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

	// LookupHost resolves a hostname to its A/AAAA addresses via the SYSTEM
	// resolver — the attach-domain V2 ownership re-check for EXTERNAL customer
	// domains (the worker re-verifies the host already points at the box before
	// touching it; it cannot trust the control plane's own pre-check). nil →
	// net.DefaultResolver.LookupHost. Tests inject a fake.
	LookupHost func(ctx context.Context, host string) ([]string, error)

	// Mail is the SHARED transactional-mail relay every provisioned instance is
	// pointed at (magic-link / password-reset / verify-email). Zero value → the
	// instance is provisioned without SMTP (Local adapter, no delivery). Sourced
	// from the worker's SMTP_RELAY_* env in cmd/barkpark-provisioner/main.go.
	Mail cloud.MailRelay

	// CloudEgressIPs is the control plane's own EGRESS address — written into every
	// provisioned instance's BARKPARK_TRUSTED_PROXIES so the box believes the caller
	// address the control plane relays (the per-phone rate-limit bucket on a proxied
	// revoke). Empty → the instance keeps loopback-only trust and every proxied
	// request keys on ONE bucket per team. Sourced from the worker's
	// BARKPARK_CLOUD_EGRESS_IPS env in cmd/barkpark-provisioner/main.go — the SAME
	// address as the CP_HOST deploy secret, authored once (see deploy/README.md).
	CloudEgressIPs string

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

	// WarmPoolSize is the target warm-pool size (dwb-10). 0 (the default) DISABLES
	// the warm pool — ProvisionWith create-then-provisions one-shot exactly as
	// before, so prod stays on the proven path until the pool is explicitly enabled.
	// >0 enables the warm-assign path (claim a pre-baked box → assign in ≤15s →
	// async refill) with a SILENT one-shot fallback when the pool is empty or an
	// assign fails.
	WarmPoolSize int
	// WarmClient is the control-plane warm-server claim-store seam. nil disables the
	// warm pool regardless of WarmPoolSize (the claim store is where the atomic
	// FOR UPDATE SKIP LOCKED claim lives). Injected; tests use a fake.
	WarmClient WarmPoolClient
	// WarmRefill overrides the async refill action launched after a successful claim
	// (create + register one replacement warm box). nil → the default. Tests inject
	// one that signals a channel so the async, non-blocking behaviour is observable
	// without racing on a real create.
	WarmRefill func(ctx context.Context)

	// StepReporter (dwb-14), when set, reports a coarse step transition for `jobID`
	// to the control plane (→ SSE → the /new progress screen). It is PURE TELEMETRY:
	// ProvisionWith swallows its error (logging to stderr) so a step-report failure
	// — a control-plane blip, a deploy restart — NEVER fails the provision. nil (the
	// tests that don't assert narration, an old wiring) disables reporting silently.
	// step ∈ create|freshen|secure|configure|content|verify|ready; status ∈
	// started|progress|done|failed — mirrored by the control plane's
	// ProvisionJob step vocabulary (cloud/lib/.../registry/provision_job.ex);
	// a step/status outside it is 422-rejected there, so the two lists MUST
	// move together.
	StepReporter func(ctx context.Context, jobID, step, status, detail string) error

	// VerifyBaseURL overrides the golden-path VERIFY gate's target origin (C2/D45).
	// Empty (production) → https://<label>.<zone>, the SAME origin the health gate +
	// content bootstrap used. Tests point it at an httptest fake instance so the real
	// probe logic runs against a controllable server without a live box.
	VerifyBaseURL string

	// ConsoleReporter (dwb-16), when set, tees the create→live chain + content
	// bootstrap narration to the control plane as LIVE console lines (→ SSE → the
	// /new console panel). Like StepReporter it is PURE TELEMETRY: ProvisionWith
	// routes it through a consoleEmitter that swallows every error, so a
	// console-report failure NEVER fails a provision. Redaction is applied to every
	// line before it leaves the worker (the minted admin token + secret patterns).
	// nil (tests, an old wiring) disables console reporting silently.
	ConsoleReporter ConsoleReporter

	// ControlURL (charter Decision 33) is the control-plane origin the on-box
	// barkpark-agent reports to. It rides into the GoLiveSpec so the configure step
	// can write /etc/barkpark/agent.env (BARKPARK_CONTROL_URL) and enable
	// barkpark-agent.service. Same value main() passes to the worker's own claim
	// loop; empty (tests that don't exercise the agent) skips the agent install.
	ControlURL string

	// Restore (charter S14, Decision 12) executes the provider + object-store actions
	// of a portable-bundle RESURRECT — a cold create, DNS repoint, sealed-identity
	// install, and database restore. ProvisionWith uses it ONLY when a job carries a
	// BundleRef (a resurrect claim); every normal launch leaves it nil and never
	// touches this seam. The real driver (wired at S14a/b/c integration) creates the
	// box via ProvisionOneShot in restore mode + runs pg_restore over the box runner;
	// tests inject a recorder so the round-trip is proven offline. nil on a restore
	// job → ProvisionWith fails loud (a resurrect with no restore driver is a
	// misconfiguration, never a silent normal provision).
	Restore RestoreDriver
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
	// ConsoleSink (dwb-16), when set, receives each bootstrap sub-step narration
	// line so DefaultBootstrap can tee its Logf to the LIVE console in addition to
	// the worker journal. nil → journal-only (the pre-dwb-16 behavior). A fake
	// bootstrap in tests simply ignores it.
	ConsoleSink func(line string)
	// DetailSink (dwb-19), when set, receives the CURATED plain-language caption
	// for each content sub-boundary (workspace → schemas → seed → webhook) so the
	// provisioner can report it as a `content`/`progress` step detail — the live
	// sub-line under the active step. Distinct from ConsoleSink (raw journal): a
	// DetailSink line is a short human caption, never raw output. nil → no
	// captions (the pre-dwb-19 behavior). MUST NOT be handed tokens.
	DetailSink func(caption string)
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
			// dwb-16: tee each bootstrap sub-step to the live console too (redacted
			// downstream by the emitter). Best-effort — a nil sink is journal-only.
			if req.ConsoleSink != nil {
				req.ConsoleSink(fmt.Sprintf(format, args...))
			}
		},
		// dwb-19: the curated caption channel — a short human line per content
		// sub-boundary, surfaced as the live `content`/`progress` sub-caption.
		Caption: req.DetailSink,
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
	// A resurrect claim (charter S14, Decision 12) carries a BundleRef and routes to
	// the RESTORE path BEFORE any normal-provision setup — it is a distinct chain (cold
	// create, sealed-identity install, database restore), never a template launch. Every
	// normal launch has BundleRef nil and falls through to the byte-for-byte unchanged
	// path below.
	if job.BundleRef != nil {
		return provisionRestore(ctx, seams, job)
	}
	if seams.Provider == nil {
		return "", "", nil, nil, fmt.Errorf("provisioner: a CloudProvider must be set")
	}

	// Provider routing (charter Decision 9). An empty kind means the pre-provider-
	// neutral control plane (or a Hetzner claim, whose payload omits the key), so
	// it MUST route Hetzner — the existing warm-pool path stays byte-for-byte
	// unchanged (zero prod regression). A non-Hetzner kind (azure) is an honest
	// pool-size-zero cold create: the provider is resolved through the registry
	// from the job's decrypted credentials, and the warm pool is forced OFF (no
	// warm boxes exist off Hetzner).
	kind := job.Kind
	if kind == "" {
		kind = cloud.ProviderHetzner
	}

	base := cloud.ServerSpec{
		Region:     job.Region,
		ServerType: job.ServerType,
	}

	if kind == cloud.ProviderHetzner {
		// Image resolves DYNAMICALLY (snapshot-management): the newest baked
		// `role=warm-image` snapshot when one exists, else the env-pinned
		// BARKPARK_SERVER_IMAGE fallback — a one-shot go-live boots the same
		// fresh bake the pool does.
		fresh := cloud.FreshSpec(ctx, cloud.ProviderHetzner)
		// azh-w3: an UNPINNED hetzner claim now emits nil region/server_type (the
		// signal tryWarmAssign reads as "pool-compatible"). Fill the empties from
		// the env-derived FreshSpec so the resilience ladder never leads with an
		// empty create — on the one-shot fallback OR when a filled-to-base spec is
		// handed to a warm assign. A real PIN (fsn1/cx32) is left untouched, so the
		// warm pin-guard still sees the difference and one-shots it.
		if base.Region == "" {
			base.Region = fresh.Region
		}
		if base.ServerType == "" {
			base.ServerType = fresh.ServerType
		}
		base.Image = fresh.Image
	} else {
		// Azure prereq (S2 carry): the SSH public key the worker installs on every
		// VM MUST be configured, else the created box is unreachable. Fail HERE,
		// before any resource exists, with copy that names the exact fix — never a
		// billed, login-dead orphan discovered mid-provision.
		if kind == cloud.ProviderAzure && strings.TrimSpace(os.Getenv(envAzureSSHPubKey)) == "" {
			return "", "", nil, nil, fmt.Errorf(
				"azure provisioning needs an SSH public key: set %s on the provisioner (the key installed on each VM so the worker can configure it) — no box was created",
				envAzureSSHPubKey)
		}
		// Resolve the provider through the registry from the job's per-kind creds.
		// A typo / unregistered kind fails loud here (before any box), never silent.
		provider, perr := cloud.ProviderFor(kind, job.Credentials)
		if perr != nil {
			return "", "", nil, nil, perr
		}
		seams.Provider = provider
		// Pool-size-zero: no warm pool off Hetzner, so ALWAYS one-shot cold create.
		// Force both knobs so a worker configured with a Hetzner warm pool can't
		// accidentally hand an azure job a Hetzner warm box (acquireHost gates on
		// WarmPoolSize > 0 AND a non-nil WarmClient).
		seams.WarmPoolSize = 0
		seams.WarmClient = nil
		// Provider-aware image: FreshSpec's warm-snapshot resolution is Hetzner-only,
		// so a non-Hetzner kind gets DefaultSpec's image (empty for azure → the
		// provider fills its own platform default). Never a Hetzner snapshot id.
		base.Image = cloud.FreshSpec(ctx, kind).Image
	}

	// The instance label is the slug when present (DNS-safe), else the name.
	label := job.Slug
	if label == "" {
		label = job.Name
	}

	// dwb-16: a best-effort LIVE console emitter bound to THIS job. Every coarse
	// phase transition (below) + the content bootstrap sub-steps are teed to it, so
	// the /new console panel shows what is happening as it happens. Redaction runs
	// on every line before it leaves the worker; a report error is swallowed, so
	// console narration is telemetry and NEVER fails a provision.
	console := newConsoleEmitter(ctx, job.JobID, seams.ConsoleReporter)
	console.logf("provisioning %s.%s (%s / %s)…", label, Zone, job.Region, job.ServerType)

	// dwb-14: a best-effort step reporter bound to THIS job. `report` swallows the
	// error (logs to stderr) so narration is telemetry, never control flow — a
	// step-report failure must never fail a provision. nil StepReporter (tests, an
	// old wiring) makes it a no-op. dwb-16: it ALSO tees a human-readable line to
	// the live console (independent of the step-array telemetry).
	report := func(step, status, detail string) {
		if detail != "" {
			console.logf("%s: %s — %s", step, status, detail)
		} else {
			console.logf("%s: %s", step, status)
		}
		if seams.StepReporter == nil {
			return
		}
		if err := seams.StepReporter(ctx, job.JobID, step, status, detail); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: step report %s/%s for job %s failed (non-fatal): %v\n", step, status, job.JobID, err)
		}
	}

	wp := &cloud.WarmPool{
		Provider:           seams.Provider,
		DNS:                seams.DNS,
		Registry:           seams.Registry,
		Health:             seams.Health,
		Caddy:              managedBoxCaddy{inner: seams.Caddy},
		RunnerFor:          seams.RunnerFor,
		Runner:             seams.Runner,
		Secrets:            seams.Secrets,
		Mail:               seams.Mail,
		TrustedProxies:     seams.CloudEgressIPs,
		HealthPollInterval: seams.HealthPollInterval,
		HealthPollDeadline: seams.HealthPollDeadline,
		// The chain fires create/secure/configure at its real phase boundaries;
		// content/ready are reported here (the provisioner owns bootstrap + success).
		Progress: report,
	}

	spec := cloud.GoLiveSpec{
		Name: label,
		Zone: Zone,
		App:  AppPort,
		Spec: base,
		// charter Decision 33 — thread the per-instance agent token (minted at
		// claim) + the control-plane origin into the go-live so configureHost writes
		// /etc/barkpark/agent.token and enables barkpark-agent.service. Both empty
		// (an old control plane / a test) → the configure step skips the agent
		// install, the box serves without the beat.
		AgentToken: job.AgentToken,
		ControlURL: seams.ControlURL,
	}

	// Acquire a configured, live host. When the warm pool is enabled (dwb-10), try
	// to ASSIGN a pre-baked box (≤15s); on an empty pool or a failed assign fall
	// through to one-shot create SILENTLY, so a cold/lagging pool still meets the
	// 90s p95 and a go-live never dead-ends. Disabled (WarmPoolSize 0 / no
	// WarmClient) → the one-shot path, byte-for-byte the prior behavior.
	live, err := acquireHost(ctx, seams, wp, spec)
	if err != nil {
		// The acquisition path already tore down any half-built box on the way out
		// (one-shot cleans up its own; a failed warm assign tears its box down, then
		// the one-shot fallback cleans up its own) — no orphan here, so nil teardown.
		// The create/secure/configure chain already reported the precise <step>/failed
		// via wp.Progress, so /new renders honest failure copy — nothing to add here.
		return "", "", nil, nil, err
	}

	// dwb-16: the chain has now minted + installed the per-instance admin token.
	// Register it as a literal console secret so every subsequent console line (the
	// content bootstrap + ready) is scrubbed of the token value — the same
	// literal-redaction the cloud runner applies to its captured output.
	console.addSecret(live.Secrets.AdminToken)

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
		// dwb-14: `content` = the template bootstrap (workspace → schemas → seed).
		report("content", "started", "")
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
			// dwb-16: tee the bootstrap sub-step narration to the live console
			// (redacted downstream by the emitter — the admin token is registered above).
			ConsoleSink: func(line string) { console.logf("%s", line) },
			// dwb-19: surface each content sub-boundary as the live caption under the
			// active `content` step (in-place update; no new steps entry per caption).
			DetailSink: func(caption string) { report("content", "progress", caption) },
		})
		if err != nil {
			report("content", "failed", err.Error())
			// Tear the half-bootstrapped box down on the same cleanup path the chain
			// uses, so — like every other in-chain failure — the returned teardown is
			// nil and no orphan bills. A cleanup failure is surfaced alongside.
			if cerr := wp.CleanupHost(live.Server, spec); cerr != nil {
				return "", "", nil, nil, fmt.Errorf("bootstrap failed (%v) AND box cleanup failed: %w", err, cerr)
			}
			return "", "", nil, nil, fmt.Errorf("bootstrap %s: %w", job.Template, err)
		}
		report("content", "done", "")
	}

	// VERIFY (C2 / D45): the box passed the health gate and, when asked, has its
	// content — but "healthy" is not "the owner can actually log in". Probe the
	// GOLDEN PATH over HTTPS against the live instance before declaring it ready: the
	// API answers, the auth/session stack cleanly REJECTS bad creds (a 5xx here is
	// the #957 32-byte-SECRET_KEY_BASE dead-on-arrival class), and Studio renders
	// through the scoped-redirect path. A red probe FAILS the provision on the SAME
	// cleanup path as a content failure — the box is torn down (nil teardown, no
	// orphan), the error flows to the worker's fail path, and /succeed never fires,
	// so the control plane never declares a login-dead box ready. Probes are
	// anonymous / sentinel-cred; the minted admin token is held but NEVER sent,
	// logged, or narrated.
	verifyBase := seams.VerifyBaseURL
	if verifyBase == "" {
		verifyBase = "https://" + label + "." + Zone
	}
	if verr := runVerifyGate(ctx, verifyConfig{
		baseURL:      verifyBase,
		token:        live.Secrets.AdminToken,
		probeTimeout: verifyProbeTimeout,
		totalBudget:  verifyTotalBudget,
	}, report); verr != nil {
		// Same teardown path as a content failure: nil teardown, no orphan bills.
		if cerr := wp.CleanupHost(live.Server, spec); cerr != nil {
			return "", "", nil, nil, fmt.Errorf("golden-path verify failed (%v) AND box cleanup failed: %w", verr, cerr)
		}
		return "", "", nil, nil, verr
	}

	// SUCCESS: the box is live but the control plane does NOT yet know it (the
	// in-chain registry is a no-op). Hand the worker a teardown bound to THIS host
	// so that if its succeed POST fails — a live box the control plane will never
	// learn about — it can delete the orphan. Reuses the SAME WarmPool.cleanupHost
	// path ProvisionOneShot uses on failure, on a fresh bounded context.
	teardown := func(context.Context) error {
		return wp.CleanupHost(live.Server, spec)
	}
	// dwb-14: `ready` — the box is live (health gate green) and, when asked, its
	// content is bootstrapped. The worker's /succeed POST that follows flips the
	// barkpark to up; this narrates the final transition for the /new screen.
	// dwb-19: a brief live caption before the terminal `done` (health already
	// passed inside acquireHost; this is the final wrap-up, not a re-check).
	report("ready", "started", "")
	report("ready", "progress", "Putting the finishing touches on your Barkpark…")
	report("ready", "done", "")
	// instance-admin-token: surface the admin bearer the chain minted + installed on
	// the box so the worker can report it on /succeed (stored encrypted for the
	// owner). NEVER logged here — it rides back only in the succeed request body.
	return live.IP, live.Secrets.AdminToken, boot, teardown, nil
}

// managedBoxCaddy wraps the chain's CaddyStepper (the injected one, or the
// canonical setup.CaddySteps default when nil) to append ONE extra
// provision-time env write to the caddy/env phase: BARKPARK_SELF_UPDATE_APPLY=1
// (managed boxes are cloud-operated; the team autoupdate policy is the consent
// — enable_apply.go is the retrofit for boxes provisioned before the flag
// existed). Appended after the PHX_HOST/PHX_SCHEME steps and before the chain's
// secrets-install restart, so the one boot picks the flag up with the rest.
type managedBoxCaddy struct{ inner cloud.CaddyStepper }

func (c managedBoxCaddy) Steps(name, zone string, appPort int) []cloud.CaddyStep {
	var steps []cloud.CaddyStep
	if c.inner != nil {
		steps = c.inner.Steps(name, zone, appPort)
	} else {
		// Mirror the cloud package's defaultCaddySteps: the canonical
		// setup.CaddySteps with SkipAppRestart (the go-live chain's
		// secrets-install step restarts the app once for everything).
		for _, s := range setup.CaddySteps(setup.CaddyOpts{Name: name, Domain: zone, AppPort: appPort, SkipAppRestart: true}) {
			steps = append(steps, cloud.CaddyStep{Title: s.Title, Cmd: s.Cmd, Argv: s.Argv})
		}
	}
	// Managed boxes are cloud-operated — new boxes ship with the self-update executor enabled.
	return append(steps, setSelfUpdateApplyStep(attachEnvFile))
}

var _ cloud.CaddyStepper = managedBoxCaddy{}

// acquireHost returns a configured, live host for the job. When the warm pool is
// enabled (WarmPoolSize > 0 AND a WarmClient is injected) it tries to ASSIGN a
// pre-baked box (the ≤15s path); on an empty pool, a claim error, or a failed
// assign it falls through to one-shot create SILENTLY — so the go-live never
// dead-ends and the 90s p95 holds even when the pool is cold or lagging. With the
// pool disabled it is exactly wp.ProvisionOneShot (the prior behavior).
func acquireHost(ctx context.Context, seams Seams, wp *cloud.WarmPool, spec cloud.GoLiveSpec) (cloud.LiveServer, error) {
	if seams.WarmPoolSize > 0 && seams.WarmClient != nil {
		if live, ok := tryWarmAssign(ctx, seams, wp, spec); ok {
			return live, nil
		}
		// empty pool / claim error / assign failure → fall through to one-shot.
	}
	return wp.ProvisionOneShot(ctx, spec)
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
