// Warm-pool go-live provisioner — the cloud-6 capstone. It chains every seam
// the earlier cloud tasks built into ONE ordered assign→live sequence:
//
//	assign → secrets → dns → caddy → migrate → health → register → replacement
//
// "Local Barkpark → live server in seconds" is a warm-pool move, not a
// create-on-demand one: a pool of ready hosts is kept warm ahead of time, a
// go-live POPS one (instant), and the pool refills itself with a background
// create. Every external touchpoint is an INJECTED interface or func so the
// whole chain runs green against fakes at zero spend — matching the cloud-1
// CloudProvider / cloud-3 DNSProvider inject-a-fake idiom.
//
// The chain FAILS CLOSED: if the health gate does not pass, Provision returns
// an error and does NOT register the server or mark it ready. This mirrors the
// "no ready until checks pass" rule the health gate itself enforces.
//
// YAGNI on purpose: one go-live at a time, pop + create-one-replacement. The
// warm_pool_size formula and autoscaling are explicitly NOT this task.
package cloud

import (
	"context"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// GoLiveSpec is the declarative request for one go-live: the per-instance
// subdomain label (Name → <name>.barkpark.cloud), the apex Zone it hangs under,
// and the cloud-provider knobs for the replacement host the pop triggers. App
// is the local port Phoenix listens on (4000). BaseURL, when set, overrides the
// health-gate target (tests point it at a fake server); empty derives the
// public https://<fqdn>.
type GoLiveSpec struct {
	Name    string     // per-instance label, e.g. "acme" → acme.barkpark.cloud
	Zone    string     // apex, e.g. "barkpark.cloud"
	App     int        // local app port, e.g. 4000
	Spec    ServerSpec // the spec used to create REPLACEMENT warm hosts
	BaseURL string     // health-gate target override (tests); empty → https://<fqdn>
}

// fqdn renders the full public hostname for this go-live: "<name>.<zone>".
func (s GoLiveSpec) fqdn() string {
	return Fqdn(s.Name, s.Zone)
}

// healthTarget is the base URL the health gate probes: the explicit BaseURL
// override when set (tests), else the public https://<fqdn>.
func (s GoLiveSpec) healthTarget() string {
	if strings.TrimSpace(s.BaseURL) != "" {
		return strings.TrimRight(s.BaseURL, "/")
	}
	return "https://" + s.fqdn()
}

// Secrets are the per-instance credentials minted for one go-live. SecretKeyBase
// is the Phoenix signing secret (the `mix phx.gen.secret` / `openssl rand`
// equivalent deploy.sh seeds into the .env); AdminToken is the clean-profile
// admin bearer (reused from setup.GenerateAdminToken). They are NEVER logged or
// returned to the caller in the clear beyond the LiveServer hand-off.
type Secrets struct {
	SecretKeyBase string
	AdminToken    string
}

// LiveServer is the verified, registered outcome of a go-live: the popped host,
// its public FQDN, and the secrets minted for it. It is what RegistryClient
// records and what Provision returns on success.
type LiveServer struct {
	Name    string
	FQDN    string
	IP      string
	Server  Server
	Secrets Secrets
}

// ─── injected seams ─────────────────────────────────────────────────────────

// CaddyStep is one ordered Caddy/TLS provisioning action, mirroring the setup
// package's step shape (Title/Cmd/Argv) so the real stepper can be backed by
// setup.CaddySteps (now exported). The cloud package owns this
// small record so the warm-pool chain carries no dependency on setup's
// unexported step type.
type CaddyStep struct {
	Title string
	Cmd   string
	Argv  []string
}

// CaddyStepper produces the ordered Caddy/TLS steps for one server. The default
// impl (defaultCaddySteps) mirrors setup.caddySteps: install Caddy, write the
// Caddyfile, set PHX_HOST/PHX_SCHEME in the app env, reload, ufw-deny the app
// port. A fake in tests records the steps without touching a box.
type CaddyStepper interface {
	Steps(name, zone string, appPort int) []CaddyStep
}

// StepRunner executes one CaddyStep. The real run shells out the Argv; the fake
// records it. Returning an error fails the chain closed before health/register.
type StepRunner interface {
	Run(ctx context.Context, s CaddyStep) error
}

// HealthChecker runs the post-deploy health gate against base and returns the
// report. The default wraps setup.RunHealthGate; tests inject a func that
// returns a green (or, for the failure path, a red) report without a live
// server. A non-nil error is the fail-closed signal.
type HealthChecker func(ctx context.Context, base, token string) (setup.HealthReport, error)

// RegistryClient is the Go client seam for the Elixir control-plane registry
// (the REAL registry is cloud-9). Register records a verified LiveServer.
// Stubbed now with FakeRegistry, wired to the control plane later.
type RegistryClient interface {
	Register(ctx context.Context, srv LiveServer) error
}

// SecretGen mints per-instance secrets. The default reuses setup.GenerateAdminToken
// for the admin token and a second random draw for SECRET_KEY_BASE.
type SecretGen func() (Secrets, error)

// ─── Pool ───────────────────────────────────────────────────────────────────

// Pool is the warm-host abstraction: a ring of pre-seeded ready hosts backed by
// a CloudProvider. pop() returns one ready host AND triggers a replacement
// create so the pool refills itself — the warm-pool point. It is NOT
// create-on-demand: the popped host already exists, so a go-live is instant.
//
// The replacement create is recorded so the chain can assert a refill happened.
type Pool struct {
	provider CloudProvider
	ready    []Server // FIFO of pre-seeded ready hosts
	// nameFor derives the replacement host's name from the pool counter so each
	// refill create has a unique, deterministic name (warm-N).
	created int
}

// NewPool seeds a warm pool with the given ready hosts against provider. The
// hosts are assumed already created (e.g. via provider.Create at seed time);
// callers seed with SeedPool to also register them in a FakeProvider.
func NewPool(provider CloudProvider, ready ...Server) *Pool {
	rs := make([]Server, len(ready))
	copy(rs, ready)
	return &Pool{provider: provider, ready: rs}
}

// SeedPool creates n warm hosts via provider (names warm-1..warm-n) and returns
// a Pool holding them ready. This is the test/seed-time helper: against a
// FakeProvider it costs nothing and pre-registers the hosts so pop's replacement
// create lands on a fresh name.
func SeedPool(ctx context.Context, provider CloudProvider, n int, base ServerSpec) (*Pool, error) {
	p := &Pool{provider: provider}
	for i := 0; i < n; i++ {
		p.created++
		spec := base
		spec.Name = fmt.Sprintf("warm-%d", p.created)
		// CreateWithFallback walks the resilience ladder so the pool seeds even
		// when the preferred type is sold out. The Fake succeeds on the first
		// candidate, so test behaviour is unchanged.
		srv, _, err := CreateWithFallback(ctx, provider, spec)
		if err != nil {
			return nil, fmt.Errorf("seed warm pool: create %q: %w", spec.Name, err)
		}
		p.ready = append(p.ready, srv)
	}
	return p, nil
}

// Len reports how many ready hosts remain in the pool.
func (p *Pool) Len() int { return len(p.ready) }

// pop returns the next ready host and triggers a replacement create so the pool
// refills. An empty pool is an error (a go-live with no warm host cannot be
// instant — fail rather than silently create-on-demand). The replacement uses
// base for type/image/region with a fresh warm-N name; its create error fails
// the pop so a refill failure is never silent.
func (p *Pool) pop(ctx context.Context, base ServerSpec) (Server, error) {
	if len(p.ready) == 0 {
		return Server{}, fmt.Errorf("warm pool empty: no ready host to assign")
	}
	host := p.ready[0]
	p.ready = p.ready[1:]

	// Refill: create one replacement so the pool stays warm. CreateWithFallback
	// walks the resilience ladder so the refill succeeds even when the preferred
	// type is sold out (the Fake succeeds on the first candidate — behaviour
	// unchanged in tests).
	p.created++
	spec := base
	spec.Name = fmt.Sprintf("warm-%d", p.created)
	repl, _, err := CreateWithFallback(ctx, p.provider, spec)
	if err != nil {
		return Server{}, fmt.Errorf("warm pool refill: create %q: %w", spec.Name, err)
	}
	p.ready = append(p.ready, repl)
	return host, nil
}

// ─── WarmPool provisioner ────────────────────────────────────────────────────

// WarmPool wires the injected seams into the go-live chain. Every field is an
// interface or func so the whole Provision runs against fakes — no real cloud,
// DNS, box, or registry. Construct directly (every field is settable) or via
// the defaults a caller fills from the real providers.
type WarmPool struct {
	Pool     *Pool
	DNS      DNSProvider
	Caddy    CaddyStepper
	Runner   StepRunner
	Health   HealthChecker
	Registry RegistryClient
	Secrets  SecretGen

	// MigrateArgv is the `mix ecto.migrate` argv the migrate step carries. It is
	// NOT executed in tests (the fake runner records it); the real runner shells
	// it out on the box. Empty → defaultMigrateArgv.
	MigrateArgv []string
}

// defaultMigrateArgv is the migrate command the migrate step runs on the box:
// `mix ecto.migrate` under the app's release env. Recorded (not executed) by the
// fake runner in tests.
func defaultMigrateArgv() []string {
	return []string{"bash", "-lc", "cd /opt/barkpark/api && mix ecto.migrate"}
}

// defaultSecretGen mints per-instance secrets reusing the existing secret-gen:
// setup.GenerateAdminToken for the admin bearer, and a second admin-token draw
// repurposed as the SECRET_KEY_BASE entropy (same crypto/rand source deploy.sh's
// `mix phx.gen.secret || openssl rand` step uses — a 32-char URL-safe secret).
func defaultSecretGen() (Secrets, error) {
	skb, err := setup.GenerateAdminToken()
	if err != nil {
		return Secrets{}, fmt.Errorf("generate SECRET_KEY_BASE: %w", err)
	}
	tok, err := setup.GenerateAdminToken()
	if err != nil {
		return Secrets{}, fmt.Errorf("generate admin token: %w", err)
	}
	return Secrets{
		// Strip the bp_admin_ prefix for the key base — it is signing entropy, not
		// a bearer token; the admin token keeps its prefix.
		SecretKeyBase: strings.TrimPrefix(skb, "bp_admin_"),
		AdminToken:    tok,
	}, nil
}

// defaultHealthChecker wraps setup.RunHealthGate with the gate options the
// go-live needs. The stub probes (agent/backup, cloud-9/10) are pointed at the
// gate's defaults; callers that have the real endpoints set them on the gate.
func defaultHealthChecker(ctx context.Context, base, token string) (setup.HealthReport, error) {
	return setup.RunHealthGate(base, token, setup.HealthGate{})
}

// defaultCaddySteps delegates to the CANONICAL setup.CaddySteps (cloud-4) — no
// duplicated step list. The warm pool gets the same idempotent Caddyfile/PHX_HOST
// provisioning the manual deploy uses; mapping setup's step → the cloud package's
// CaddyStep keeps the injectable seam (tests still swap in a fake CaddyStepper).
type defaultCaddySteps struct{}

func (defaultCaddySteps) Steps(name, zone string, appPort int) []CaddyStep {
	raw := setup.CaddySteps(setup.CaddyOpts{Name: name, Domain: zone, AppPort: appPort})
	out := make([]CaddyStep, len(raw))
	for i, s := range raw {
		out[i] = CaddyStep{Title: s.Title, Cmd: s.Cmd, Argv: s.Argv}
	}
	return out
}

// withDefaults fills any nil injected seam with its default. The Pool, DNS, and
// Registry have no zero-value default (the caller MUST inject a provider-backed
// pool, a DNS provider, and a registry client) and are validated in Provision.
func (wp *WarmPool) withDefaults() {
	if wp.Caddy == nil {
		wp.Caddy = defaultCaddySteps{}
	}
	if wp.Runner == nil {
		wp.Runner = realStepRunner{}
	}
	if wp.Health == nil {
		wp.Health = defaultHealthChecker
	}
	if wp.Secrets == nil {
		wp.Secrets = defaultSecretGen
	}
	if len(wp.MigrateArgv) == 0 {
		wp.MigrateArgv = defaultMigrateArgv()
	}
}

// realStepRunner shells out a CaddyStep's Argv via the package-local runCapture
// (the same exec mechanism the cloud + setup packages use). It is the production
// runner; tests inject a fake that records instead.
type realStepRunner struct{}

func (realStepRunner) Run(ctx context.Context, s CaddyStep) error {
	if len(s.Argv) == 0 {
		return nil // narration-only step
	}
	if _, err := runCapture(ctx, s.Argv[0], s.Argv[1:]...); err != nil {
		return fmt.Errorf("caddy step %q: %w", s.Title, err)
	}
	return nil
}

// Provision runs the ordered go-live chain for spec and returns the verified,
// registered LiveServer. The chain is:
//
//  1. assign      — pop a ready host from the warm pool (triggers a refill).
//  2. secrets     — mint per-instance SECRET_KEY_BASE + admin token.
//  3. dns         — UpsertRecord an A record <name>.<zone> → the host IP.
//  4. caddy       — run the Caddy/TLS steps (sets PHX_HOST/PHX_SCHEME).
//  5. migrate     — run the mix ecto.migrate step.
//  6. health      — RunHealthGate against the new server (FAIL CLOSED here).
//  7. register    — record the LiveServer in the control-plane registry.
//  8. replacement — already triggered by the pop in step 1 (pool stays warm).
//
// FAIL CLOSED: if health (step 6) does not pass, Provision returns the gate
// error and does NOT register the server. The replacement create from step 1
// still stands — the pool refill is independent of this go-live's outcome.
func (wp *WarmPool) Provision(ctx context.Context, spec GoLiveSpec) (LiveServer, error) {
	wp.withDefaults()
	if wp.Pool == nil {
		return LiveServer{}, fmt.Errorf("warmpool: a provider-backed Pool must be injected")
	}
	if wp.DNS == nil {
		return LiveServer{}, fmt.Errorf("warmpool: a DNSProvider must be injected")
	}
	if wp.Registry == nil {
		return LiveServer{}, fmt.Errorf("warmpool: a RegistryClient must be injected")
	}
	if strings.TrimSpace(spec.Name) == "" || strings.TrimSpace(spec.Zone) == "" {
		return LiveServer{}, fmt.Errorf("warmpool: spec Name and Zone are required")
	}
	if spec.App <= 0 {
		return LiveServer{}, fmt.Errorf("warmpool: spec App port must be positive, got %d", spec.App)
	}

	// 1. assign — pop a warm host (this also fires the replacement create).
	host, err := wp.Pool.pop(ctx, spec.Spec)
	if err != nil {
		return LiveServer{}, fmt.Errorf("assign: %w", err)
	}

	// 2. secrets — mint per-instance credentials.
	secrets, err := wp.Secrets()
	if err != nil {
		return LiveServer{}, fmt.Errorf("secrets: %w", err)
	}

	// 3. dns — point <name>.<zone> at the assigned host IP.
	rec := Record{Zone: spec.Zone, Name: spec.Name, Type: "A", Value: host.IP}
	if err := wp.DNS.UpsertRecord(ctx, rec); err != nil {
		return LiveServer{}, fmt.Errorf("dns: upsert %s: %w", spec.fqdn(), err)
	}

	// 4. caddy — run the TLS/PHX_HOST steps via the injected runner.
	for _, s := range wp.Caddy.Steps(spec.Name, spec.Zone, spec.App) {
		if err := wp.Runner.Run(ctx, s); err != nil {
			return LiveServer{}, fmt.Errorf("caddy: %w", err)
		}
	}

	// 5. migrate — run the mix ecto.migrate step through the same runner.
	migrate := CaddyStep{Title: "run database migrations (mix ecto.migrate)", Cmd: strings.Join(wp.MigrateArgv, " "), Argv: wp.MigrateArgv}
	if err := wp.Runner.Run(ctx, migrate); err != nil {
		return LiveServer{}, fmt.Errorf("migrate: %w", err)
	}

	// 6. health — FAIL CLOSED. A red gate stops the chain before register.
	report, err := wp.Health(ctx, spec.healthTarget(), secrets.AdminToken)
	if err != nil {
		return LiveServer{}, fmt.Errorf("health: %s not ready: %w", spec.fqdn(), err)
	}
	if !report.OK {
		return LiveServer{}, fmt.Errorf("health: %s not ready: %s", spec.fqdn(), strings.Join(report.Failures(), ", "))
	}

	// 7. register — record the verified server in the control-plane registry.
	live := LiveServer{
		Name:    spec.Name,
		FQDN:    spec.fqdn(),
		IP:      host.IP,
		Server:  host,
		Secrets: secrets,
	}
	if err := wp.Registry.Register(ctx, live); err != nil {
		return LiveServer{}, fmt.Errorf("register: %w", err)
	}

	// 8. replacement — already triggered by pop in step 1; the pool is warm.
	return live, nil
}

// ─── FakeRegistry ────────────────────────────────────────────────────────────

// FakeRegistry is the in-memory RegistryClient every go-live test runs against —
// the Elixir control plane (cloud-9) is not built yet, so the Go client seam is
// stubbed here. Register records the LiveServer; Registered reads them back.
// Safe for sequential test use (one go-live at a time — YAGNI on locking).
type FakeRegistry struct {
	servers []LiveServer
}

// NewFakeRegistry returns an empty in-memory registry.
func NewFakeRegistry() *FakeRegistry { return &FakeRegistry{} }

// Register records srv. The real control-plane Register will POST to the Elixir
// API; here it just appends.
func (r *FakeRegistry) Register(_ context.Context, srv LiveServer) error {
	r.servers = append(r.servers, srv)
	return nil
}

// Registered returns the servers recorded so far, in registration order.
func (r *FakeRegistry) Registered() []LiveServer {
	out := make([]LiveServer, len(r.servers))
	copy(out, r.servers)
	return out
}

// Has reports whether a server with the given FQDN was registered.
func (r *FakeRegistry) Has(fqdn string) bool {
	for _, s := range r.servers {
		if s.FQDN == fqdn {
			return true
		}
	}
	return false
}

// compile-time assertions that the concrete types satisfy their seams.
var (
	_ RegistryClient = (*FakeRegistry)(nil)
	_ StepRunner     = realStepRunner{}
	_ CaddyStepper   = defaultCaddySteps{}
)
