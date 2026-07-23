// support.go — the fleet-SUPPORT bring-up primitives for `bp cloud support add`
// (Personal Dev Fleet Wave C, PDF-D56..D62).
//
// A SUPPORT is a subordinate runner box for the developer's MAIN Barkpark
// (charter PDF-D1: hub-and-spoke — supports serve the main, they get no public
// identity of their own). Its bring-up reuses the warm-pool go-live chain but
// deliberately REDUCED (PDF-D59): a support has no public FQDN, so the
// dns/caddy/public-health/tenant-register steps are DROPPED and the health gate
// is a LOCAL curl on the box. This file owns the two cloud-seam halves —
// creating the box and configuring it — while the orchestration (roster row,
// bind, dataset pull, runtime install, systemd unit) lives in the CLI surface
// (internal/cli/cloud_support_cmd.go), which narrates each named state.
//
// This is NOT a rival provision chain: every step here IS the warm-pool step
// (CreateWarmServer, EnsureFresh, secretsInstallStep, defaultMigrateArgv,
// adminTokenStep), re-sequenced for a box that never fronts the public internet.
package cloud

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// FleetSupportLabelKey is the provider label that marks a box as a fleet
// support and carries the support's worker NAME — the box's stable identity
// (Hetzner recycles IPs, and CreateWarmServer mints a random warm-<hex> server
// name, so neither is a safe handle). A later `bp cloud support remove <name>`
// resolves the box by this label, mirroring how FQDNLabelKey anchors instances.
const FleetSupportLabelKey = "barkpark-fleet-support"

// SupportSSHReadyTimeout bounds how long a freshly-created support box may take
// to accept SSH before the bring-up fails closed — same budget as the go-live
// chain's sshReadyTimeout (a snapshot boot is ~30-60s; 3 min is generous).
const SupportSSHReadyTimeout = sshReadyTimeout

// SupportLocalHealthProbe is the LOCAL health gate a support runs INSTEAD of
// the public https://<fqdn> poll (PDF-D59: a support has no fqdn — the baked
// Barkpark serves localhost only, for the on-box listener + dataset import).
// `head -c` keeps a huge schema payload out of captured output; -fsS makes a
// non-2xx an error with the reason on stderr.
const SupportLocalHealthProbe = `curl -fsS http://localhost:4000/api/schemas | head -c 200`

// SupportRunner is the per-host capability set the support bring-up needs:
// step execution (configure chain), output capture (health probe + capacity
// measure), stdin feed (dataset tar streaming), and the SSH readiness poll.
// The production *SSHStepRunner satisfies all four; tests inject a recorder.
type SupportRunner interface {
	StepRunner
	RunOutput(ctx context.Context, script string) (string, error)
	RunFeed(ctx context.Context, title, script string, stdin io.Reader) (string, error)
	WaitReady(ctx context.Context, timeout time.Duration) error
}

// compile-time assertion that the production SSH runner fills the seam.
var _ SupportRunner = (*SSHStepRunner)(nil)

// CreateSupportServer creates ONE x86 warm-image box for a fleet support and
// stamps its identity. It rides CreateWarmServer verbatim (FreshSpec resolves
// the newest baked snapshot; the resilience ladder dodges sold-out types; the
// box fails closed if it cannot be labeled), then:
//
//  1. stamps FleetSupportLabelKey=<name> — the support's identity. FAIL CLOSED:
//     an unlabelable box cannot be found again by `support remove`, so it is
//     torn down rather than leaked as unidentifiable spend.
//  2. drops the barkpark-warm pool label (best-effort) — the box is a support,
//     not pool inventory; leaving the label would let the pool reconciler count
//     or recycle it. Ordered AFTER (1) so there is never an instant where the
//     box carries neither identity, mirroring AssignWarm.
//
// A CREATE failure (e.g. the live-proven Hetzner 412 resource_unavailable,
// PDF-D58) returns the provider error with NOTHING created and NOTHING written.
func CreateSupportServer(ctx context.Context, provider CloudProvider, providerName, name string) (Server, error) {
	spec := FreshSpec(ctx, providerName)
	host, err := CreateWarmServer(ctx, provider, spec)
	if err != nil {
		return Server{}, err
	}

	labeler, ok := provider.(ServerLabeler)
	if !ok {
		warmDeleteBestEffort(provider, host.Name)
		return Server{}, fmt.Errorf(
			"create support %q: provider cannot label — refusing to leak an unidentifiable support box", name)
	}
	if lerr := labeler.LabelServer(ctx, host.Name, FleetSupportLabelKey, name); lerr != nil {
		warmDeleteBestEffort(provider, host.Name)
		return Server{}, fmt.Errorf("create support %q: label %s: %w", name, FleetSupportLabelKey, lerr)
	}
	if remover, ok := provider.(ServerLabelRemover); ok {
		if rerr := remover.RemoveLabel(ctx, host.Name, WarmLabelKey); rerr != nil {
			fmt.Fprintf(os.Stderr, "bp cloud support: WARNING: %s: remove %s label: %v (cosmetic — the support label is the identity)\n",
				host.Name, WarmLabelKey, rerr)
		}
	}

	if host.Labels == nil {
		host.Labels = map[string]string{}
	}
	host.Labels[FleetSupportLabelKey] = name
	delete(host.Labels, WarmLabelKey)
	return host, nil
}

// SupportConfigureOpts configures one ConfigureSupportHost run.
type SupportConfigureOpts struct {
	// SecretsGen mints the per-instance secrets. nil → the production generator
	// (independent crypto/rand draws — the same one the go-live chain uses).
	SecretsGen SecretGen
	// Narrate reports each named sub-state (freshen / secrets-mint /
	// secrets-install / migrate / admin-token / health-local) as it happens.
	// nil-safe.
	Narrate func(state, detail string)
}

// ConfigureSupportHost runs the REDUCED go-live subset (PDF-D59) on an
// already-created, SSH-ready support box:
//
//	freshen (fail-open) → secrets-mint → secrets-install → migrate →
//	admin-token → LOCAL health probe (curl localhost:4000/api/schemas)
//
// DROPPED vs configureHost: dns, caddy/TLS, the public health poll, and the
// control-plane tenant register — a support has no public identity. NEVER
// authored here: barkpark.service (baked into the warm image). The minted
// Secrets are returned so the caller can drive the on-box admin API (dataset
// import) with the box's own admin token. Every failure is fail-closed except
// freshen, which degrades loudly onto the baked release (a working-but-behind
// support beats a dead bring-up — the same policy as the go-live chain).
func ConfigureSupportHost(ctx context.Context, runner SupportRunner, opts SupportConfigureOpts) (Secrets, error) {
	narrate := opts.Narrate
	if narrate == nil {
		narrate = func(string, string) {}
	}

	// freshen — bring the baked checkout to origin/main BEFORE migrate (the
	// migrations must match the code that will serve). FAIL-OPEN, like the
	// go-live chain: a freshen failure degrades to the baked release, loudly.
	if _, ferr := EnsureFresh(ctx, runner, FreshenOpts{
		RebuildTimeout: freshenRebuildBudget,
		Narrate:        func(status, detail string) { narrate("freshen", strings.TrimSpace(status+" "+detail)) },
	}); ferr != nil {
		narrate("freshen", "degraded — continuing on the baked release: "+ferr.Error())
	}

	// secrets-mint — per-instance credentials, validated BEFORE any of them is
	// single-quoted into a shell script (fail closed on a malformed draw).
	gen := opts.SecretsGen
	if gen == nil {
		gen = defaultSecretGen
	}
	secrets, err := gen()
	if err != nil {
		return Secrets{}, fmt.Errorf("secrets-mint: %w", err)
	}
	if err := validateSecrets(secrets); err != nil {
		return Secrets{}, fmt.Errorf("secrets-mint: %w", err)
	}
	if err := validateSecretKeyBase(secrets.SecretKeyBase); err != nil {
		return Secrets{}, fmt.Errorf("secrets-mint: %w", err)
	}
	if err := validateAdminToken(secrets.AdminToken); err != nil {
		return Secrets{}, fmt.Errorf("secrets-mint: %w", err)
	}
	narrate("secrets-mint", "per-instance secrets minted")

	// secrets-install — the box runs on its OWN keys before migrate (runtime.exs
	// requires BARKPARK_KEK in prod; migrate sources .env). No mail relay: a
	// support sends no transactional mail.
	narrate("secrets-install", "installing per-instance secrets + restarting Barkpark")
	if err := runner.Run(ctx, secretsInstallStep(secrets, MailRelay{})); err != nil {
		return Secrets{}, fmt.Errorf("secrets-install: %w", err)
	}

	// migrate — the same step the go-live chain carries, env-secret scrubbed.
	narrate("migrate", "running database migrations")
	argv := defaultMigrateArgv()
	migrate := CaddyStep{
		Title:            "run database migrations (mix ecto.migrate)",
		Cmd:              strings.Join(argv, " "),
		Argv:             argv,
		RedactEnvSecrets: true,
	}
	if err := runner.Run(ctx, migrate); err != nil {
		return Secrets{}, fmt.Errorf("migrate: %w", err)
	}

	// admin-token — make the minted token THE admin token on the box.
	narrate("admin-token", "installing the minted admin token")
	if err := runner.Run(ctx, adminTokenStep(secrets.AdminToken)); err != nil {
		return Secrets{}, fmt.Errorf("admin-token: %w", err)
	}

	// health-local — the support's health gate is the box's OWN loopback API
	// (PDF-D59): no fqdn, no ACME warm-up, so one direct probe suffices.
	narrate("health-local", "probing http://localhost:4000/api/schemas on the box")
	probeOut, perr := runner.RunOutput(ctx, SupportLocalHealthProbe)
	if perr != nil {
		return Secrets{}, fmt.Errorf("health-local: localhost:4000/api/schemas not answering on the box: %w: %s",
			perr, strings.TrimSpace(probeOut))
	}
	if strings.TrimSpace(probeOut) == "" {
		return Secrets{}, fmt.Errorf("health-local: localhost:4000/api/schemas answered EMPTY on the box — Barkpark is not serving")
	}
	narrate("health-local", "ok")

	return secrets, nil
}
