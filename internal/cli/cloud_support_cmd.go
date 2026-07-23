package cli

// cloud_support_cmd.go is `bp cloud support …` — the Personal Dev Fleet's ONE
// ACTION (Wave C, PDF-D56..D62): grow the fleet from a single command.
//
//	bp cloud support add <name> [--agent claude|codex] [--workspace <slug>]
//	                            [--dataset <slug>] [--parent <cp-row-id>]
//
// `add` provisions an x86 warm-image box, binds it to the developer's MAIN
// Barkpark (the active `bp use` server), pulls a SCRUBBED dataset onto it
// (dev-profile export → merge import, the PDS twin-doctrine pull), installs the
// fleet listener runtime, and supervises it under systemd — then polls the
// main's roster until the listener is truthfully ONLINE with measured capacity,
// or reports an honest timeout (the row then ages to offline; never faked).
//
// Every step is a NAMED PRINTED STATE; every failure prints the honest reason,
// what has actually been written so far, and the exact next command (the
// Kinsta bar). Ordering is load-bearing (PDF-D56): the provisioning roster row
// is written ONLY AFTER the provider create succeeds, so a placement failure
// (live-proven Hetzner 412 resource_unavailable, PDF-D58) writes NOTHING.
//
// Boundaries this file honors:
//   - the roster row's self-declared status rides in content.status, NEVER as a
//     top-level status (the top-level key is the server-owned draft/published
//     column and 422s exact-vocab by design — PDF-D56).
//   - the bind endpoints (/v1/fleet/support-tokens, /v1/fleet/supports) are
//     RUNTIME HTTP calls on the main — no compile-time dependency on the
//     sibling Elixir slices that ship them.
//   - agent PROVIDER KEYS ARE NEVER COPIED (PDF-D62): the command finishes by
//     printing the exact SSH one-liner the developer runs themselves.
//   - barkpark.service is baked into the warm image — never authored here.
//
// `remove` is DELIBERATELY absent — a round-2 slice (pdf-wc-one-action-remove)
// extends this file after merge; the dispatcher names that honestly.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// supportCtx is the context every support bring-up call runs under. A package
// var (the cloudCtx idiom) so a later task can bound it without touching call
// sites, and so tests keep it fast.
var supportCtx = context.Background

// ── injected seams (production defaults; tests override) ────────────────────

// supportProviderFor resolves the cloud provider the support box is created on.
// Hetzner is the fleet's provider today (x86 warm images live there); the seam
// exists so tests never touch hcloud and a later slice can neutralize it.
var supportProviderFor = func() (cloud.CloudProvider, error) {
	return cloud.ProviderFor(cloud.ProviderHetzner, nil)
}

// supportCreateServer creates + identity-labels the box (cloud.CreateSupportServer).
var supportCreateServer = cloud.CreateSupportServer

// supportRunnerFor builds the per-host SSH runner once the box IP is known.
var supportRunnerFor = func(host string) cloud.SupportRunner {
	return cloud.NewSSHStepRunner(host)
}

// supportConfigureHost runs the reduced configure chain (cloud.ConfigureSupportHost).
var supportConfigureHost = cloud.ConfigureSupportHost

// supportSecretsGen overrides the per-instance secret generator. nil → the
// production crypto/rand generator inside the cloud package. Tests inject
// deterministic (but validation-passing) secrets.
var supportSecretsGen cloud.SecretGen

// supportReadyTimeout / poll knobs — vars so tests never sleep for real.
var (
	supportReadyTimeout       = cloud.SupportSSHReadyTimeout
	supportRosterPollInterval = 5 * time.Second
	supportRosterPollBudget   = 4 * time.Minute
)

// supportClock stamps the roster row's last_seen. A var so tests pin it.
var supportClock = func() time.Time { return time.Now().UTC() }

// supportProvisioningTTL is the provisioning roster row's honest freshness
// budget (PDF-D56): the whole bring-up — configure + dataset pull + runtime —
// fits inside 30 min, after which an abandoned row truthfully ages to offline.
const supportProvisioningTTL = 1800

// supportRawBase is where the box fetches origin/main file CONTENT (fleet
// runtime + unit) — the freshened on-box checkout is the fallback. PDF-D62:
// the runtime files are written from origin/main content, never from whatever
// stale copy an operator machine carries.
const supportRawBase = "https://raw.githubusercontent.com/FRIKKern/barkpark/main"

// ── validation fences ────────────────────────────────────────────────────────

// supportNameRe fences the worker name: it rides in provider labels, the
// listener doc id, systemd env, and single-quoted shell — so it is locked to a
// DNS-label shape. Lowercase alphanumerics + hyphens, 63 max, no leading/-.
var supportNameRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// supportSlugRe fences workspace/dataset slugs interpolated into shell + URLs.
var supportSlugRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// supportURLSafeRe is the safe shape the main's base URL must match before it
// is single-quoted into the on-box env-file script (mirrors the cloud
// package's agent-URL guard: no quotes, spaces, $, ;, backticks).
var supportURLSafeRe = regexp.MustCompile(`^[A-Za-z0-9:/._~%?=&+-]+$`)

// supportTokenSafeRe is the safe shape a minted ledger token must match before
// it is single-quoted into the env-file script (fail closed on a token that
// could break out of the quoting — the injection guard, not the authority).
var supportTokenSafeRe = regexp.MustCompile(`^[A-Za-z0-9._~+/=-]+$`)

// supportClassVocab is the size-class vocabulary FLEET_MAX_CLASS may carry.
var supportClassVocab = map[string]bool{"light": true, "standard": true, "heavy": true, "xl": true}

// supportAgentPackages maps the --agent choice to the npm package + binary the
// runtime step installs FAIL-OPEN (a missing agent CLI degrades the listener's
// orders, never its presence) and the env var the developer must hand over.
var supportAgentPackages = map[string]struct{ pkg, bin, keyVar string }{
	"claude": {pkg: "@anthropic-ai/claude-code", bin: "claude", keyVar: "ANTHROPIC_API_KEY"},
	"codex":  {pkg: "@openai/codex", bin: "codex", keyVar: "OPENAI_API_KEY"},
}

// ── dispatch ─────────────────────────────────────────────────────────────────

// runCloudSupport dispatches `bp cloud support <verb> …`.
func runCloudSupport(out *writer, g globals, args []string) int {
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudSupportHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing support command (run `bp cloud support -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "add":
		return runCloudSupportAdd(out, g, rest)
	case "remove", "rm", "delete":
		return useError(out, "usage",
			"`bp cloud support remove` is not built yet (a planned round-2 verb) — until it lands, tear a support down with `bp cloud instance delete <server> --provider hetzner --yes` (find the server via its barkpark-fleet-support label) and delete its listener row on the main",
			exitUsage)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown support command %q (run `bp cloud support -h` for usage)", verb), exitUsage)
	}
}

// ── the one action ───────────────────────────────────────────────────────────

// supportAddRun carries one `support add` invocation's resolved inputs +
// accumulated truth, so each step method reads like the sequence it narrates.
type supportAddRun struct {
	out *writer
	g   globals

	name    string
	agent   string
	ws      string
	dataset string
	parent  string // optional --parent: the main's control-plane row id

	base  string // the MAIN's content-API base URL
	token string // the operator's bearer against the main

	host    cloud.Server
	runner  cloud.SupportRunner
	secrets cloud.Secrets

	ledgerToken string // minted for the box, delivered 0600 — never printed
	tokenID     string
	maxClass    string // measured on the box; "" when the measure degraded
}

func runCloudSupportAdd(out *writer, g globals, args []string) int {
	const usage = "bp cloud support add <name> [--agent claude|codex] [--workspace <slug>] [--dataset <slug>] [--parent <cp-row-id>]"
	a, err := parseHzArgs(args, []string{"agent", "workspace", "dataset", "parent"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <name> (usage: "+usage+")", exitUsage)
	}

	r := &supportAddRun{out: out, g: g, name: a.pos[0]}
	if !supportNameRe.MatchString(r.name) {
		return useError(out, "usage",
			fmt.Sprintf("invalid support name %q — want a DNS-label shape: lowercase letters, digits, hyphens (it becomes the worker id, the listener-<name> roster row, and a provider label)", r.name),
			exitUsage)
	}
	r.agent = strings.TrimSpace(a.val("agent"))
	if r.agent == "" {
		r.agent = "claude"
	}
	if _, ok := supportAgentPackages[r.agent]; !ok {
		return useError(out, "usage", fmt.Sprintf("unknown --agent %q (want claude|codex)", r.agent), exitUsage)
	}
	r.parent = strings.TrimSpace(a.val("parent"))

	// The MAIN is the active content context — the same precedence every bp
	// command resolves (env > saved server > baked localhost floor).
	ctx := resolveContext(g)
	r.base = strings.TrimRight(strings.TrimSpace(ctx.Server), "/")
	r.token = strings.TrimSpace(ctx.Token)
	if r.base == "" {
		return useError(out, "failed", "no main Barkpark resolved — run `bp use <name>` (or set BARKPARK_API_URL) so the support knows which main it serves", exitGeneric)
	}
	if !supportURLSafeRe.MatchString(r.base) {
		return useError(out, "failed", fmt.Sprintf("main URL %q has an unexpected shape; refusing to interpolate it into on-box scripts", r.base), exitGeneric)
	}

	r.ws = strings.TrimSpace(a.val("workspace"))
	if r.ws == "" {
		r.ws = strings.TrimSpace(ctx.Workspace)
	}
	if r.ws == "" {
		r.ws = "default"
	}
	// --dataset is a GLOBAL value flag: parseGlobals eats every spelling the
	// user types, so read the local flag first (defensive) then the global,
	// gated on datasetSet exactly like the workspace export verb.
	r.dataset = strings.TrimSpace(a.val("dataset"))
	if r.dataset == "" && g.datasetSet {
		r.dataset = strings.TrimSpace(g.dataset)
	}
	if r.dataset == "" {
		r.dataset = strings.TrimSpace(ctx.Dataset)
	}
	if r.dataset == "" {
		r.dataset = "production"
	}
	if !supportSlugRe.MatchString(r.ws) {
		return useError(out, "usage", fmt.Sprintf("invalid workspace slug %q", r.ws), exitUsage)
	}
	if !supportSlugRe.MatchString(r.dataset) {
		return useError(out, "usage", fmt.Sprintf("invalid dataset slug %q", r.dataset), exitUsage)
	}

	// A localhost main is unreachable FROM the box — say so up front, honestly,
	// but proceed (the bind/poll steps will name the failure precisely).
	if h := hostOf(r.base); h == "localhost" || h == "127.0.0.1" || h == "::1" {
		out.errf("⚠ the active main is %s — a cloud support box cannot reach a localhost main; the listener will bind but never connect. Point bp at a reachable main first (`bp use <name>`).", r.base)
	}

	if g.dryRun {
		out.progressf("DRY RUN — bp cloud support add %s would run, in order:", r.name)
		out.progressf("  1. create        x86 warm-image box on hetzner (label %s=%s); a placement failure writes NOTHING", cloud.FleetSupportLabelKey, r.name)
		out.progressf("  2. wait-ready    poll sshd on the new box (budget %s)", supportReadyTimeout)
		out.progressf("  3. roster-row    publish listener-%s {status:provisioning, ttl_s:%d} on %s (dataset %s)", r.name, supportProvisioningTTL, r.base, r.dataset)
		out.progressf("  4. configure     freshen → secrets → migrate → admin-token → LOCAL health probe")
		out.progressf("  5. bind          POST /v1/fleet/support-tokens + POST /v1/fleet/supports on the main")
		out.progressf("  6. dataset       dev-profile export of %s/%s → tar over SSH → merge-import into the box", r.ws, r.dataset)
		out.progressf("  7. runtime       fleet-run.sh + protocol (origin/main content), %s CLI fail-open, unit + env 0600", r.agent)
		out.progressf("  8. online        enable barkpark-fleet-listener, poll the roster to online-with-capacity (budget %s)", supportRosterPollBudget)
		return exitOK
	}

	return r.run()
}

// run executes the eight named states in order. Each step returns (exitCode,
// stop); the first stop wins.
func (r *supportAddRun) run() int {
	steps := []func() (int, bool){
		r.stepCreate,
		r.stepWaitReady,
		r.stepRosterRow,
		r.stepConfigure,
		r.stepBind,
		r.stepDataset,
		r.stepRuntime,
		r.stepOnline,
	}
	for _, step := range steps {
		if code, stop := step(); stop {
			return code
		}
	}
	return r.success()
}

// ── narration helpers ────────────────────────────────────────────────────────

func (r *supportAddRun) state(step, msg string) { r.out.progressf("→ %s: %s", step, msg) }
func (r *supportAddRun) done(step, msg string)  { r.out.progressf("✓ %s — %s", step, msg) }

// fail prints the honest terminal state for a failed step: the reason, what
// has ACTUALLY been written so far, and the exact next command — then returns
// (exitCode, stop). Machine output gets the same truth as one JSON document.
func (r *supportAddRun) fail(step, reason, written, next string, code int) (int, bool) {
	if r.out.emitStructured(map[string]any{
		"ok":      false,
		"support": r.name,
		"step":    step,
		"error":   map[string]any{"code": "failed", "message": reason},
		"state":   written,
		"next":    next,
	}) {
		return code, true
	}
	r.out.userErr("✗ %s failed — %s", step, reason)
	r.out.errf("  state: %s", written)
	r.out.errf("  next:  %s", next)
	return code, true
}

// ── the eight steps ──────────────────────────────────────────────────────────

// stepCreate — PDF-D58: a placement failure prints the provider error and
// writes NOTHING anywhere (no box, no roster row, no tokens).
func (r *supportAddRun) stepCreate() (int, bool) {
	provider, perr := supportProviderFor()
	if perr != nil {
		return r.fail("create", perr.Error(),
			"nothing was created and nothing was written",
			"fix the provider credential (hetzner: set HCLOUD_TOKEN or an `hcloud context`) and re-run `bp cloud support add "+r.name+"`",
			exitAuth)
	}
	r.state("create", fmt.Sprintf("provisioning an x86 warm-image box for support %q on hetzner…", r.name))
	host, err := supportCreateServer(supportCtx(), provider, cloud.ProviderHetzner, r.name)
	if err != nil {
		return r.fail("create", err.Error(),
			"nothing was created and nothing was written (no box, no roster row, no token)",
			"re-run `bp cloud support add "+r.name+"` — placement failures are transient; BARKPARK_SERVER_TYPE / BARKPARK_SERVER_LOCATION move the type/region",
			exitGeneric)
	}
	r.host = host
	r.done("create", fmt.Sprintf("%s up at %s (x86 warm image, label %s=%s)", host.Name, host.IP, cloud.FleetSupportLabelKey, r.name))
	return exitOK, false
}

// stepWaitReady — the box exists but is still booting; poll sshd (PDF-D59).
func (r *supportAddRun) stepWaitReady() (int, bool) {
	r.runner = supportRunnerFor(r.host.IP)
	r.state("wait-ready", fmt.Sprintf("waiting for sshd on %s (budget %s)", r.host.IP, supportReadyTimeout))
	if err := r.runner.WaitReady(supportCtx(), supportReadyTimeout); err != nil {
		return r.fail("wait-ready", err.Error(),
			fmt.Sprintf("box %s EXISTS at %s (it is billing); nothing was written to the main", r.host.Name, r.host.IP),
			fmt.Sprintf("reclaim it with `bp cloud instance delete %s --provider hetzner --yes`, or re-run `bp cloud support add %s` once the box answers SSH", r.host.Name, r.name),
			exitGeneric)
	}
	r.done("wait-ready", "sshd answering")
	return exitOK, false
}

// stepRosterRow — ONLY now that a box exists (PDF-D56): publish the
// provisioning row on the MAIN via the dataset-in-path mutate route. The
// self-declared status rides in content.status — NEVER top-level (the
// top-level key is the server-owned draft/published column).
func (r *supportAddRun) stepRosterRow() (int, bool) {
	r.state("roster-row", fmt.Sprintf("publishing listener-%s {status:provisioning, ttl_s:%d} on %s (dataset %s)", r.name, supportProvisioningTTL, r.base, r.dataset))
	doc := map[string]any{
		"_id":    "listener-" + r.name,
		"_type":  "listener",
		"_draft": false,
		"content": map[string]any{
			"worker":    r.name,
			"status":    "provisioning",
			"last_seen": supportClock().Format(time.RFC3339),
			"ttl_s":     supportProvisioningTTL,
		},
	}
	body := map[string]any{"mutations": []any{
		map[string]any{"createOrReplace": doc},
		// _draft:false is expressed mechanically: publish in the SAME atomic batch.
		map[string]any{"publish": map[string]any{"id": "listener-" + r.name, "type": "listener"}},
	}}
	status, resp, err := supportMainJSON(http.MethodPost, r.base+"/v1/data/mutate/"+url.PathEscape(r.dataset), r.token, body)
	if err != nil {
		return r.fail("roster-row", "cannot reach the main: "+err.Error(),
			fmt.Sprintf("box %s up at %s; NO roster row written", r.host.Name, r.host.IP),
			"check the active main (`bp use`) and its token, then re-run `bp cloud support add "+r.name+"`",
			exitGeneric)
	}
	if status < 200 || status >= 300 {
		return r.fail("roster-row", fmt.Sprintf("main answered %d: %s", status, supportTrim(resp)),
			fmt.Sprintf("box %s up at %s; NO roster row written", r.host.Name, r.host.IP),
			"fix the main's token/permissions (the mutate route needs write) and re-run `bp cloud support add "+r.name+"`",
			exitGeneric)
	}
	r.done("roster-row", fmt.Sprintf("published listener-%s (provisioning, ttl_s=%d)", r.name, supportProvisioningTTL))
	return exitOK, false
}

// stepConfigure — the REDUCED go-live subset (PDF-D59) + LOCAL health probe.
func (r *supportAddRun) stepConfigure() (int, bool) {
	r.state("configure", "freshen → secrets-mint → secrets-install → migrate → admin-token → local health")
	secrets, err := supportConfigureHost(supportCtx(), r.runner, cloud.SupportConfigureOpts{
		SecretsGen: supportSecretsGen,
		Narrate:    func(state, detail string) { r.out.progressf("  · %s: %s", state, detail) },
	})
	if err != nil {
		return r.fail("configure", err.Error(),
			fmt.Sprintf("box %s up at %s; roster row listener-%s reads provisioning and will honestly age to offline at its ttl", r.host.Name, r.host.IP, r.name),
			fmt.Sprintf("inspect the box (`ssh root@%s`), then either re-run `bp cloud support add %s` or reclaim it with `bp cloud instance delete %s --provider hetzner --yes`", r.host.IP, r.name, r.host.Name),
			exitGeneric)
	}
	r.secrets = secrets
	r.done("configure", "box serves Barkpark on localhost with its own secrets")
	return exitOK, false
}

// stepBind — mint the ledger token + register the control-plane support row.
// Both are RUNTIME HTTP calls on the main (sibling slices ship the routes; no
// compile-time coupling). The minted token is delivered to the box in
// stepRuntime — 0600, never printed.
func (r *supportAddRun) stepBind() (int, bool) {
	r.state("bind", "minting a support token on the main's ledger")
	// The mint contract key is "name" (the endpoint labels the token
	// fleet-support-<name>); "worker" rides along as provenance only.
	status, resp, err := supportMainJSON(http.MethodPost, r.base+"/v1/fleet/support-tokens",
		r.token, map[string]any{"name": r.name, "worker": r.name})
	if err != nil || status < 200 || status >= 300 {
		reason := ""
		if err != nil {
			reason = err.Error()
		} else {
			reason = fmt.Sprintf("main answered %d: %s", status, supportTrim(resp))
		}
		return r.fail("bind", "support-token mint failed: "+reason,
			fmt.Sprintf("box %s configured at %s; roster row provisioning; NO token minted, NO control-plane row", r.host.Name, r.host.IP),
			"the main must serve POST /v1/fleet/support-tokens (update it to a build that has the fleet bind routes), then re-run `bp cloud support add "+r.name+"`",
			exitGeneric)
	}
	tok, tokID := supportParseMint(resp)
	if tok == "" {
		return r.fail("bind", "the mint response carried no token (looked for token/secret/value): "+supportTrim(resp),
			fmt.Sprintf("box %s configured at %s; roster row provisioning; NO usable token", r.host.Name, r.host.IP),
			"inspect the main's /v1/fleet/support-tokens response shape, then re-run `bp cloud support add "+r.name+"`",
			exitGeneric)
	}
	if !supportTokenSafeRe.MatchString(tok) {
		return r.fail("bind", "the minted token has an unexpected shape; refusing to interpolate it into an on-box script",
			fmt.Sprintf("box %s configured at %s; roster row provisioning; token discarded", r.host.Name, r.host.IP),
			"inspect the main's token mint, then re-run `bp cloud support add "+r.name+"`",
			exitGeneric)
	}
	r.ledgerToken, r.tokenID = tok, tokID

	r.state("bind", "registering the control-plane support row (fleet group record)")
	// Contract keys per the CP endpoint (PDF-D61): name + parent_id (REQUIRED
	// server-side) + host + token_id. worker/provider/server_name/agent ride
	// along as provenance the endpoint is free to ignore.
	reg := map[string]any{
		"worker":      r.name,
		"name":        r.name,
		"host":        r.host.IP,
		"provider":    "hetzner",
		"server_name": r.host.Name,
		"agent":       r.agent,
	}
	if r.tokenID != "" {
		reg["token_id"] = r.tokenID
	}
	// parent_id is the MAIN's control-plane row id — the CP endpoint REQUIRES
	// it (422 without). --parent supplies it explicitly; when absent we still
	// send the registration so the refusal is the server's honest one.
	if r.parent != "" {
		reg["parent_id"] = r.parent
	}
	status, resp, err = supportMainJSON(http.MethodPost, r.base+"/v1/fleet/supports", r.token, reg)
	if err != nil || status < 200 || status >= 300 {
		reason := ""
		if err != nil {
			reason = err.Error()
		} else {
			reason = fmt.Sprintf("main answered %d: %s", status, supportTrim(resp))
		}
		return r.fail("bind", "control-plane support registration failed: "+reason,
			fmt.Sprintf("box %s configured at %s; token minted (id %s) but NOT registered — mint again on retry rather than reusing", r.host.Name, r.host.IP, r.tokenID),
			"the target must serve POST /v1/fleet/supports and the group record needs the main's row id — re-run with `bp cloud support add "+r.name+" --parent <the main's control-plane row id>`",
			exitGeneric)
	}
	r.done("bind", fmt.Sprintf("token minted (id %s) + support row registered for %s", supportOr(r.tokenID, "unreported"), r.name))
	return exitOK, false
}

// stepDataset — the scrubbed pull (PDS twin doctrine): dev-profile dataset
// export FROM the main, streamed over SSH, merge-imported into the box's OWN
// localhost API (allow_bundle_import enabled first; bp installed first — the
// on-box import runs through the box's bp).
func (r *supportAddRun) stepDataset() (int, bool) {
	r.state("dataset", fmt.Sprintf("dev-profile (scrubbed) export of %s/%s from the main", r.ws, r.dataset))
	tar, err := r.exportDatasetTar()
	if err != nil {
		return r.fail("dataset", err.Error(),
			fmt.Sprintf("box %s bound at %s; NO dataset copied yet", r.host.Name, r.host.IP),
			"check the main's export route (`bp cloud workspace export "+r.ws+" --profile dev`) and re-run `bp cloud support add "+r.name+"`",
			exitGeneric)
	}
	defer func() {
		tar.Close()
		os.Remove(tar.Name())
	}()

	r.state("dataset", "streaming the bundle to the box over SSH")
	if _, err := r.runner.RunFeed(supportCtx(), "stream dataset bundle",
		`mkdir -p /opt/barkpark-fleet && cat > /opt/barkpark-fleet/dataset.tar`, tar); err != nil {
		return r.fail("dataset", "stream to box failed: "+err.Error(),
			fmt.Sprintf("box %s bound at %s; bundle NOT on the box", r.host.Name, r.host.IP),
			"re-run `bp cloud support add "+r.name+"` (the export is repeatable)",
			exitGeneric)
	}

	r.state("dataset", "enabling workspace bundle import on the box (BARKPARK_ALLOW_BUNDLE_IMPORT=1)")
	if err := r.runner.Run(supportCtx(), supportEnableImportStep()); err != nil {
		return r.fail("dataset", "enable bundle import failed: "+err.Error(),
			fmt.Sprintf("box %s bound at %s; bundle on the box but import stays fail-closed", r.host.Name, r.host.IP),
			fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
			exitGeneric)
	}

	r.state("dataset", "installing bp on the box (scripts/install-cli.sh; skipped when present)")
	if err := r.runner.Run(supportCtx(), supportEnsureBpStep()); err != nil {
		return r.fail("dataset", "bp install on the box failed: "+err.Error(),
			fmt.Sprintf("box %s bound at %s; bundle staged but not imported", r.host.Name, r.host.IP),
			fmt.Sprintf("install bp by hand (`ssh root@%s 'sh /opt/barkpark/scripts/install-cli.sh'`), then re-run `bp cloud support add %s`", r.host.IP, r.name),
			exitGeneric)
	}

	r.state("dataset", fmt.Sprintf("merge-importing %s into the box's local workspace %q", r.dataset, r.ws))
	if err := r.runner.Run(supportCtx(), supportImportStep(r.ws, r.secrets.AdminToken)); err != nil {
		return r.fail("dataset", "on-box import failed: "+err.Error(),
			fmt.Sprintf("box %s bound at %s; bundle staged at /opt/barkpark-fleet/dataset.tar but not imported", r.host.Name, r.host.IP),
			fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
			exitGeneric)
	}
	r.done("dataset", fmt.Sprintf("scrubbed %s/%s merged into the box", r.ws, r.dataset))
	return exitOK, false
}

// stepRuntime — the listener runtime (PDF-D62): fleet-run.sh + protocol from
// origin/main content, the agent CLI FAIL-OPEN, the measured capacity ceiling,
// and the systemd unit + 0600 env carrying BARKPARK_API_URL/BARKPARK_API_TOKEN
// (exact var names — bp's env context reads them; BARKPARK_TOKEN is a
// documented shadow hazard). Agent provider keys are NEVER copied.
func (r *supportAddRun) stepRuntime() (int, bool) {
	r.state("runtime", "writing fleet-run.sh + fleet-protocol.md (origin/main content)")
	if err := r.runner.Run(supportCtx(), supportFleetFilesStep()); err != nil {
		return r.fail("runtime", "fleet runtime files failed: "+err.Error(),
			fmt.Sprintf("box %s bound + data loaded at %s; listener runtime absent", r.host.Name, r.host.IP),
			fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
			exitGeneric)
	}

	// FAIL-OPEN: the listener's presence never depends on the agent CLI — a
	// missing agent degrades ORDERS, loudly, not the bring-up.
	spec := supportAgentPackages[r.agent]
	r.state("runtime", fmt.Sprintf("installing node + %s CLI (%s) — fail-open", r.agent, spec.pkg))
	if err := r.runner.Run(supportCtx(), supportAgentInstallStep(spec.pkg, spec.bin)); err != nil {
		r.out.errf("⚠ runtime: %s CLI install degraded (%v) — the listener will come online but orders will fail until you install %s on the box", r.agent, err, spec.pkg)
	}

	r.state("runtime", "measuring the box's size class (fleet-run.sh capacity)")
	if out, err := r.runner.RunOutput(supportCtx(), supportCapacityMeasureScript); err == nil {
		r.maxClass = supportParseSizeClass(out)
	}
	if r.maxClass == "" {
		r.out.errf("⚠ runtime: capacity measure degraded — FLEET_MAX_CLASS omitted; the listener measures itself at each beat")
	}

	r.state("runtime", "writing /etc/barkpark/fleet-listener.env (0600) + the systemd unit")
	if err := r.runner.Run(supportCtx(), supportUnitInstallStep(r.base, r.ledgerToken, r.name, r.agent, r.maxClass)); err != nil {
		return r.fail("runtime", "unit/env install failed: "+err.Error(),
			fmt.Sprintf("box %s bound + data loaded at %s; listener not yet supervised", r.host.Name, r.host.IP),
			fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
			exitGeneric)
	}
	r.done("runtime", "listener runtime installed (unit barkpark-fleet-listener, env 0600)")
	return exitOK, false
}

// stepOnline — enable the unit, hand over the key one-liner (keys are never
// copied), then poll the MAIN's roster until the row truthfully reads
// online-with-capacity or the budget expires.
func (r *supportAddRun) stepOnline() (int, bool) {
	r.state("online", "enabling barkpark-fleet-listener on the box")
	if err := r.runner.Run(supportCtx(), cloud.CaddyStep{
		Title: "enable + start the fleet listener",
		Argv:  []string{"bash", "-lc", "set -e; systemctl daemon-reload; systemctl enable --now barkpark-fleet-listener"},
	}); err != nil {
		return r.fail("online", "systemctl enable failed: "+err.Error(),
			fmt.Sprintf("box %s fully installed at %s; listener not running", r.host.Name, r.host.IP),
			fmt.Sprintf("`ssh root@%s 'systemctl status barkpark-fleet-listener'`, fix, then `systemctl enable --now barkpark-fleet-listener`", r.host.IP),
			exitGeneric)
	}

	// PDF-D62 / chat-hands D5: provider keys are handed over BY THE DEVELOPER.
	// Print the one-liner before the poll so a timeout still leaves it in hand.
	spec := supportAgentPackages[r.agent]
	r.out.progressf("")
	r.out.progressf("agent provider keys are NEVER copied — hand the box its %s key yourself:", r.agent)
	r.out.progressf("  ssh root@%s \"printf '%s=<your-key>\\n' >> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener\"", r.host.IP, spec.keyVar)
	r.out.progressf("")

	r.state("online", fmt.Sprintf("polling the main's roster for %s → online-with-capacity (budget %s)", r.name, supportRosterPollBudget))
	deadline := supportClock().Add(supportRosterPollBudget)
	var lastStatus string
	for {
		row, err := supportRosterRow(r.base, r.token, r.dataset, r.name)
		if err == nil && row != nil {
			st, _ := row["status"].(string)
			lastStatus = st
			capMap, hasCap := row["capacity"].(map[string]any)
			if (st == "idle" || st == "working" || st == "blocked") && hasCap && len(capMap) > 0 {
				r.done("online", fmt.Sprintf("%s reads %s with capacity %s on the main's roster", r.name, st, supportCompactJSON(capMap)))
				return exitOK, false
			}
		}
		if !supportClock().Before(deadline) {
			return r.fail("online",
				fmt.Sprintf("the roster did not reach online-with-capacity within %s (last read: %s) — never faking online; the provisioning row now ages to offline at its ttl", supportRosterPollBudget, supportOr(lastStatus, "no row")),
				fmt.Sprintf("box %s fully installed at %s; listener enabled but not (yet) beating with capacity", r.host.Name, r.host.IP),
				fmt.Sprintf("watch it with `ssh root@%s 'journalctl -u barkpark-fleet-listener -f'` and `bp fleet roster`; the row flips online on its first capacity beat", r.host.IP),
				exitGeneric)
		}
		time.Sleep(supportRosterPollInterval)
	}
}

// success emits the final receipt — human summary or one JSON document.
func (r *supportAddRun) success() int {
	spec := supportAgentPackages[r.agent]
	payload := map[string]any{
		"ok": true,
		"support": map[string]any{
			"name":      r.name,
			"agent":     r.agent,
			"server":    r.host.Name,
			"ip":        r.host.IP,
			"provider":  "hetzner",
			"token_id":  r.tokenID,
			"max_class": r.maxClass,
			"unit":      "barkpark-fleet-listener",
		},
		"main":    map[string]any{"url": r.base, "workspace": r.ws, "dataset": r.dataset},
		"key_var": spec.keyVar,
	}
	if r.out.emitStructured(payload) {
		return exitOK
	}
	r.out.outf("")
	r.out.outf("✓ support %s is ONLINE — one more machine serving your main", r.name)
	r.out.outf("  main:   %s (%s/%s, scrubbed pull)", r.base, r.ws, r.dataset)
	r.out.outf("  box:    %s at %s (hetzner, label %s=%s)", r.host.Name, r.host.IP, cloud.FleetSupportLabelKey, r.name)
	r.out.outf("  agent:  %s (hand it %s via the ssh one-liner above)", r.agent, spec.keyVar)
	r.out.outf("  next:   `bp fleet roster` shows it; route an order by naming assignee=%s", r.name)
	return exitOK
}

// ── on-box step builders (pure — tests assert their scripts) ─────────────────

// supportEnableImportStep flips the box's fail-closed bundle-import switch and
// restarts Barkpark, then waits for the loopback API to answer again. The .env
// edit is idempotent (strip + append, the secretsInstallStep idiom).
func supportEnableImportStep() cloud.CaddyStep {
	script := `set -e
touch /opt/barkpark/.env
grep -v '^BARKPARK_ALLOW_BUNDLE_IMPORT=' /opt/barkpark/.env > /opt/barkpark/.env.bpnew || true
printf 'BARKPARK_ALLOW_BUNDLE_IMPORT=1\n' >> /opt/barkpark/.env.bpnew
mv /opt/barkpark/.env.bpnew /opt/barkpark/.env
systemctl restart barkpark
for i in $(seq 1 60); do curl -fsS http://localhost:4000/api/schemas >/dev/null 2>&1 && exit 0; sleep 2; done
echo 'barkpark did not come back after restart' >&2; exit 1`
	return cloud.CaddyStep{
		Title: "enable workspace bundle import (BARKPARK_ALLOW_BUNDLE_IMPORT=1) + restart",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportEnsureBpStep installs bp via the committed installer when absent —
// the on-box import (and later operator SSH sessions) run through it.
func supportEnsureBpStep() cloud.CaddyStep {
	script := `set -e
command -v bp >/dev/null 2>&1 && exit 0
sh /opt/barkpark/scripts/install-cli.sh`
	return cloud.CaddyStep{
		Title: "install the bp CLI on the box (scripts/install-cli.sh)",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportImportStep merge-imports the staged bundle into the box's OWN
// localhost API with the box's minted admin token (BP_TOK env — Argv only,
// redacted; never in the narrated Title/Cmd).
func supportImportStep(ws, adminToken string) cloud.CaddyStep {
	script := `set -e; export BP_TOK='` + adminToken + `'; export PATH=/usr/local/bin:/usr/bin:$PATH
bp -s http://localhost:4000 --token "$BP_TOK" cloud workspace import '` + ws + `' --file /opt/barkpark-fleet/dataset.tar --yes --merge`
	return cloud.CaddyStep{
		Title:  "merge-import the scrubbed dataset bundle into the box (bp cloud workspace import --merge)",
		Cmd:    "bp cloud workspace import " + ws + " --file /opt/barkpark-fleet/dataset.tar --yes --merge (token redacted)",
		Argv:   []string{"bash", "-lc", script},
		Redact: []string{adminToken},
	}
}

// supportFleetFilesStep writes the fleet runtime from origin/main CONTENT:
// raw.githubusercontent origin/main first, the freshened on-box checkout as
// the fallback (PDF-D62/D64 — never an operator machine's stale copy).
func supportFleetFilesStep() cloud.CaddyStep {
	script := `set -e
mkdir -p /opt/barkpark-fleet
fetch(){ curl -fsSL "` + supportRawBase + `/$1" -o "$2" 2>/dev/null || cp "/opt/barkpark/$1" "$2"; }
fetch tooling/fleet/fleet-run.sh /opt/barkpark-fleet/fleet-run.sh
fetch tooling/fleet/fleet-protocol.md /opt/barkpark-fleet/fleet-protocol.md
chmod 0755 /opt/barkpark-fleet/fleet-run.sh`
	return cloud.CaddyStep{
		Title: "write fleet-run.sh + fleet-protocol.md from origin/main content",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportAgentInstallStep installs node + the agent CLI. The CALLER treats a
// failure as a WARNING (fail-open): presence never depends on the vendor CLI.
func supportAgentInstallStep(pkg, bin string) cloud.CaddyStep {
	script := `set -e
command -v node >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 && apt-get install -y nodejs npm >/dev/null 2>&1; }
npm install -g '` + pkg + `' >/dev/null 2>&1
command -v '` + bin + `' >/dev/null 2>&1`
	return cloud.CaddyStep{
		Title: "install node + the agent CLI (" + pkg + ") — fail-open",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportCapacityMeasureScript measures the box's size class through the SAME
// measurer the listener beats with (fleet-run.sh capacity, PDF-D36) — never a
// second RAM formula.
const supportCapacityMeasureScript = `bash /opt/barkpark-fleet/fleet-run.sh capacity`

// supportUnitInstallStep writes the 0600 listener env (the minted ledger token
// rides in via $BP_FLEET_TOK — Argv only, redacted) and installs the committed
// unit (origin/main content, on-box checkout fallback). It does NOT enable the
// unit — that is its own named state.
func supportUnitInstallStep(mainBase, ledgerToken, worker, agent, maxClass string) cloud.CaddyStep {
	classLine := ""
	if supportClassVocab[maxClass] {
		classLine = `printf 'FLEET_MAX_CLASS=%s\n' '` + maxClass + `' >> /etc/barkpark/fleet-listener.env` + "\n"
	}
	script := `set -e
export BP_FLEET_TOK='` + ledgerToken + `'
mkdir -p /etc/barkpark
umask 077
: > /etc/barkpark/fleet-listener.env
printf 'BARKPARK_API_URL=%s\n' '` + mainBase + `' >> /etc/barkpark/fleet-listener.env
printf 'BARKPARK_API_TOKEN=%s\n' "$BP_FLEET_TOK" >> /etc/barkpark/fleet-listener.env
printf 'FLEET_WORKER=%s\n' '` + worker + `' >> /etc/barkpark/fleet-listener.env
printf 'FLEET_AGENT=%s\n' '` + agent + `' >> /etc/barkpark/fleet-listener.env
` + classLine + `chmod 600 /etc/barkpark/fleet-listener.env
curl -fsSL "` + supportRawBase + `/deploy/systemd/barkpark-fleet-listener.service" -o /etc/systemd/system/barkpark-fleet-listener.service 2>/dev/null || install -m 0644 /opt/barkpark/deploy/systemd/barkpark-fleet-listener.service /etc/systemd/system/barkpark-fleet-listener.service
chmod 0644 /etc/systemd/system/barkpark-fleet-listener.service`
	return cloud.CaddyStep{
		Title:  "write /etc/barkpark/fleet-listener.env (0600) + install barkpark-fleet-listener.service",
		Cmd:    "write fleet-listener.env with BARKPARK_API_URL/BARKPARK_API_TOKEN (token redacted) + install the unit",
		Argv:   []string{"bash", "-lc", script},
		Redact: []string{ledgerToken},
	}
}

// ── main-API helpers ─────────────────────────────────────────────────────────

// exportDatasetTar GETs the dev-profile (scrubbed) dataset bundle from the
// main into a temp file and returns it opened for reading.
func (r *supportAddRun) exportDatasetTar() (*os.File, error) {
	q := url.Values{}
	q.Set("profile", "dev")
	q.Set("dataset", r.dataset)
	q.Set("source_server", r.base)
	target := r.base + "/api/workspaces/" + url.PathEscape(r.ws) + "/export?" + q.Encode()
	req, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		return nil, fmt.Errorf("build export request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+r.token)
	req.Header.Set("Accept", "application/x-tar, application/json")
	resp, err := newTransferClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("export request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := readCapped(resp.Body, maxResponseBytes)
		return nil, fmt.Errorf("export answered %d: %s", resp.StatusCode, supportTrim(body))
	}
	f, err := os.CreateTemp("", "bp-support-dataset-*.tar")
	if err != nil {
		return nil, fmt.Errorf("create temp bundle: %w", err)
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(f.Name())
		return nil, fmt.Errorf("stream export: %w", err)
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		f.Close()
		os.Remove(f.Name())
		return nil, fmt.Errorf("rewind bundle: %w", err)
	}
	return f, nil
}

// supportMainJSON POSTs/GETs one JSON payload against the main and returns
// (status, body, transport error). Non-2xx is NOT an error here — callers own
// the honest message per step.
func supportMainJSON(method, target, token string, payload any) (int, []byte, error) {
	var rdr io.Reader
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, fmt.Errorf("encode request: %w", err)
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, target, rdr)
	if err != nil {
		return 0, nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := newTransferClient().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, rerr := readCapped(resp.Body, maxResponseBytes)
	if rerr != nil {
		return resp.StatusCode, nil, fmt.Errorf("read response: %w", rerr)
	}
	return resp.StatusCode, body, nil
}

// supportRosterRow GETs the main's roster (the documents envelope, PDF-D21)
// and returns the row whose worker matches, nil when absent.
func supportRosterRow(base, token, dataset, worker string) (map[string]any, error) {
	status, body, err := supportMainJSON(http.MethodGet,
		base+"/v1/fleet/roster?dataset="+url.QueryEscape(dataset), token, nil)
	if err != nil {
		return nil, err
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("roster answered %d: %s", status, supportTrim(body))
	}
	var env struct {
		Documents []map[string]any `json:"documents"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return nil, fmt.Errorf("roster payload not parseable: %w", jerr)
	}
	for _, d := range env.Documents {
		if w, _ := d["worker"].(string); w == worker {
			return d, nil
		}
	}
	return nil, nil
}

// supportParseMint reads the minted token + token id out of the mint response,
// leniently: top-level first, then one known wrapper level — the route ships
// in a sibling slice, so the exact envelope key must not be a coupling point.
func supportParseMint(body []byte) (token, tokenID string) {
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return "", ""
	}
	layers := []map[string]any{m}
	for _, wrapper := range []string{"support_token", "token", "doc", "data"} {
		if sub, ok := m[wrapper].(map[string]any); ok {
			layers = append(layers, sub)
		}
	}
	for _, layer := range layers {
		if token == "" {
			for _, k := range []string{"token", "secret", "value", "bearer"} {
				if s, ok := layer[k].(string); ok && strings.TrimSpace(s) != "" {
					token = s
					break
				}
			}
		}
		if tokenID == "" {
			for _, k := range []string{"token_id", "id"} {
				if s, ok := layer[k].(string); ok && strings.TrimSpace(s) != "" {
					tokenID = s
					break
				}
			}
		}
	}
	// The wrapper named "token" may itself BE the token string.
	if token == "" {
		if s, ok := m["token"].(string); ok {
			token = s
		}
	}
	return token, tokenID
}

// supportParseSizeClass reads size_class out of fleet-run.sh capacity's JSON,
// "" when unparseable or off-vocabulary (the caller degrades loudly).
func supportParseSizeClass(out string) string {
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "{") {
			continue
		}
		var m struct {
			SizeClass string `json:"size_class"`
		}
		if err := json.Unmarshal([]byte(line), &m); err == nil && supportClassVocab[m.SizeClass] {
			return m.SizeClass
		}
	}
	return ""
}

// ── small formatting helpers ─────────────────────────────────────────────────

// supportTrim renders a response body into an error message: single line,
// bounded, never empty.
func supportTrim(b []byte) string {
	s := strings.Join(strings.Fields(string(b)), " ")
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	if s == "" {
		return "(empty body)"
	}
	return s
}

func supportOr(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}

func supportCompactJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(b)
}

// ── help ─────────────────────────────────────────────────────────────────────

func printCloudSupportHelp(out *writer) {
	const help = `bp cloud support — grow your Personal Dev Fleet with one action.

USAGE
  bp cloud support add <name> [--agent claude|codex] [--workspace <slug>]
                              [--dataset <slug>] [--parent <cp-row-id>]
                              [--dry-run] [-o json|yaml]

WHAT IT DOES (eight named states, in order)
  create      provision an x86 warm-image box on hetzner, labeled
              barkpark-fleet-support=<name>. A placement failure writes NOTHING.
  wait-ready  poll sshd on the new box.
  roster-row  publish listener-<name> {status:provisioning, ttl_s:1800} on the
              MAIN's ledger (only now that a box exists — the row never lies).
  configure   the reduced go-live chain on the box: freshen → per-instance
              secrets → migrate → admin token → LOCAL health probe. No DNS, no
              TLS, no public identity — a support serves the main, not the web.
  bind        mint a support token on the main (/v1/fleet/support-tokens) and
              register the control-plane support row (/v1/fleet/supports).
  dataset     dev-profile (SCRUBBED) export of the main's dataset, streamed
              over SSH, merge-imported into the box's own Barkpark.
  runtime     fleet-run.sh + fleet-protocol.md (origin/main content), the agent
              CLI (fail-open), and the systemd unit + 0600 env carrying
              BARKPARK_API_URL / BARKPARK_API_TOKEN.
  online      enable barkpark-fleet-listener and poll the main's roster until
              the row truthfully reads online WITH measured capacity, or report
              an honest timeout (the row then ages to offline — never faked).

  Agent provider keys are NEVER copied to the box: the command finishes by
  printing the exact ssh one-liner you run to hand them over yourself.

FLAGS
  --agent claude|codex   which agent CLI the listener runs orders with (default claude)
  --workspace <slug>     the main workspace to pull from (default: the active context)
  --dataset <slug>       the dataset to pull + register the listener under
                         (default: the active context, else production)
  --parent <cp-row-id>   the main's control-plane row id for the fleet group
                         record (default: the main resolves itself server-side)
  --dry-run              print the eight states and do nothing
  -o json|yaml           one machine-readable receipt on stdout

RELATED
  bp fleet roster        the fleet's presence table (who is online, with what)
  bp cloud support remove   not built yet — a planned round-2 verb`
	out.outf("%s", help)
}
