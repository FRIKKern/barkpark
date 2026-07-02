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
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// adminTokenAlphabet is the EXACT shape setup.GenerateAdminToken mints:
// bp_admin_ + base64url (no padding). It deliberately excludes the shell/elixir
// metacharacters (quotes, $, ;, backticks) so single-quoting the token into the
// admin-token step's script + elixir literal is injection-safe. validateAdminToken
// asserts a token matches before it is interpolated, so a future change to the
// token generator that introduced an unsafe char fails loudly here rather than
// shelling out a malformed (or injected) command on the box.
var adminTokenAlphabet = regexp.MustCompile(`^bp_admin_[A-Za-z0-9_-]+$`)

// validateAdminToken rejects a token that carries a character outside the safe
// alphabet — the assert-the-alphabet guard before single-quoting the token into
// the shell + elixir of the admin-token step.
func validateAdminToken(token string) error {
	if !adminTokenAlphabet.MatchString(token) {
		return fmt.Errorf("admin token has an unexpected shape (want bp_admin_<base64url>); refusing to interpolate it into a shell command")
	}
	return nil
}

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
	// Redact lists secret substrings (e.g. a minted admin token) that MUST be
	// scrubbed from any captured remote output before it is wrapped into an
	// error. The SSH/real runners capture stdout+stderr and surface it in the
	// returned error; without this, a step whose script echoes a secret on
	// failure would leak it into the worker's fail() POST and the journal. The
	// admin-token step populates this with the token; non-secret steps leave it
	// empty.
	Redact []string
	// RedactEnvSecrets, when true, runs PATTERN-based scrubbing over captured
	// output in addition to the literal Redact substrings — for steps that source
	// /opt/barkpark/.env (`set -a; . /opt/barkpark/.env; set +a`) and could echo a
	// DB password / SECRET_KEY_BASE / BARKPARK_CLOAK_KEY / PREVIEW_JWT_SECRET on
	// failure. The worker NEVER knows these VALUES (they are generated on the box),
	// so a literal Redact can't catch them; scrubEnvSecrets matches their SHAPE.
	// Set true on the migrate step (and any other .env-sourcing step).
	RedactEnvSecrets bool
}

// scrubSecrets replaces every non-empty substring in redact with a fixed
// placeholder so a captured-output error never carries a secret. It is the
// per-step redaction the SSH/real runners apply BEFORE fmt.Errorf.
func scrubSecrets(out string, redact []string) string {
	for _, secret := range redact {
		if secret == "" {
			continue
		}
		out = strings.ReplaceAll(out, secret, "[REDACTED]")
	}
	return out
}

// ectoUserinfoRe matches the userinfo of an ecto/postgres URL — the
// `<user>:<pass>@` after the scheme — so a leaked DATABASE_URL value
// (ecto://user:PASS@host/db) never carries the password into an error. Both the
// ecto:// scheme deploy.sh uses and the postgres(ql):// shapes are covered.
var ectoUserinfoRe = regexp.MustCompile(`(ecto|postgres|postgresql)://[^\s:/@]+:[^\s@]+@`)

// envSecretAssignRe matches `KEY=<non-space-run>` for the secret-shaped env keys
// the migrate/admin-token scripts source from /opt/barkpark/.env. The worker
// does not know the VALUES (generated on the box), so this redacts by KEY name +
// the value's shape (a run of non-whitespace) rather than by exact match.
var envSecretAssignRe = regexp.MustCompile(`(SECRET_KEY_BASE|BARKPARK_CLOAK_KEY|PREVIEW_JWT_SECRET|DATABASE_URL)=\S+`)

// scrubEnvSecrets is the PATTERN-based companion to scrubSecrets: it redacts
// secret-SHAPED substrings the worker can't enumerate because their values are
// generated on the box. A step that sources /opt/barkpark/.env can echo a DB
// password or a signing/encryption key on failure, and that captured output
// flows raw through worker.fail() into the persisted provision_jobs.error column
// + the worker's stderr — so a migrate failure would leak prod secrets. This is
// applied (alongside the literal scrubSecrets) when CaddyStep.RedactEnvSecrets is
// set. It redacts:
//
//   - ecto/postgres URL userinfo:  ecto://user:PASS@host  →  ecto://[REDACTED]@host
//   - the secret env assignments:  SECRET_KEY_BASE=…       →  SECRET_KEY_BASE=[REDACTED]
//     (also BARKPARK_CLOAK_KEY, PREVIEW_JWT_SECRET, DATABASE_URL)
func scrubEnvSecrets(out string) string {
	out = ectoUserinfoRe.ReplaceAllStringFunc(out, func(m string) string {
		// m is "<scheme>://user:pass@" — keep the scheme, redact the userinfo.
		scheme := m[:strings.Index(m, "://")]
		return scheme + "://[REDACTED]@"
	})
	out = envSecretAssignRe.ReplaceAllStringFunc(out, func(m string) string {
		key := m[:strings.IndexByte(m, '=')]
		return key + "=[REDACTED]"
	})
	return out
}

// scrubStepOutput applies BOTH the literal per-step redaction (the minted admin
// token et al.) AND, when the step sources .env, the pattern-based env-secret
// scrub — the single place the SSH/real runners funnel captured output through
// before it is wrapped into an error.
func scrubStepOutput(out string, s CaddyStep) string {
	out = scrubSecrets(out, s.Redact)
	if s.RedactEnvSecrets {
		out = scrubEnvSecrets(out)
	}
	return out
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
	// Pool is the warm-host source for the warm-pool Provision path. The per-job
	// ProvisionOneShot path does NOT use it (it creates one server directly via
	// Provider), so a one-shot caller leaves Pool nil and sets Provider instead.
	Pool *Pool
	// Provider is the cloud provider ProvisionOneShot creates + deletes its single
	// server through. Only the one-shot path needs it; the warm-pool path acquires
	// hosts via Pool.pop instead and may leave Provider nil.
	Provider CloudProvider
	DNS      DNSProvider
	Caddy    CaddyStepper

	// RunnerFor builds the StepRunner for an assigned host's IP. This is the
	// PER-HOST seam: the Caddy/TLS + migrate steps must run ON the provisioned
	// instance, so the runner can only be built once a host is popped (step 1).
	// Production defaults to an SSHStepRunner factory (NewSSHStepRunner) that SSHes
	// into the host; tests inject a factory returning a recording runner. When nil,
	// withDefaults fills it — preferring the host-agnostic Runner below for
	// back-compat if one is set, else the SSH factory.
	RunnerFor func(host string) StepRunner

	// Runner is the LEGACY host-agnostic runner seam. It predates RunnerFor and is
	// kept for back-compat: when set and RunnerFor is nil, withDefaults wraps it in
	// a factory that ignores the host (the old behaviour — handy for a fake that
	// does not care which host it targets). New code should inject RunnerFor.
	Runner StepRunner

	Health   HealthChecker
	Registry RegistryClient
	Secrets  SecretGen

	// MigrateArgv is the `mix ecto.migrate` argv the migrate step carries. It is
	// NOT executed in tests (the fake runner records it); the real runner shells
	// it out on the box. Empty → defaultMigrateArgv.
	MigrateArgv []string

	// DeleteRetryBackoff overrides the pause between teardown Delete retries in
	// cleanupHost. Zero → the production deleteRetryBackoff (~1s). Tests set a tiny
	// value so the retry path runs fast; production leaves it zero.
	DeleteRetryBackoff time.Duration

	// HealthPollInterval is the gap between health-gate probes in configureHost's
	// BOUNDED poll (F2). On a cold provision the box's DNS has not propagated to the
	// public resolver and Caddy has not yet obtained the Let's Encrypt cert via ACME,
	// so the first https://<fqdn> probe almost always fails — a single-shot gate
	// would fail-closed and tear the (paid) box down. Zero → healthPollInterval
	// (~10s). Tests set a tiny value so the retry-then-succeed / deadline paths run
	// without real sleeps.
	HealthPollInterval time.Duration
	// HealthPollDeadline bounds how long configureHost retries the health gate before
	// failing closed (F2). It must be generous enough to cover DNS propagation + a
	// cold ACME issuance (tens of seconds to a couple minutes) but is NOT unbounded —
	// past the deadline the chain fails closed and the caller tears the box down.
	// Zero → healthPollDeadline (~4m). Tests set a tiny value.
	HealthPollDeadline time.Duration
}

// healthInterval returns the gap between health-gate probes: the injected override
// when set, else the production healthPollInterval. Lets tests poll fast.
func (wp *WarmPool) healthInterval() time.Duration {
	if wp.HealthPollInterval > 0 {
		return wp.HealthPollInterval
	}
	return healthPollInterval
}

// healthDeadline returns the total budget for the bounded health poll: the injected
// override when set, else the production healthPollDeadline.
func (wp *WarmPool) healthDeadline() time.Duration {
	if wp.HealthPollDeadline > 0 {
		return wp.HealthPollDeadline
	}
	return healthPollDeadline
}

// healthPollInterval is the default gap between health-gate probes when
// WarmPool.HealthPollInterval is zero — ~10s, frequent enough that a box that
// becomes ready early is registered promptly, sparse enough to not hammer ACME.
const healthPollInterval = 10 * time.Second

// healthPollDeadline is the default total budget for the bounded health poll when
// WarmPool.HealthPollDeadline is zero. A cold provision must clear DNS propagation
// to the public resolver AND a first-time Let's Encrypt ACME issuance before
// https://<fqdn> verifies; 4 minutes covers the common case with headroom while
// still bounding the wait so a genuinely-broken box fails closed rather than
// hanging the worker forever.
const healthPollDeadline = 4 * time.Minute

// pollHealth runs the health gate against target on a BOUNDED poll: it probes
// immediately, and on a not-ready result (a non-nil error OR a non-OK report)
// retries every healthInterval until healthDeadline elapses, returning as SOON as
// the gate passes. This tolerates the cold-provision window where DNS has not yet
// propagated to the public resolver and Caddy has not yet obtained the ACME cert —
// connection/TLS/DNS errors all surface as a gate error, which is treated as
// not-ready-yet rather than a hard failure. It FAILS CLOSED only after the
// deadline (returning the last error / the last report's failures), and it NEVER
// loops unbounded. ctx cancellation aborts the wait between probes.
func (wp *WarmPool) pollHealth(ctx context.Context, target, token string) (setup.HealthReport, error) {
	deadline := time.Now().Add(wp.healthDeadline())
	interval := wp.healthInterval()
	var lastReport setup.HealthReport
	var lastErr error
	for {
		report, err := wp.Health(ctx, target, token)
		if err == nil && report.OK {
			return report, nil // ready — register can proceed
		}
		lastReport, lastErr = report, err

		// Out of budget? Stop polling and fail closed. (Checked AFTER a probe so the
		// gate is always attempted at least once, even with a zero/short deadline.)
		if !time.Now().Before(deadline) {
			break
		}
		select {
		case <-ctx.Done():
			return lastReport, ctx.Err()
		case <-time.After(interval):
		}
	}
	if lastErr != nil {
		return lastReport, lastErr
	}
	return lastReport, fmt.Errorf("health gate not ready after %s: %s", wp.healthDeadline(), strings.Join(lastReport.Failures(), ", "))
}

// deleteBackoff returns the per-retry teardown pause: the injected override when
// set, else the production deleteRetryBackoff. Lets tests run the retry path fast.
func (wp *WarmPool) deleteBackoff() time.Duration {
	if wp.DeleteRetryBackoff > 0 {
		return wp.DeleteRetryBackoff
	}
	return deleteRetryBackoff
}

// defaultMigrateArgv is the migrate command the migrate step runs on the box:
// `mix ecto.migrate` under the app's release env. It sources asdf first because
// the deploy.sh image puts asdf on PATH via ~/.bashrc, which Ubuntu's default
// .bashrc SKIPS for non-interactive shells — and the SSH runner's `bash -l` is
// non-interactive, so without this `mix` is not found (exit 127). Recorded (not
// executed) by the fake runner in tests.
func defaultMigrateArgv() []string {
	return []string{"bash", "-lc", "set -a; . /opt/barkpark/.env; set +a; . /root/.asdf/asdf.sh && cd /opt/barkpark/api && mix ecto.migrate"}
}

// adminTokenStep builds the per-instance step that makes token THE admin token on
// the box: it revokes any pre-existing admin tokens (the baked image seeded a
// random one) then mints token under the Default tenancy scope via the public
// Barkpark.Auth API. The token rides in through the BP_TOK env so it never lands
// in the step Title/Cmd (which may be narrated/logged) — only in the Argv the SSH
// runner base64-encodes and sends. asdf is sourced (the SSH runner's `bash -l` is
// non-interactive, so Ubuntu's .bashrc skips asdf → mix would be exit 127).
func adminTokenStep(token string) CaddyStep {
	// FAIL LOUD: create_token must return {:ok, _} or the step halts non-zero so
	// the chain fails closed — a swallowed error would brick the instance to ZERO
	// admin tokens (we revoked the baked one first, so there is no fallback). The
	// error branch IO.inspect's only the create_token RESULT (an :error tuple /
	// changeset) — NEVER the token itself — so the failure is diagnosable without
	// leaking the secret into stderr/journal.
	const elixir = `scope = Barkpark.Seeds.Shared.ensure_default_scope(); ` +
		`Barkpark.Auth.list_tokens(scope.dataset) |> Enum.filter(&Barkpark.Auth.has_permission?(&1, "admin")) |> Enum.each(&Barkpark.Auth.revoke_token/1); ` +
		`case Barkpark.Auth.create_token(System.fetch_env!("BP_TOK"), "barkpark cloud admin", scope.dataset, ["read", "write", "admin"], scope.workspace_id) do {:ok, _} -> :ok; other -> IO.inspect(other, label: "admin-token create failed"); System.halt(1) end`
	script := `set -a; . /opt/barkpark/.env; set +a; export BP_TOK='` + token + `'; . /root/.asdf/asdf.sh && cd /opt/barkpark/api && mix run -e '` + elixir + `'`
	return CaddyStep{
		Title: "install the minted admin token",
		Cmd:   "install admin token (value redacted)",
		Argv:  []string{"bash", "-lc", script},
		// The token rides in the Argv (base64'd over SSH); scrub it from any
		// captured output so a step failure never surfaces the bp_admin_ value.
		Redact: []string{token},
		// This step also `. /opt/barkpark/.env`, so a failure could echo the DB
		// password / SECRET_KEY_BASE / cloak key. Pattern-scrub those too.
		RedactEnvSecrets: true,
	}
}

// secretKeyBaseAlphabet is the safe shape a SECRET_KEY_BASE must match before it
// is single-quoted into the secret-install step's shell script. defaultSecretGen
// mints a base64url value (chars [A-Za-z0-9_-]); the `+/=` are tolerated too so a
// real `mix phx.gen.secret` (standard base64) value also passes. It deliberately
// excludes the shell/quote metacharacters (space, $, ;, backticks, single quote)
// so single-quoting the secret into the script is injection-safe.
var secretKeyBaseAlphabet = regexp.MustCompile(`^[A-Za-z0-9_+/=-]+$`)

// validateSecretKeyBase rejects an empty or unsafe-shaped secret — the
// assert-the-alphabet guard before single-quoting the value into the shell of the
// secret-install step. A future change to the secret generator that introduced an
// unsafe char fails loudly here rather than shelling out a malformed (or injected)
// command on the box, mirroring validateAdminToken.
func validateSecretKeyBase(secret string) error {
	if secret == "" {
		return fmt.Errorf("secret key base is empty; refusing to install a blank Phoenix signing secret")
	}
	if !secretKeyBaseAlphabet.MatchString(secret) {
		return fmt.Errorf("secret key base has an unexpected shape; refusing to interpolate it into a shell command")
	}
	return nil
}

// secretKeyBaseStep builds the per-instance step that installs the MINTED
// SECRET_KEY_BASE into /opt/barkpark/.env and restarts Barkpark so Phoenix runs on
// its OWN signing secret. Without this every instance keeps the SECRET_KEY_BASE
// BAKED into the warm image, so all tenants share ONE Phoenix signing secret — a
// cross-tenant session/token forgery hole. The secret rides in via the BP_SKB env
// so it never lands in the step Title/Cmd (which may be narrated/logged) — only in
// the Argv the SSH runner base64-encodes and sends, mirroring adminTokenStep. The
// .env edit is idempotent: grep -v strips any existing SECRET_KEY_BASE= line, the
// minted value is appended from $BP_SKB via printf "%s" (never interpolated into
// the script TEXT), and the file is swapped in with mv — so re-running the chain
// never duplicates the line. The restart makes Phoenix re-read the secret at boot
// (it reads SECRET_KEY_BASE once at startup, exactly like PHX_HOST).
func secretKeyBaseStep(secret string) CaddyStep {
	const envFile = "/opt/barkpark/.env"
	script := `export BP_SKB='` + secret + `'; ` +
		`touch ` + envFile + `; ` +
		`grep -v '^SECRET_KEY_BASE=' ` + envFile + ` > ` + envFile + `.bpnew || true; ` +
		`printf 'SECRET_KEY_BASE=%s\n' "$BP_SKB" >> ` + envFile + `.bpnew; ` +
		`mv ` + envFile + `.bpnew ` + envFile + `; ` +
		`systemctl restart barkpark`
	return CaddyStep{
		Title: "install the minted SECRET_KEY_BASE + restart Barkpark",
		Cmd:   "install per-instance SECRET_KEY_BASE (value redacted) + systemctl restart barkpark",
		Argv:  []string{"bash", "-lc", script},
		// The secret rides in the Argv (base64'd over SSH); scrub it from any
		// captured output so a step failure never surfaces the SECRET_KEY_BASE value.
		Redact: []string{secret},
		// This step rewrites .env; a failure could echo other secret-shaped lines
		// (DATABASE_URL, cloak key) from grep/printf. Pattern-scrub those too.
		RedactEnvSecrets: true,
	}
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
// go-live needs. StubsOptional is true because the agent + backup endpoints are
// cloud-9/10 and not deployed on instances yet — requiring them would fail-close
// EVERY go-live. The real checks (API up, studio, websocket-not-403, TLS, and
// the token-gated Postgres read) still gate hard. Once cloud-9/10 ship, wire the
// real AgentStatusURL/BackupStatusURL here and they enforce automatically.
func defaultHealthChecker(ctx context.Context, base, token string) (setup.HealthReport, error) {
	return setup.RunHealthGate(base, token, setup.HealthGate{StubsOptional: true})
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
	if wp.RunnerFor == nil {
		if wp.Runner != nil {
			// Back-compat: a legacy host-agnostic Runner was injected — wrap it in a
			// factory that ignores the host. Lets old callers (and fakes that don't
			// care which host they target) keep working unchanged.
			runner := wp.Runner
			wp.RunnerFor = func(string) StepRunner { return runner }
		} else {
			// Production default: SSH into the assigned host for every step.
			wp.RunnerFor = func(host string) StepRunner { return NewSSHStepRunner(host) }
		}
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
	if out, err := runCapture(ctx, s.Argv[0], s.Argv[1:]...); err != nil {
		return fmt.Errorf("caddy step %q: %w: %s", s.Title, err, strings.TrimSpace(scrubStepOutput(out, s)))
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

	// 2-7. configure the popped host through the shared go-live chain (secrets →
	// dns → caddy → migrate → admin-token → health → register).
	live, err := wp.configureHost(ctx, host, spec)
	if err != nil {
		return LiveServer{}, err
	}

	// 8. replacement — already triggered by pop in step 1; the pool is warm.
	return live, nil
}

// ProvisionOneShot is the PER-JOB go-live path: create exactly ONE server with a
// globally-unique name, configure it through the same chain Provision uses, and
// return the verified LiveServer. Unlike Provision it is NOT warm-pool-backed —
// there is no pool, no pop, and no refill, so a long-lived worker can call it
// once PER JOB without the warm-N name collision (job #2 re-creating warm-1) or
// the orphan replacement the pool refill leaves behind.
//
// The server NAME is made GLOBALLY unique via oneShotServerName(spec.Name): a
// bp-<sanitized-slug>-<crypto/rand suffix>. The crypto suffix guards the Hetzner
// duplicate-name path even if two jobs ever carried an identical subdomain.
// NOTE: the DNS FQDN (<spec.Name>.<zone>) is ALSO globally unique now — the
// control plane allocates a <slug>-<teamid> provisioning_subdomain before queuing
// the job, so spec.Name already carries the team-scoped, globally-unique
// subdomain. The NAME suffix is the second, independent uniqueness guard.
//
// CLEANUP ON FAILURE: once the server exists, ANY later step failing (dns, caddy,
// migrate, admin-token, health, register) deletes the server AND the DNS A record
// using a FRESH, bounded context — so a cancelled/timed-out job ctx still gets to
// tear down its half-built box and leave ZERO orphans. On success exactly ONE
// server remains. (Ported from the live harness's deferred cleanup idea.)
func (wp *WarmPool) ProvisionOneShot(ctx context.Context, spec GoLiveSpec) (LiveServer, error) {
	wp.withDefaults()
	if wp.Provider == nil {
		return LiveServer{}, fmt.Errorf("warmpool: a CloudProvider must be injected for one-shot provisioning")
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

	// 1. create — exactly ONE server, globally-unique name from the job. Walk the
	// resilience ladder so a sold-out preferred type still lands a box.
	createSpec := spec.Spec
	createSpec.Name = oneShotServerName(spec.Name)
	host, _, err := CreateWithFallback(ctx, wp.Provider, createSpec)
	if err != nil {
		return LiveServer{}, fmt.Errorf("create %q: %w", createSpec.Name, err)
	}

	// 1b. stamp the box's public FQDN as the barkpark-fqdn label — the box's stable
	// per-instance IDENTITY. A later user-initiated Remove resolves WHICH box to
	// delete by matching this label (see DeprovisionByIP), never the IP alone,
	// because Hetzner reuses freed IPs across boxes. FAIL CLOSED: an un-labelable
	// box can't be safely removed later (its IP could be reused by another tenant),
	// so tear it down now rather than leak an unidentifiable billed orphan.
	if lerr := wp.labelFQDN(ctx, host.Name, spec.fqdn()); lerr != nil {
		if cerr := wp.cleanupHost(host, spec); cerr != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: %v\n", cerr)
		}
		return LiveServer{}, fmt.Errorf("label fqdn %q: %w", spec.fqdn(), lerr)
	}

	// 1c. reap leaked predecessors (dwb-11): any OTHER managed box carrying THIS
	// fqdn label is, by construction, a half-built box a CRASHED prior attempt
	// left behind (a worker that died mid-provision runs no teardown, and such a
	// box is never orphan-labeled, so neither SweepOrphans nor DeprovisionByIP —
	// which requires an IP match — would ever recover it: it would bill forever).
	// Safe to delete: the fqdn is the instance's globally-unique identity, the
	// stale-claim threshold guarantees the prior worker is no longer live (a fresh
	// claim is never re-handed out inside the provision timeout), and the FQDN is
	// only re-usable after the old box was already deleted by a deprovision.
	// Best-effort: a reap failure must not fail THIS (about-to-be-good) provision
	// — it is logged, and the box stays a candidate for the next attempt's reap.
	if rerr := wp.reapLeakedPredecessors(ctx, spec.fqdn(), host.Name); rerr != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: %v\n", rerr)
	}

	// 2-7. configure the created host through the shared chain. On ANY failure
	// after the server exists, tear it down (server + DNS) so no orphan remains.
	live, err := wp.configureHost(ctx, host, spec)
	if err != nil {
		// Log a FAILED cleanup (a swallowed teardown silently orphans a billed
		// box). The provision error is what the caller acts on, but a leaked server
		// must be observable in the worker journal — mirror how the worker logs.
		if cerr := wp.cleanupHost(host, spec); cerr != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: %v\n", cerr)
		}
		return LiveServer{}, err
	}
	return live, nil
}

// sshReadyWaiter is the optional capability a per-host runner advertises when it
// can probe SSH readiness. The production SSHStepRunner implements it; the test
// fakes don't, so the readiness wait is simply skipped for them (no boot in tests).
type sshReadyWaiter interface {
	WaitReady(ctx context.Context, timeout time.Duration) error
}

// sshReadyTimeout bounds how long configureHost waits for a freshly-created box to
// accept SSH before failing closed. A snapshot boot is ~30-60s; 3 min is generous.
const sshReadyTimeout = 3 * time.Minute

// configureHost runs the shared go-live chain on an ALREADY-ACQUIRED host (popped
// from the warm pool, or freshly created one-shot): secrets → dns → caddy →
// migrate → admin-token → secret-key-base → health → register. The health gate is
// a BOUNDED poll (F2) so a cold provision's DNS/ACME warm-up doesn't fail it
// spuriously. It FAILS CLOSED — a never-ready health gate
// returns the gate error and does NOT register the server. The caller owns the
// host's lifecycle (warm-pool leaves it; one-shot tears it down on the returned
// error).
func (wp *WarmPool) configureHost(ctx context.Context, host Server, spec GoLiveSpec) (LiveServer, error) {
	// Build the runner for THIS host — the Caddy/TLS + migrate steps run ON the
	// acquired instance (over SSH in production), not on the worker. The host IP
	// is only known once the host is acquired, which is why the runner is a
	// per-host factory rather than a fixed field.
	runner := wp.RunnerFor(host.IP)

	// 1b. wait for sshd — a freshly-created one-shot box isn't SSH-ready the instant
	// create returns (OS still booting), and the very first step below SSHes in, so
	// poll until the box accepts SSH or fail closed. A warm-pool host is already
	// booted, so the first probe returns immediately. Runners that don't support a
	// readiness probe (the test fakes) skip it. On timeout the caller (one-shot)
	// tears the box down — no orphan.
	if rw, ok := runner.(sshReadyWaiter); ok {
		if err := rw.WaitReady(ctx, sshReadyTimeout); err != nil {
			return LiveServer{}, fmt.Errorf("ssh not ready on %s: %w", host.IP, err)
		}
	}

	// 2. secrets — mint per-instance credentials.
	secrets, err := wp.Secrets()
	if err != nil {
		return LiveServer{}, fmt.Errorf("secrets: %w", err)
	}

	// 3. dns — point <name>.<zone> at the acquired host IP. spec.Name is the
	// control-plane-allocated provisioning_subdomain (<slug>-<teamid>), which is
	// already GLOBALLY unique — two teams that picked the same slug get distinct
	// FQDNs, so there is no cross-team A-record clobber. (The server NAME carries an
	// additional crypto/rand suffix from oneShotServerName as a second guard.)
	rec := Record{Zone: spec.Zone, Name: spec.Name, Type: "A", Value: host.IP}
	if err := wp.DNS.UpsertRecord(ctx, rec); err != nil {
		return LiveServer{}, fmt.Errorf("dns: upsert %s: %w", spec.fqdn(), err)
	}

	// 4. caddy — run the TLS/PHX_HOST steps ON the acquired host via the per-host runner.
	for _, s := range wp.Caddy.Steps(spec.Name, spec.Zone, spec.App) {
		if err := runner.Run(ctx, s); err != nil {
			return LiveServer{}, fmt.Errorf("caddy: %w", err)
		}
	}

	// 5. migrate — run the mix ecto.migrate step through the same per-host runner.
	// RedactEnvSecrets: the step does `. /opt/barkpark/.env`, so a migrate failure
	// could echo DATABASE_URL (with the DB password), SECRET_KEY_BASE, the cloak
	// key, or PREVIEW_JWT_SECRET into captured output → worker.fail() → the
	// persisted error column. Pattern-scrub them (the worker can't enumerate the
	// values; they're generated on the box).
	migrate := CaddyStep{Title: "run database migrations (mix ecto.migrate)", Cmd: strings.Join(wp.MigrateArgv, " "), Argv: wp.MigrateArgv, RedactEnvSecrets: true}
	if err := runner.Run(ctx, migrate); err != nil {
		return LiveServer{}, fmt.Errorf("migrate: %w", err)
	}

	// 5b. admin token — install the minted AdminToken as THE admin token on the
	// instance: the health gate's token-gated check uses it, and the customer
	// needs it to use their Barkpark. The baked image already seeded a random
	// admin token, so we revoke existing admin tokens first, then mint ours under
	// the default scope. Sources asdf (non-interactive ssh shell skips ~/.bashrc).
	// The token rides in via env (BP_TOK) so it never lands in a logged Title/Cmd;
	// the SSH runner base64s the whole script, so the nested quotes survive.
	if err := validateAdminToken(secrets.AdminToken); err != nil {
		return LiveServer{}, fmt.Errorf("admin-token: %w", err)
	}
	if err := runner.Run(ctx, adminTokenStep(secrets.AdminToken)); err != nil {
		return LiveServer{}, fmt.Errorf("admin-token: %w", err)
	}

	// 5c. secret-key-base — install the minted per-instance SECRET_KEY_BASE into the
	// app .env and restart Barkpark so Phoenix runs on its OWN signing secret. The
	// warm image bakes a SECRET_KEY_BASE that EVERY instance would otherwise keep, so
	// all tenants would share one signing secret => cross-tenant session/token
	// forgery. This runs LAST before the health gate so the restarted app is already
	// on its own secret when the gate (and its token-gated probe) hits it. The secret
	// rides in via env (BP_SKB) so it never lands in a logged Title/Cmd; the SSH
	// runner base64s the whole script, so the quoting survives.
	if err := validateSecretKeyBase(secrets.SecretKeyBase); err != nil {
		return LiveServer{}, fmt.Errorf("secret-key-base: %w", err)
	}
	if err := runner.Run(ctx, secretKeyBaseStep(secrets.SecretKeyBase)); err != nil {
		return LiveServer{}, fmt.Errorf("secret-key-base: %w", err)
	}

	// 6. health — FAIL CLOSED, on a BOUNDED poll (F2). A cold provision's DNS has not
	// propagated to the public resolver and Caddy has not yet obtained the ACME cert,
	// so the first https://<fqdn> probe usually fails; pollHealth retries on a fixed
	// interval up to a deadline and succeeds as soon as the gate passes, treating
	// connection/TLS/DNS errors as not-ready-yet. It fails closed ONLY after the
	// deadline — a red/never-ready gate stops the chain before register.
	report, err := wp.pollHealth(ctx, spec.healthTarget(), secrets.AdminToken)
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
	return live, nil
}

// deleteRetries is how many EXTRA times cleanupHost retries provider.Delete (after
// the first attempt) before giving up and marking the box orphaned. A transient
// Hetzner blip (a 5xx / rate-limit on delete) self-heals within these few tries,
// so a healthy account never reaches the orphan-marking path.
const deleteRetries = 2

// deleteRetryBackoff is the fixed pause between teardown Delete retries — short,
// because the box is billing and the teardown context is bounded by cleanupTimeout.
const deleteRetryBackoff = 1 * time.Second

// cleanupHost tears down a one-shot host whose provision failed AFTER the server
// existed: delete the DNS A record and the server, using a FRESH bounded context
// so a cancelled/timed-out job ctx still completes the teardown. Best-effort — it
// attempts BOTH deletes even if one fails (the goal is zero orphans, not a clean
// error). DeleteRecord is idempotent (a no-op when the record was never written),
// so calling it before the dns step ran is harmless.
//
// SERVER DELETE retries deleteRetries+1 times with a short backoff so a transient
// Hetzner Delete blip self-heals rather than leaking a billed box. If Delete STILL
// fails after the retries, the box is best-effort marked barkpark-orphaned=true
// (plus its FQDN) so SweepOrphans can recover it + its DNS on a later cycle — the
// double-failure (succeed-report failed → teardown → Delete failed) auto-recovery
// path. The orphan label is set ONLY here, so a labeled box is definitively meant
// to be gone; SweepOrphans never touches a managed-but-not-orphaned box.
//
// It RETURNS an aggregated error of whatever failed (nil on a clean teardown)
// instead of swallowing it: a failed server Delete silently orphans a BILLED box,
// which must be observable. ProvisionOneShot logs the returned error to stderr so
// a failed cleanup is detectable in the worker journal.
func (wp *WarmPool) cleanupHost(host Server, spec GoLiveSpec) error {
	cctx, cancel := context.WithTimeout(context.Background(), cleanupTimeout)
	defer cancel()
	var errs []string
	// DNS first (cheap, no dependency), then the server.
	if err := wp.DNS.DeleteRecord(cctx, spec.Zone, spec.Name, "A"); err != nil {
		errs = append(errs, fmt.Sprintf("delete DNS %s A: %v", spec.fqdn(), err))
	}
	if wp.Provider != nil && host.Name != "" {
		delErr := wp.deleteWithRetry(cctx, host.Name)
		if delErr != nil {
			// Delete persistently failed: a billed orphan the control plane is blind to.
			// Best-effort mark it orphaned (+ its FQDN) so SweepOrphans recovers it
			// later; a marking failure is logged into the error, never blocks.
			markErr := wp.markOrphaned(cctx, host.Name, spec.fqdn())
			msg := fmt.Sprintf("delete server %s (BILLED ORPHAN): %v", host.Name, delErr)
			if markErr != nil {
				msg += fmt.Sprintf("; AND failed to mark it orphaned for the sweep (manual cleanup needed): %v", markErr)
			} else {
				msg += "; marked barkpark-orphaned=true for the sweep to recover"
			}
			errs = append(errs, msg)
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("cleanup of %s incomplete: %s", spec.fqdn(), strings.Join(errs, "; "))
	}
	return nil
}

// deleteWithRetry calls provider.Delete up to deleteRetries+1 times with a short
// backoff, returning nil on the first success and the LAST error if every attempt
// failed. The backoff honours ctx cancellation so a wedged teardown context does
// not stall here. A transient Hetzner blip self-heals within the retries; a
// persistent failure falls through to the orphan-marking path.
func (wp *WarmPool) deleteWithRetry(ctx context.Context, name string) error {
	var lastErr error
	for attempt := 0; attempt <= deleteRetries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(wp.deleteBackoff()):
			}
		}
		if lastErr = wp.Provider.Delete(ctx, name); lastErr == nil {
			return nil // delete succeeded (possibly on a retry) — no orphan
		}
	}
	return lastErr
}

// labelFQDN stamps the box's public FQDN as the barkpark-fqdn label so a later
// user-initiated Remove can confirm box IDENTITY before deleting it (the IP alone
// is not safe — Hetzner reuses freed IPs across boxes). Unlike markOrphaned's
// best-effort labeling, this is a HARD requirement: a provider that cannot label,
// or a failed label call, is returned as an error so ProvisionOneShot fails closed
// and tears the box down rather than registering an un-removable instance.
func (wp *WarmPool) labelFQDN(ctx context.Context, name, fqdn string) error {
	labeler, ok := wp.Provider.(ServerLabeler)
	if !ok {
		return fmt.Errorf("provider cannot label servers — cannot stamp the FQDN identity a safe Remove needs")
	}
	return labeler.LabelServer(ctx, name, FQDNLabelKey, fqdn)
}

// markOrphaned best-effort stamps barkpark-orphaned=true (and the box's FQDN) on a
// box whose Delete persistently failed, so SweepOrphans can delete it + its DNS
// record on a later cycle. It is the recovery flag for the double-failure path. A
// provider that can't label (no ServerLabeler) yields a clear error the caller
// folds into its message — the box is then a true manual-cleanup orphan. Setting
// BOTH labels is attempted even if the first fails (best-effort), and any failure
// is aggregated and returned (never panics, never blocks teardown).
func (wp *WarmPool) markOrphaned(ctx context.Context, name, fqdn string) error {
	labeler, ok := wp.Provider.(ServerLabeler)
	if !ok {
		return fmt.Errorf("provider does not support labeling — cannot mark orphaned")
	}
	var errs []string
	if err := labeler.LabelServer(ctx, name, OrphanedLabelKey, orphanedLabelVal); err != nil {
		errs = append(errs, fmt.Sprintf("%s: %v", OrphanedLabelKey, err))
	}
	// Record the FQDN so SweepOrphans can also delete the stranded DNS record. A
	// label value must be DNS/label-safe — the fqdn already is.
	if fqdn != "" {
		if err := labeler.LabelServer(ctx, name, FQDNLabelKey, fqdn); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", FQDNLabelKey, err))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return nil
}

// reapLeakedPredecessors deletes every managed box (other than keepName) whose
// barkpark-fqdn label equals fqdn — the recovery for a WORKER CRASH mid-provision
// (dwb-11). A worker that dies hard (OOM, kill -9, host reboot) between create
// and its own teardown leaves a half-built box that is NEITHER orphan-labeled
// (cleanupHost never ran) NOR reachable by DeprovisionByIP (the control plane
// never learned its IP), so nothing else can ever reap it. Because the fqdn is
// the instance's globally-unique identity — stamped fail-closed at create and
// freed only after a completed deprovision — any same-fqdn box that is not the
// one we just created is definitively a dead prior attempt of THIS instance.
//
// Delete-first with the same retry ladder cleanupHost uses; a persistent delete
// failure falls back to markOrphaned so SweepOrphans recovers the box later. The
// DNS record is deliberately NOT touched — it belongs to the instance identity
// the CURRENT (surviving) attempt is about to configure. Failures are aggregated
// and returned for logging; the caller treats the reap as best-effort.
func (wp *WarmPool) reapLeakedPredecessors(ctx context.Context, fqdn, keepName string) error {
	lister, ok := wp.Provider.(LabelLister)
	if !ok || fqdn == "" {
		return nil // no label-listing capability (tests/minimal providers) → nothing to reap
	}

	rctx, cancel := context.WithTimeout(ctx, cleanupTimeout)
	defer cancel()

	managed, err := lister.ListByLabel(rctx, ManagedLabelKey, managedLabelVal)
	if err != nil {
		return fmt.Errorf("reap predecessors of %s: list managed: %w", fqdn, err)
	}

	var errs []string
	for _, s := range managed {
		if s.Name == keepName || s.Labels[FQDNLabelKey] != fqdn {
			continue
		}
		if derr := wp.deleteWithRetry(rctx, s.Name); derr != nil {
			msg := fmt.Sprintf("delete leaked predecessor %s (BILLED ORPHAN): %v", s.Name, derr)
			if merr := wp.markOrphaned(rctx, s.Name, fqdn); merr != nil {
				msg += fmt.Sprintf("; AND failed to mark it orphaned for the sweep (manual cleanup needed): %v", merr)
			} else {
				msg += "; marked barkpark-orphaned=true for the sweep to recover"
			}
			errs = append(errs, msg)
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("reap predecessors of %s incomplete: %s", fqdn, strings.Join(errs, "; "))
	}
	return nil
}

// CleanupHost is the EXPORTED teardown the worker calls when a box is live but
// the control plane was never told (a succeed-report transport failure): the box
// is real and billed, the control plane will never know it exists, so it must be
// deleted to leave ZERO orphans. It is the SAME teardown ProvisionOneShot runs on
// a post-create step failure — server + DNS A record, on a fresh bounded context —
// so the "no orphan the control plane doesn't know about" invariant has one
// implementation, not two. host is the LiveServer.Server returned from a
// successful ProvisionOneShot; spec carries the DNS Name/Zone to delete.
func (wp *WarmPool) CleanupHost(host Server, spec GoLiveSpec) error {
	return wp.cleanupHost(host, spec)
}

// SweepOrphans finds every box labeled barkpark-orphaned=true and DELETES it
// (plus its stranded DNS A record, recovered from the barkpark-fqdn label). It is
// the auto-recovery half of the double-failure edge: a box only ever carries the
// orphaned label because the teardown path set it AFTER deciding the box must die
// but provider.Delete failed — so a labeled box is DEFINITIVELY meant to be gone.
//
// WHY THIS CANNOT DELETE A LIVE BOX: the selector is barkpark-orphaned=true, set
// EXCLUSIVELY in cleanupHost.markOrphaned. A healthy provisioned box carries only
// barkpark-managed=true (stamped at create), which this sweep ignores; an
// unlabeled box (created outside Barkpark) is never returned by the orphaned-label
// query. So the only boxes deleted are ones the worker already tried and failed to
// tear down — never a managed box, never a live customer box, never anything
// unlabeled.
//
// It is BEST-EFFORT and aggregates: a per-box Delete or DNS-delete failure is
// collected and the sweep continues to the next box, returning the count swept and
// an aggregated error of whatever failed (the box keeps its label and is retried
// next sweep). It runs on a fresh bounded context so a wedged delete cannot stall
// the worker. A provider that cannot list by label (no LabelLister) returns a
// clear error — the sweep is a no-op rather than a panic.
func (wp *WarmPool) SweepOrphans(ctx context.Context) (swept int, err error) {
	if wp.Provider == nil {
		return 0, fmt.Errorf("sweep orphans: a CloudProvider must be set")
	}
	lister, ok := wp.Provider.(LabelLister)
	if !ok {
		return 0, fmt.Errorf("sweep orphans: provider cannot list by label")
	}

	sctx, cancel := context.WithTimeout(ctx, cleanupTimeout)
	defer cancel()

	orphans, err := lister.ListByLabel(sctx, OrphanedLabelKey, orphanedLabelVal)
	if err != nil {
		return 0, fmt.Errorf("sweep orphans: list: %w", err)
	}

	var errs []string
	for _, o := range orphans {
		// Delete the DNS A record FIRST (cheap, idempotent) from the recorded FQDN
		// label, then the box. A box with no fqdn label (older orphan, or a marking
		// that only got the orphaned flag) still gets deleted — only its DNS is left.
		if fqdn := o.Labels[FQDNLabelKey]; fqdn != "" && wp.DNS != nil {
			label, zone := splitFqdn(strings.Trim(strings.TrimSpace(fqdn), "."))
			if derr := wp.DNS.DeleteRecord(sctx, zone, label, "A"); derr != nil {
				errs = append(errs, fmt.Sprintf("orphan %s: delete DNS %s: %v", o.Name, fqdn, derr))
			}
		}
		if derr := wp.Provider.Delete(sctx, o.Name); derr != nil {
			errs = append(errs, fmt.Sprintf("orphan %s: delete server: %v", o.Name, derr))
			continue // box NOT gone — keep its label so the next sweep retries it
		}
		swept++
	}
	if len(errs) > 0 {
		return swept, fmt.Errorf("sweep orphans: %d swept, %d failed: %s", swept, len(errs), strings.Join(errs, "; "))
	}
	return swept, nil
}

// DeprovisionByIP tears down a SPECIFIC managed box on a user-initiated Remove.
// The control plane never stored the random-suffixed create NAME, so it hands
// back the box's IP plus the DNS label+zone that form its public FQDN. We resolve
// the box to delete by matching BOTH the IP AND the barkpark-fqdn label (stamped
// at create, see ProvisionOneShot) — NEVER the IP alone. An IP is NOT a stable
// handle: Hetzner releases a deleted box's IP back to the pool and can reassign it
// to a DIFFERENT customer's box. Between a job's claim and a later reaper re-claim
// (e.g. after a dropped succeed-report) the original box may be gone and its IP
// reused, so matching the IP alone could delete the wrong tenant's live box. The
// FQDN is the box's globally-unique per-instance identity (<slug>-<teamid>.<zone>),
// so requiring it as well guarantees we only ever delete THIS job's box.
//
// The server is deleted FIRST (stop billing), then the DNS A record. FULLY
// IDEMPOTENT: no IP+FQDN match → no server delete (box already gone, or the IP
// was reused by another instance — left untouched); DeleteRecord swallows
// not-found. Runs on a fresh bounded context.
func (wp *WarmPool) DeprovisionByIP(ctx context.Context, ip, dnsLabel, dnsZone string) error {
	if wp.Provider == nil {
		return fmt.Errorf("deprovision: a CloudProvider must be set")
	}
	if strings.TrimSpace(ip) == "" {
		return fmt.Errorf("deprovision: an ip is required to locate the box")
	}
	lister, ok := wp.Provider.(LabelLister)
	if !ok {
		return fmt.Errorf("deprovision: provider cannot list by label")
	}

	dctx, cancel := context.WithTimeout(ctx, cleanupTimeout)
	defer cancel()

	managed, err := lister.ListByLabel(dctx, ManagedLabelKey, managedLabelVal)
	if err != nil {
		return fmt.Errorf("deprovision %s: list managed: %w", ip, err)
	}
	// The box's stable identity: its public FQDN, stamped as the barkpark-fqdn
	// label at create. An empty wantFqdn (control plane sent no label/zone) is a
	// programming error upstream — refuse to fall back to IP-only matching, which
	// is exactly the unsafe behaviour this guard exists to prevent.
	wantFqdn := Fqdn(dnsLabel, dnsZone)
	if wantFqdn == "" {
		return fmt.Errorf("deprovision %s: missing dns label/zone — cannot confirm box identity", ip)
	}
	name := ""
	ipOccupiedByOther := false
	for _, s := range managed {
		if s.IP == ip {
			if s.Labels[FQDNLabelKey] == wantFqdn {
				name = s.Name
				break
			}
			// A managed box occupies this IP but its identity label does NOT match
			// this job's box. Two cases, both unsafe to proceed past: (a) a legacy box
			// created before the barkpark-fqdn label existed, or (b) a recycled IP now
			// held by a DIFFERENT tenant's box. We must neither delete it nor let the
			// control plane delete the registry row (which would strand a billed box),
			// so we FAIL LOUDLY instead of silently no-op'ing the delete.
			ipOccupiedByOther = true
		}
	}
	if name == "" && ipOccupiedByOther {
		return fmt.Errorf(
			"deprovision %s: a managed box occupies this IP but its %s label does not match %q "+
				"(possible legacy box predating the label, or a recycled IP held by another instance) "+
				"— refusing to delete; investigate manually",
			ip, FQDNLabelKey, wantFqdn,
		)
	}
	if name != "" {
		if derr := wp.Provider.Delete(dctx, name); derr != nil {
			return fmt.Errorf("deprovision %s: delete server %s: %w", ip, name, derr)
		}
	}

	if wp.DNS != nil && dnsLabel != "" && dnsZone != "" {
		if derr := wp.DNS.DeleteRecord(dctx, dnsZone, dnsLabel, "A"); derr != nil {
			return fmt.Errorf("deprovision %s: delete DNS %s.%s: %w", ip, dnsLabel, dnsZone, derr)
		}
	}
	return nil
}

// cleanupTimeout bounds the fresh teardown context cleanupHost uses so a single
// stuck delete cannot wedge the worker forever.
const cleanupTimeout = 2 * time.Minute

// serverNameMaxLen caps a created server name at the hostname-LABEL limit (RFC
// 1035): 63 chars. hcloud server names share that limit, so a long customer slug
// must be truncated rather than rejected.
const serverNameMaxLen = 63

// serverNameSuffixHex is the length of the crypto/rand hex suffix appended to a
// one-shot server name. 6 hex chars = 24 bits = ~16M values, ample to make a
// per-team-unique slug GLOBALLY unique without colliding in practice.
const serverNameSuffixHex = 6

// randHex returns n hex characters drawn from crypto/rand. On the (effectively
// impossible) read failure it falls back to a time-derived value so a name is
// always produced — uniqueness degrades gracefully rather than panicking a
// provision.
func randHex(n int) string {
	b := make([]byte, (n+1)/2)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand should never fail; fall back to a time nonce so the chain
		// still gets a (weaker but non-empty) suffix rather than aborting.
		return fmt.Sprintf("%0*x", n, time.Now().UnixNano())[:n]
	}
	return hex.EncodeToString(b)[:n]
}

// oneShotServerName derives a GLOBALLY-UNIQUE, DNS/hcloud-safe server name from a
// job's per-instance label: bp-<sanitized label>-<6 hex>. The crypto/rand suffix
// makes the NAME globally unique regardless of the label, guarding the Hetzner
// duplicate-name path even if two jobs ever carried an identical subdomain. The
// final name is capped at serverNameMaxLen (63, the hostname-label limit): the
// slug portion is truncated as needed, but the "bp-" prefix and the "-<suffix>"
// are ALWAYS preserved (truncating those would defeat the uniqueness/identification
// they provide).
//
// NOTE: the DNS FQDN (<spec.Name>.<zone>) is independently globally unique — the
// control plane allocates a <slug>-<teamid> provisioning_subdomain before the job
// is queued, so spec.Name already carries a globally-unique subdomain. This suffix
// is the second, server-name-side uniqueness guard.
func oneShotServerName(label string) string {
	s := strings.ToLower(strings.TrimSpace(label))
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-' || r == '_':
			b.WriteRune('-')
		default:
			b.WriteRune('-')
		}
	}
	name := strings.Trim(b.String(), "-")
	if name == "" {
		name = "instance"
	}

	suffix := randHex(serverNameSuffixHex)
	// Budget for the slug portion = 63 − len("bp-") − len("-"+suffix). Truncate the
	// slug to fit; the prefix and suffix are never dropped.
	const prefix = "bp-"
	reserved := len(prefix) + 1 + len(suffix) // "-"+suffix
	maxSlug := serverNameMaxLen - reserved
	if len(name) > maxSlug {
		name = strings.Trim(name[:maxSlug], "-")
		if name == "" {
			name = "x" // a truncation that emptied to all-dashes still needs a stem
		}
	}
	return prefix + name + "-" + suffix
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
