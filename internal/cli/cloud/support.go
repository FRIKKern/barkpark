// support.go — the fleet-SUPPORT bring-up primitives for `bp cloud support add`
// (Personal Dev Fleet Wave C, PDF-D56..D62).
//
// A SUPPORT is a subordinate runner box for the developer's MAIN Barkpark
// (charter PDF-D1: hub-and-spoke — supports serve the main). Its bring-up
// reuses the warm-pool go-live chain but deliberately REDUCED (PDF-D59): this
// configure subset drops the dns/caddy/public-health/tenant-register steps and
// gates on a LOCAL curl on the box. WHO adds the public identity differs by
// chain: the CP worker chain (internal/provisioner/support.go) wraps this
// subset with the full DNS → Caddy/TLS → public-health legs so a provisioned
// support fronts <label>.barkpark.cloud like a main does (Open Studio works);
// the laptop `bp cloud support add` chain still ships the box headless. This
// file owns the two cloud-seam halves — creating the box and configuring it —
// while the orchestration (roster row, bind, dataset pull, runtime install,
// systemd unit) lives in the CLI surface (internal/cli/cloud_support_cmd.go),
// which narrates each named state.
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
// control-plane tenant register — the CP worker chain layers dns/caddy + the
// public health poll AROUND this subset itself (supports carry a full public
// identity now); the CLI chain runs it bare. NEVER
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

// SupportDefaultWorkspaceSlug is the migrate-seeded root workspace slug every
// baked box ships. It is the ONE import target that can be PRE-POLLUTED: the
// warm image's baked Postgres carries the seed lineage forward across bake
// generations (deploy/bake-server-image.sh snapshots the data dir; the lineage
// was originally seeded SEED_PROFILE=demo, ~27 docs), so the box's "default"
// workspace is NOT the empty shell the merge engine's fail-closed PDS-D9 proof
// requires — a scrubbed default-workspace bundle 409s workspace_slug_conflict
// (three live provision_support failures on 2026-07-26). Both support chains
// gate the reset + re-mint bracket below on exactly this slug.
const SupportDefaultWorkspaceSlug = "default"

// SupportResetDefaultWorkspaceStep deletes the box's seeded "default"
// workspace so the ensure-workspace step that follows creates a PROVABLY empty
// shell and the merge-import lands on the live-proven PDS-D9 adopt branch
// (empty shell → adopt-delete → import) instead of 409ing on the baked seed
// docs. The engine's empty-shell proof (adopt_or_refuse_root_slug! +
// empty_shell?) is correct and fail-closed — this step satisfies it, never
// weakens it. Mechanics are adminTokenStep's verbatim (the admin plane on a
// box IS `mix run -e` under the app's release env, asdf sourced because the
// SSH runner's `bash -l` is non-interactive): Tenancy.delete_workspace/1 on
// the slug-resolved workspace, TOLERATING absent (nil → no-op success) so
// re-runs converge. FAIL LOUD on a delete error — a half-reset box must never
// reach the import. No token rides this step (mix run is DB-direct), but it
// sources .env, so env secrets are pattern-scrubbed from any captured output.
//
// The step REPORTS the document count it is about to delete (one
// Repo.aggregate on documents.workspace_id before the delete): the seed size
// was unmeasured folklore ("~27 docs", never observed), and this line is the
// only observation of the image seed that survives the reset — it converts
// the folklore into a measured number at zero cost (PDF-D103's second half).
//
// CASCADE WARNING for callers: the box admin token is scoped to the default
// workspace (api_tokens.workspace_id is ON DELETE CASCADE since migration
// 20260527140000), so this delete KILLS it — always follow with
// SupportAdminTokenStep before the next token-authenticated on-box call.
func SupportResetDefaultWorkspaceStep() CaddyStep {
	const elixir = `case Barkpark.Tenancy.get_workspace_by_slug("default") do ` +
		`nil -> IO.puts("default workspace already absent - reset is a no-op"); ` +
		`ws -> require Ecto.Query; ` +
		`doc_count = Barkpark.Repo.aggregate(Ecto.Query.where(Barkpark.Content.Document, workspace_id: ^ws.id), :count); ` +
		`IO.puts("default workspace carries #{doc_count} document(s) - deleting them with the workspace"); ` +
		`case Barkpark.Tenancy.delete_workspace(ws) do ` +
		`{:ok, _} -> IO.puts("default workspace deleted - #{doc_count} document(s) destroyed (measured, not folklore)"); ` +
		`other -> IO.inspect(other, label: "default workspace reset failed"); System.halt(1) end end`
	script := `set -a; . /opt/barkpark/.env; set +a; . /root/.asdf/asdf.sh && cd /opt/barkpark/api && mix run -e '` + elixir + `'`
	return CaddyStep{
		Title: "reset the seeded default workspace to a provably-empty import target (Tenancy.delete_workspace — reports the measured doc count; absent is a no-op)",
		Cmd:   "mix run -e 'Tenancy.delete_workspace(default)' (counts docs first; tolerates absent)",
		Argv:  []string{"bash", "-lc", script},
		// This step sources /opt/barkpark/.env — a failure could echo the DB
		// password / SECRET_KEY_BASE / cloak key. Pattern-scrub those.
		RedactEnvSecrets: true,
	}
}

// SupportAdminTokenStep re-runs the go-live admin-token step (adminTokenStep —
// revoke existing admin tokens, ensure_default_scope, mint the SAME secret
// value; re-running converges). Exported because BOTH support chains must
// restore the box credential after a default-workspace delete cascades it
// (api_tokens.workspace_id :delete_all), TWICE on the ws=="default" path:
//
//  1. right after SupportResetDefaultWorkspaceStep — the ensure + import HTTP
//     calls need a live bearer, and Seeds.Shared.ensure_default_scope inside
//     the step get-or-creates the empty default workspace/project/dataset the
//     adopt branch then replaces (no separate scope-recreation step needed);
//  2. right after the merge-import — the engine's PDS-D9 adopt branch deletes
//     the empty shell IN-TRANSACTION (Tenancy.delete_workspace again), which
//     cascades the token minted in (1). Post-import, ensure_default_scope
//     resolves slug "default" to the freshly-IMPORTED workspace, so the
//     restored token is scoped to the content it must govern — the credential
//     the chain holds and reports to the CP at succeed (mint_studio_link)
//     stays live, restored verbatim.
func SupportAdminTokenStep(boxAdminToken string) CaddyStep {
	return adminTokenStep(boxAdminToken)
}

// SupportMergeImportStep builds the on-box merge-import step BOTH support
// chains run (the CLI's `bp cloud support add` and the CP worker's
// provision_support): bp merge-imports the staged dataset bundle into the
// box's OWN localhost API with the BOX's minted admin token — never the
// parent's. ONE shared builder: the two chains carried byte-copied scripts and
// the failure mode drifted blind (task-63a199c0a0ce2a06 — the live import 500
// surfaced as a bare "exit status 8" because bp's error body and the box-side
// crash log never left the box).
//
// The script therefore CARRIES ITS EVIDENCE: bp's combined output is ALWAYS
// echoed, and on a non-zero exit the box's own barkpark journal tail (the
// Phoenix crash report behind a 500) follows before the exit status is
// preserved. Custody: the admin token rides Argv only and is listed in Redact,
// so the runner scrubs it from any captured output; everything else the step
// can print is box-local error text (bp's stderr, journal lines), which is
// exactly what the job console must surface for the next failure to name
// itself.
func SupportMergeImportStep(ws, boxAdminToken string) CaddyStep {
	script := `set -e; export BP_TOK='` + boxAdminToken + `'; export PATH=/usr/local/bin:/usr/bin:$PATH
rc=0
out=$(bp -s http://localhost:4000 --token "$BP_TOK" cloud workspace import '` + ws + `' --file /opt/barkpark-fleet/dataset.tar --yes --merge 2>&1) || rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then
  echo "bp import exited $rc — box-side evidence follows"
  echo '--- barkpark journal tail (journalctl -u barkpark -n 120) ---'
  journalctl -u barkpark -n 120 --no-pager 2>&1 || true
  echo '--- end barkpark journal tail ---'
fi
exit $rc`
	return CaddyStep{
		Title:  "merge-import the scrubbed dataset bundle into the box (bp cloud workspace import --merge)",
		Cmd:    "bp cloud workspace import " + ws + " --file /opt/barkpark-fleet/dataset.tar --yes --merge (token redacted)",
		Argv:   []string{"bash", "-lc", script},
		Redact: []string{boxAdminToken},
	}
}
