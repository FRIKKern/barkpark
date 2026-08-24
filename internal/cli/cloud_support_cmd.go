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
//   - the bind is TWO calls on TWO hosts (PDF-D69): the support token is minted
//     on the MAIN (POST /v1/fleet/support-tokens, admin-gated — it authorizes
//     ledger writes there), while the fleet group record is registered on the
//     CONTROL PLANE (POST /v1/fleet/supports, via the bp-login
//     CloudURL/CloudToken seam — the CP owns the fleet registry). Both are
//     RUNTIME HTTP calls — no compile-time dependency on the slices that ship
//     the routes.
//   - agent PROVIDER KEYS ARE NEVER COPIED (PDF-D62): the command finishes by
//     printing the exact SSH one-liner the developer runs themselves.
//   - barkpark.service is baked into the warm image — never authored here.
//
// `remove` is the mirror verb (PDF-D68): tear a support down across all FIVE
// surfaces — token (main), box (provider), leaked A records (DNS, swept by
// VALUE: every A rrset resolving to the box IP goes, PDF-D101), roster row
// (main), control-plane row (CP, deleted LAST because it is the sole durable
// holder of the token id) — then RE-READ every surface (delete responses prove
// nothing, D33) and exit non-zero naming every survivor. Idempotent: a double
// remove reports already-gone; partial state converges.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
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

// supportDNSFor resolves the DNS provider the remove-side A-record sweep rides,
// given the already-resolved DNS token ("" ⇔ compute fallback: CloudDNS
// inherits the process HCLOUD_TOKEN / `hcloud context`). The token precedence
// is instDNSClient's law (--dns-token > BARKPARK_DNS_HCLOUD_TOKEN > compute,
// PDF-D101): the fleet compute token that owns every box sees ZERO zones, so a
// one-token sweep would fail silently on every real teardown. A seam so tests
// inject FakeDNS and assert the credential that actually arrived.
var supportDNSFor = func(dnsToken string) cloud.DNSProvider {
	d := cloud.NewCloudDNS()
	d.Token = dnsToken
	return d
}

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
		return runCloudSupportRemove(out, g, rest)
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

	// The CONTROL PLANE the register leg targets (PDF-D69) — resolved from the
	// bp-login credentials (Config.CloudURL/CloudToken) BEFORE the box create,
	// so a known-missing credential never bills a box.
	cpBase  string
	cpToken string

	host    cloud.Server
	runner  cloud.SupportRunner
	secrets cloud.Secrets

	ledgerToken string // minted for the box, delivered 0600 — never printed
	tokenID     string
	cpRowID     string // the CP support row id the register leg returned
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
		out.progressf("  5. bind          mint POST /v1/fleet/support-tokens on the MAIN + register POST /v1/fleet/supports on the CONTROL PLANE (PDF-D69)")
		out.progressf("  6. dataset       dev-profile export of %s/%s → tar over SSH → merge-import into the box", r.ws, r.dataset)
		out.progressf("  7. runtime       fleet-run.sh + protocol (origin/main content), %s CLI fail-open, unit + env 0600", r.agent)
		out.progressf("  8. online        enable barkpark-fleet-listener, poll the roster to online-with-capacity (budget %s)", supportRosterPollBudget)
		return exitOK
	}

	// PDF-D69: the register leg targets the CONTROL PLANE, so the Cloud login is
	// checked UP FRONT — BEFORE the box create. A known-missing credential must
	// never bill a box (the D58 writes-nothing ethos). requireCloud emits the
	// exact "not logged in — run `bp login` first" wording.
	cfg, okc := requireCloud(out)
	if !okc {
		return exitAuth
	}
	cl := cfg.CloudClient()
	r.cpBase = strings.TrimRight(strings.TrimSpace(cl.BaseURL), "/")
	r.cpToken = cl.Token

	// PDF-D70: without --parent, resolve the main's control-plane row id BEFORE
	// the box create, so a zero/many refusal costs nothing.
	if r.parent == "" {
		if code, stop := r.resolveParent(); stop {
			return code
		}
	}

	return r.run()
}

// resolveParent (PDF-D70) resolves --parent's default: the control-plane row
// whose URL host matches the active main. The match key is hostname-of(row.url)
// — NEVER the host column, which is a raw IP on every real row (guerrilla:
// host=157.180.90.121 vs url=https://guerrilla.barkpark.cloud — a host-column
// match returns zero by construction, live-proven). Support rows can never be
// parents (the CP 422s them; we exclude them from candidacy). Exactly one match
// resolves; zero or many REFUSES, naming the candidates; explicit --parent
// skips this entirely.
func (r *supportAddRun) resolveParent() (int, bool) {
	rows, status, err := supportCPBarkparks(r.cpBase, r.cpToken)
	if err != nil {
		return useError(r.out, "failed",
			"resolve --parent: cannot reach the control plane ("+r.cpBase+"): "+err.Error()+" — nothing was created; pass --parent <cp-row-id> or retry",
			exitGeneric), true
	}
	if status == http.StatusUnauthorized {
		return useError(r.out, "auth",
			"resolve --parent: the control plane rejected the Cloud session (401) — not logged in; run `bp login` first",
			exitAuth), true
	}
	if status < 200 || status >= 300 {
		return useError(r.out, "failed",
			fmt.Sprintf("resolve --parent: the control plane answered %d listing your fleet — nothing was created; pass --parent <cp-row-id> or retry", status),
			exitGeneric), true
	}

	wantHost := hostOf(r.base)
	var matches []supportCPRow
	var candidates []string
	for _, row := range rows {
		if row.FleetRole == "support" {
			continue // two-tier: a support can never be a parent
		}
		candidates = append(candidates, supportCPRowLabel(row))
		if row.URL != "" && hostOf(row.URL) == wantHost {
			matches = append(matches, row)
		}
	}
	switch len(matches) {
	case 1:
		r.parent = matches[0].ID
		r.out.progressf("→ parent: resolved %s — its url host matches the active main (%s)", supportCPRowLabel(matches[0]), wantHost)
		return exitOK, false
	case 0:
		return useError(r.out, "failed",
			fmt.Sprintf("resolve --parent: no control-plane row's url matches the active main's host %q — nothing was created. Candidates: %s. Re-run with `bp cloud support add %s --parent <cp-row-id>`",
				wantHost, supportOr(strings.Join(candidates, ", "), "(none — is this main registered on the control plane?)"), r.name),
			exitGeneric), true
	default:
		var names []string
		for _, m := range matches {
			names = append(names, supportCPRowLabel(m))
		}
		return useError(r.out, "failed",
			fmt.Sprintf("resolve --parent: %d control-plane rows match the active main's host %q — refusing to pick one. Candidates: %s. Re-run with `bp cloud support add %s --parent <cp-row-id>`",
				len(matches), wantHost, strings.Join(names, ", "), r.name),
			exitGeneric), true
	}
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
//
// The three composers below are PURE: no receiver, no I/O, one server answer in
// and the printed sentence out. They exist so the success-claim registry
// (success_claim_registry_test.go) can CALL the production sentence instead of
// mirroring its format string — stepOnline and stepDNS drive ssh + network and
// cannot be rendered, and a mirror only ever pins the mirror.
//
// PDS-D431: each one takes the SERVER'S ANSWER WHOLE and does its own
// extraction. Handing them pre-destructured leaves (a status, a capacity map, a
// fqdn list) would move the destructuring back into the caller — and an
// argument the caller stops passing is exactly the drop these rows exist to
// catch, so the hole would re-open one frame up.

// supportOnlineNarration composes stepOnline's ONLINE receipt from the MAIN'S
// ROSTER ROW — a decoded JSON body (supportRosterRow returns map[string]any),
// never from anything the local verb already knew. Both measured facts (the
// row's status and its capacity) are read HERE.
func supportOnlineNarration(name string, row map[string]any) string {
	st, _ := row["status"].(string)
	capMap, _ := row["capacity"].(map[string]any)
	return fmt.Sprintf("%s reads %s with capacity %s on the main's roster", name, st, supportCompactJSON(capMap))
}

// supportDNSNarration composes stepDNS's sweep receipt — BOTH branches, so the
// clean/swept fork and the fqdn mapping live in one place. `deleted` is what
// the ZONE returned (the rrset names it actually removed), and the names are
// qualified against the zone here rather than by the caller.
func supportDNSNarration(zone, ip string, deleted []string) string {
	if len(deleted) == 0 {
		return fmt.Sprintf("no A records in %s resolve to %s (already clean)", zone, ip)
	}
	fqdns := make([]string, 0, len(deleted))
	for _, n := range deleted {
		fqdns = append(fqdns, cloud.Fqdn(n, zone))
	}
	return fmt.Sprintf("%d A record(s) deleted: %s (the census re-reads the zone)", len(deleted), strings.Join(fqdns, ", "))
}

// supportCapacityNarration renders the box's MEASURED size class for the human
// receipt. Until now max_class rode the machine envelope only, so the human
// sentence carried no measured fact at all and arm 3 had nothing to attribute
// on both surfaces. A degraded measure is stated as degraded — never silently
// omitted and never guessed.
func supportCapacityNarration(maxClass string) string {
	if maxClass == "" {
		return "not measured (degraded) — the listener measures itself at each beat"
	}
	return maxClass + " (measured on the box by fleet-run.sh capacity)"
}

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

	r.state("bind", "registering the fleet group record on the CONTROL PLANE ("+r.cpBase+")")
	// PDF-D69: POST /v1/fleet/supports exists ONLY on the control plane (the CP
	// owns the fleet registry) — it rides the CloudURL/CloudToken seam, never
	// the main. Contract keys (PDF-D61): name + parent_id (REQUIRED server-side)
	// + host + token_id. worker/provider/server_name/agent ride along as
	// provenance the endpoint is free to ignore.
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
	if r.parent != "" {
		reg["parent_id"] = r.parent
	}
	status, resp, err = supportMainJSON(http.MethodPost, r.cpBase+"/v1/fleet/supports", r.cpToken, reg)
	if err != nil {
		return r.fail("bind", "control-plane support registration failed: "+err.Error(),
			fmt.Sprintf("box %s configured at %s; token minted (id %s) but NOT registered — mint again on retry rather than reusing", r.host.Name, r.host.IP, r.tokenID),
			"check the control plane ("+r.cpBase+") is reachable, then re-run `bp cloud support add "+r.name+"`",
			exitGeneric)
	}
	if status < 200 || status >= 300 {
		written := fmt.Sprintf("box %s configured at %s; token minted (id %s) on the main but NOT registered — mint again on retry rather than reusing", r.host.Name, r.host.IP, r.tokenID)
		reason := fmt.Sprintf("control plane answered %d: %s", status, supportTrim(resp))
		// Named narrations per the CP's credential-aware contract (PDF-D69).
		switch {
		case status == http.StatusUnauthorized:
			return r.fail("bind", "control-plane support registration refused: "+reason,
				written,
				"the Cloud session is missing or dead — not logged in; run `bp login` first, then re-run `bp cloud support add "+r.name+"`",
				exitAuth)
		// The teamless refusal, on BOTH sides of the control plane's status
		// conversion: today 422 {"error":"no_team"}, after #9956
		// 403 {"error":"forbidden","reason":"no_team","scope":"team"}. Reading the
		// STATUS alone would drop this caller into the 403 arm below and hand a
		// user who HAS NO TEAM a sentence about a team-admin ROLE — which cannot be
		// granted without a team, and which points at re-authenticating a
		// credential that is fine. The CAUSE the server named decides, so the
		// sentence, the fix and the exit code are identical across the flip.
		case supportCPNoTeam(status, resp):
			return r.fail("bind", "control-plane support registration refused: "+reason,
				written,
				"your Cloud login has no active team — run `bp team use <team>`, then re-run `bp cloud support add "+r.name+"`",
				exitGeneric)
		case status == http.StatusForbidden:
			return r.fail("bind", "control-plane support registration refused: "+reason,
				written,
				"a session needs team-admin, a PAT needs the deploy ability — fix the credential, then re-run `bp cloud support add "+r.name+"`",
				exitAuth)
		case status == http.StatusNotFound:
			return r.fail("bind", "control-plane support registration refused: "+reason,
				written,
				"the parent row was not found in your team — re-run with `bp cloud support add "+r.name+" --parent <the main's control-plane row id>`",
				exitGeneric)
		default:
			return r.fail("bind", "control-plane support registration failed: "+reason,
				written,
				"the control plane must serve POST /v1/fleet/supports — re-run `bp cloud support add "+r.name+"` once it does",
				exitGeneric)
		}
	}
	r.cpRowID = supportParseCPRowID(resp)
	r.done("bind", fmt.Sprintf("token minted (id %s) on the main + support row %s registered on the control plane", supportOr(r.tokenID, "unreported"), supportOr(r.cpRowID, "(id unreported)")))
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

	// ws=="default" is the ONE slug whose import target is PRE-POLLUTED: the
	// warm image's baked Postgres carries the seed lineage's docs forward
	// (bake-server-image.sh snapshots the data dir), so the box's own "default"
	// flunks the merge engine's fail-closed empty-shell proof (PDS-D9) and the
	// import 409s workspace_slug_conflict. Reset: delete the seeded workspace
	// (absent → no-op), then re-mint the box admin token the delete cascaded
	// (api_tokens.workspace_id :delete_all; the mint's ensure_default_scope
	// also recreates the empty default scope). Same latent bug as the worker
	// chain — a laptop-added support serving a template-less main hits it too.
	resetDefault := r.ws == cloud.SupportDefaultWorkspaceSlug
	if resetDefault {
		r.state("dataset", "resetting the box's seeded default workspace to an empty import target")
		if err := r.runner.Run(supportCtx(), cloud.SupportResetDefaultWorkspaceStep()); err != nil {
			return r.fail("dataset", "default-workspace reset on the box failed: "+err.Error(),
				fmt.Sprintf("box %s bound at %s; bundle staged but not imported", r.host.Name, r.host.IP),
				fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
				exitGeneric)
		}
		r.state("dataset", "re-minting the box admin token (the reset delete cascaded it)")
		if err := r.runner.Run(supportCtx(), cloud.SupportAdminTokenStep(r.secrets.AdminToken)); err != nil {
			return r.fail("dataset", "admin-token re-mint after reset failed: "+err.Error(),
				fmt.Sprintf("box %s bound at %s; default workspace reset but the box holds NO admin token", r.host.Name, r.host.IP),
				fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
				exitGeneric)
		}
	}

	r.state("dataset", fmt.Sprintf("ensuring workspace %q exists on the box (already-exists is fine)", r.ws))
	if err := r.runner.Run(supportCtx(), supportEnsureWorkspaceStep(r.ws, r.secrets.AdminToken)); err != nil {
		return r.fail("dataset", "workspace ensure on the box failed: "+err.Error(),
			fmt.Sprintf("box %s bound at %s; bundle staged but not imported", r.host.Name, r.host.IP),
			fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
			exitGeneric)
	}

	r.state("dataset", fmt.Sprintf("merge-importing %s into the box's local workspace %q", r.dataset, r.ws))
	if err := r.runner.Run(supportCtx(), supportImportStep(r.ws, r.secrets.AdminToken)); err != nil {
		return r.fail("dataset", "on-box import failed: "+err.Error(),
			fmt.Sprintf("box %s bound at %s; bundle staged at /opt/barkpark-fleet/dataset.tar but not imported", r.host.Name, r.host.IP),
			fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
			exitGeneric)
	}

	if resetDefault {
		// The import's adopt branch deleted the empty "default" shell
		// IN-TRANSACTION (PDS-D9), cascading the token minted above a SECOND
		// time. Restore it so the credential this chain reported to the CP at
		// bind stays live; ensure_default_scope now resolves slug "default" to
		// the IMPORTED workspace, scoping the token to the content it governs.
		r.state("dataset", "restoring the box admin token (the import's adopt-delete cascaded it)")
		if err := r.runner.Run(supportCtx(), cloud.SupportAdminTokenStep(r.secrets.AdminToken)); err != nil {
			return r.fail("dataset", "admin-token restore after import failed: "+err.Error(),
				fmt.Sprintf("box %s bound at %s; dataset imported but the box holds NO admin token", r.host.Name, r.host.IP),
				fmt.Sprintf("inspect `ssh root@%s`, then re-run `bp cloud support add %s`", r.host.IP, r.name),
				exitGeneric)
		}
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
				r.done("online", supportOnlineNarration(r.name, row))
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
			"cp_row_id": r.cpRowID,
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
	r.out.outf("  size:   max class %s", supportCapacityNarration(r.maxClass))
	r.out.outf("  next:   `bp fleet roster` shows it; route an order by naming assignee=%s", r.name)
	return exitOK
}

// ── the mirror verb: remove ──────────────────────────────────────────────────

// supportProbeSecretScript best-effort reads the support's own ledger token off
// the box (0600 env written by add) so the census can run the REAL 403→401
// token probe instead of trusting the revoke receipt. Read-only; the secret
// stays in-process and is never printed.
const supportProbeSecretScript = `grep '^BARKPARK_API_TOKEN=' /etc/barkpark/fleet-listener.env | head -n1 | cut -d= -f2-`

// supportRemoveRun carries one `support remove` invocation's resolved inputs +
// accumulated truth. Teardown ORDER is law (PDF-D68): read the CP record FIRST
// (sole durable token-id holder), then token revoke on the main, then the
// identity-fenced box delete, then the leaked-A-record sweep (by VALUE,
// PDF-D101), then the roster row, then the CP row LAST — so a crash at any
// point never strands the token id. Then the five-surface census.
type supportRemoveRun struct {
	out *writer
	g   globals

	name    string
	dataset string

	base  string // the MAIN
	token string

	cpBase  string // the CONTROL PLANE (CloudURL/CloudToken seam)
	cpToken string

	provider cloud.CloudProvider
	lister   cloud.LabelLister

	rows  []supportCPRow // the CP support rows matching name (fleet_role=support)
	boxes []cloud.Server // label-matched boxes at locate time

	probeSecret string // the support's own token, ssh-read best-effort — never printed
	probeBefore int    // pre-revoke probe status (0 = never probed)

	revoked map[string]string // token_id → "revoked" | "already gone (404)"

	dnsToken    string            // resolved DNS credential (--dns-token > BARKPARK_DNS_HCLOUD_TOKEN > "" = compute)
	dnsTokenSrc string            // which rung resolved it — "compute" earns a loud warning
	dns         cloud.DNSProvider // built at stepDNS; nil ⇔ the DNS leg never ran
	dnsZone     string            // zone derived from the CP row's url host
	dnsIP       string            // the box IP the sweep + census match A-record VALUES against
	dnsSkip     string            // non-empty ⇔ why the DNS leg was skipped (printed honestly, never reported clean)
	dnsSwept    bool              // true ⇔ the by-value sweep RAN AND RETURNED CLEANLY — the only thing that earns ?mode=detach
	cpHandedOff map[string]string // CP row id → the status the control plane reported when it took the teardown over (202)
}

func runCloudSupportRemove(out *writer, g globals, args []string) int {
	const usage = "bp cloud support remove <name> [--dataset <slug>] [--dns-token <token>]"
	a, err := parseHzArgs(args, []string{"dataset", "dns-token"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <name> (usage: "+usage+")", exitUsage)
	}
	r := &supportRemoveRun{out: out, g: g, name: a.pos[0], revoked: map[string]string{}}
	if !supportNameRe.MatchString(r.name) {
		return useError(out, "usage",
			fmt.Sprintf("invalid support name %q — want a DNS-label shape (the name is the identity the teardown resolves by)", r.name),
			exitUsage)
	}

	ctx := resolveContext(g)
	r.base = strings.TrimRight(strings.TrimSpace(ctx.Server), "/")
	r.token = strings.TrimSpace(ctx.Token)
	if r.base == "" {
		return useError(out, "failed", "no main Barkpark resolved — run `bp use <name>` (or set BARKPARK_API_URL) so remove knows which main the support served", exitGeneric)
	}

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
	if !supportSlugRe.MatchString(r.dataset) {
		return useError(out, "usage", fmt.Sprintf("invalid dataset slug %q", r.dataset), exitUsage)
	}

	// The DNS sweep credential — instDNSClient's precedence (PDF-D101). The
	// compute fallback is remembered so the sweep can warn loudly: the fleet
	// compute token sees ZERO zones, and a silent zero-record sweep is exactly
	// the lie the by-value census exists to catch.
	r.dnsToken = strings.TrimSpace(a.val("dns-token"))
	r.dnsTokenSrc = "--dns-token"
	if r.dnsToken == "" {
		r.dnsToken = strings.TrimSpace(os.Getenv("BARKPARK_DNS_HCLOUD_TOKEN"))
		r.dnsTokenSrc = "BARKPARK_DNS_HCLOUD_TOKEN"
	}
	if r.dnsToken == "" {
		r.dnsTokenSrc = "compute"
	}

	if g.dryRun {
		out.progressf("DRY RUN — bp cloud support remove %s would run, in order (PDF-D68):", r.name)
		out.progressf("  1. cp-read   GET /v1/barkparks on the control plane — capture the support row id + token id FIRST")
		out.progressf("  2. locate    list boxes labeled %s=%s (identity-fenced; foreign identity refused)", cloud.FleetSupportLabelKey, r.name)
		out.progressf("  3. token     revoke the support token on the main (idempotent — 404 is already-gone)")
		out.progressf("  4. server    delete the box (only an exact identity match; >1 match refused)")
		out.progressf("  5. dns       sweep every A record in the zone that resolves to the box IP — by VALUE, not name (PDF-D101; credential: --dns-token > BARKPARK_DNS_HCLOUD_TOKEN > compute)")
		out.progressf("  6. roster    delete listener-%s on %s (dataset %s)", r.name, r.base, r.dataset)
		out.progressf("  7. cp-row    DELETE /v1/fleet/supports/:id on the control plane — LAST (sole durable token-id holder)")
		out.progressf("  8. census    RE-READ all five surfaces; any survivor is named and exits non-zero")
		return exitOK
	}

	// The CP legs ride the same bp-login seam the add's register leg uses.
	cfg, okc := requireCloud(out)
	if !okc {
		return exitAuth
	}
	cl := cfg.CloudClient()
	r.cpBase = strings.TrimRight(strings.TrimSpace(cl.BaseURL), "/")
	r.cpToken = cl.Token

	return r.run()
}

func (r *supportRemoveRun) run() int {
	steps := []func() (int, bool){
		r.stepCPRead,
		r.stepLocate,
		r.stepToken,
		r.stepServer,
		r.stepDNS,
		r.stepRoster,
		r.stepCPRow,
	}
	for _, step := range steps {
		if code, stop := step(); stop {
			return code
		}
	}
	return r.census()
}

func (r *supportRemoveRun) state(step, msg string) { r.out.progressf("→ %s: %s", step, msg) }
func (r *supportRemoveRun) done(step, msg string)  { r.out.progressf("✓ %s — %s", step, msg) }

// fail is the remove-side honest terminal state: reason, what is ACTUALLY still
// standing, and the exact next command. Partial state is safe by construction —
// the CP row (the token id's holder) is deleted last, so a re-run converges.
func (r *supportRemoveRun) fail(step, reason, standing string, code int) (int, bool) {
	if r.out.emitStructured(map[string]any{
		"ok":      false,
		"support": r.name,
		"step":    step,
		"error":   map[string]any{"code": "failed", "message": reason},
		"state":   standing,
		"next":    "re-run `bp cloud support remove " + r.name + "` — the teardown is idempotent and converges",
	}) {
		return code, true
	}
	r.out.userErr("✗ %s failed — %s", step, reason)
	r.out.errf("  state: %s", standing)
	r.out.errf("  next:  re-run `bp cloud support remove %s` — the teardown is idempotent and converges", r.name)
	return code, true
}

// stepCPRead — FIRST (PDF-D68): the CP support row is the SOLE durable holder
// of the token id (no GET route exists on fleet/supports or support-tokens), so
// it is read before anything is torn down and deleted after everything else.
func (r *supportRemoveRun) stepCPRead() (int, bool) {
	r.state("cp-read", "reading the support's control-plane record (GET /v1/barkparks on "+r.cpBase+")")
	rows, status, err := supportCPBarkparks(r.cpBase, r.cpToken)
	if err != nil {
		return r.fail("cp-read", "cannot reach the control plane: "+err.Error(),
			"nothing torn down yet", exitGeneric)
	}
	if status == http.StatusUnauthorized {
		return r.fail("cp-read", "the control plane rejected the Cloud session (401) — not logged in; run `bp login` first",
			"nothing torn down yet", exitAuth)
	}
	if status < 200 || status >= 300 {
		return r.fail("cp-read", fmt.Sprintf("the control plane answered %d listing your fleet", status),
			"nothing torn down yet", exitGeneric)
	}
	for _, row := range rows {
		if row.FleetRole == "support" && row.Name == r.name {
			r.rows = append(r.rows, row)
		}
	}
	if len(r.rows) == 0 {
		r.done("cp-read", fmt.Sprintf("no control-plane support row named %q (already unbound)", r.name))
		return exitOK, false
	}
	var ids []string
	for _, row := range r.rows {
		ids = append(ids, fmt.Sprintf("%s (token id %s)", row.ID, supportOr(row.FleetTokenID, "none")))
	}
	r.done("cp-read", strings.Join(ids, ", "))
	return exitOK, false
}

// stepLocate lists the label-matched boxes and re-checks each one's identity —
// the DeprovisionByIP fence, ported: NEVER delete a box whose
// barkpark-fleet-support label names a different identity, and NEVER pick one
// of several matches. Also best-effort captures the support's own token off the
// box (0600 env) so the census can run the real 403→401 probe, and takes the
// pre-revoke 403 baseline (a probe that cannot fail proves nothing).
func (r *supportRemoveRun) stepLocate() (int, bool) {
	provider, perr := supportProviderFor()
	if perr != nil {
		return r.fail("locate", perr.Error(),
			"nothing torn down yet — fix the provider credential (hetzner: set HCLOUD_TOKEN or an `hcloud context`)", exitAuth)
	}
	r.provider = provider
	lister, ok := provider.(cloud.LabelLister)
	if !ok {
		return r.fail("locate", "provider cannot list by label — cannot safely locate the support box",
			"nothing torn down yet", exitGeneric)
	}
	r.lister = lister

	r.state("locate", fmt.Sprintf("listing boxes labeled %s=%s", cloud.FleetSupportLabelKey, r.name))
	boxes, err := lister.ListByLabel(supportCtx(), cloud.FleetSupportLabelKey, r.name)
	if err != nil {
		return r.fail("locate", "list by label failed: "+err.Error(), "nothing torn down yet", exitGeneric)
	}
	// Identity fence: refuse LOUDLY on any foreign identity in the result —
	// deleting on a mismatched label is exactly the wrong-box deletion the
	// DeprovisionByIP lineage exists to prevent.
	for _, box := range boxes {
		if got := box.Labels[cloud.FleetSupportLabelKey]; got != r.name {
			return r.fail("locate",
				fmt.Sprintf("box %s (ip %s) is labeled %s=%q, not %q — REFUSING to touch a foreign identity; investigate manually",
					box.Name, box.IP, cloud.FleetSupportLabelKey, got, r.name),
				"nothing torn down yet", exitGeneric)
		}
	}
	if len(boxes) > 1 {
		var names []string
		for _, box := range boxes {
			names = append(names, fmt.Sprintf("%s (ip %s)", box.Name, box.IP))
		}
		return r.fail("locate",
			fmt.Sprintf("%d boxes carry %s=%s — an anomaly this command never picks-one from: %s; investigate manually",
				len(boxes), cloud.FleetSupportLabelKey, r.name, strings.Join(names, ", ")),
			"nothing torn down yet", exitGeneric)
	}
	r.boxes = boxes
	if len(boxes) == 0 {
		r.done("locate", fmt.Sprintf("no box carries %s=%s (already gone)", cloud.FleetSupportLabelKey, r.name))
		return exitOK, false
	}
	box := boxes[0]
	r.done("locate", fmt.Sprintf("%s at %s (identity verified: %s=%s)", box.Name, box.IP, cloud.FleetSupportLabelKey, r.name))

	// Best-effort probe-secret capture + 403 baseline. Failures here degrade the
	// census token leg to the revoke receipt — never the teardown.
	if secret, serr := supportRunnerFor(box.IP).RunOutput(supportCtx(), supportProbeSecretScript); serr == nil {
		secret = supportLastLine(secret)
		if secret != "" && supportTokenSafeRe.MatchString(secret) {
			r.probeSecret = secret
			if st, perr := supportTokenProbe(r.base, r.probeSecret); perr == nil {
				r.probeBefore = st
				r.state("locate", fmt.Sprintf("probe secret captured off the box (never printed); pre-revoke probe read %d", st))
			}
		}
	}
	if r.probeSecret == "" {
		r.state("locate", "probe secret unavailable (box env unreadable) — the census token leg falls back to the revoke receipt")
	}
	return exitOK, false
}

// stepToken revokes each recorded token id on the MAIN — idempotent (404 =
// already gone). A hard failure STOPS: the CP row still holds the token id, so
// a re-run converges instead of stranding a live credential.
func (r *supportRemoveRun) stepToken() (int, bool) {
	ids := supportTokenIDs(r.rows)
	if len(ids) == 0 {
		r.done("token", "no token id on record — nothing to revoke")
		return exitOK, false
	}
	for _, id := range ids {
		r.state("token", fmt.Sprintf("revoking support token %s on the main (%s)", id, r.base))
		status, resp, err := supportMainJSON(http.MethodDelete, r.base+"/v1/fleet/support-tokens/"+url.PathEscape(id), r.token, nil)
		if err != nil {
			return r.fail("token", "cannot reach the main: "+err.Error(),
				fmt.Sprintf("token %s NOT revoked; the control-plane row still holds its id", id), exitGeneric)
		}
		switch {
		case status >= 200 && status < 300:
			r.revoked[id] = "revoked"
			r.done("token", fmt.Sprintf("%s revoked (receipt %s)", id, supportTrim(resp)))
		case status == http.StatusNotFound:
			r.revoked[id] = "already gone (404)"
			r.done("token", id+" already gone (404)")
		case status == http.StatusUnauthorized || status == http.StatusForbidden:
			return r.fail("token", fmt.Sprintf("the main answered %d — the revoke route is admin-gated; use an admin token against the main", status),
				fmt.Sprintf("token %s NOT revoked; the control-plane row still holds its id", id), exitAuth)
		default:
			return r.fail("token", fmt.Sprintf("the main answered %d: %s", status, supportTrim(resp)),
				fmt.Sprintf("token %s NOT revoked; the control-plane row still holds its id", id), exitGeneric)
		}
	}
	return exitOK, false
}

// stepServer deletes the (single, identity-verified) box.
func (r *supportRemoveRun) stepServer() (int, bool) {
	for _, box := range r.boxes {
		r.state("server", fmt.Sprintf("deleting box %s at %s", box.Name, box.IP))
		if err := r.provider.Delete(supportCtx(), box.Name); err != nil {
			return r.fail("server", "delete failed: "+err.Error(),
				fmt.Sprintf("box %s still exists (it is billing); token already revoked", box.Name), exitGeneric)
		}
		r.done("server", box.Name+" deleted")
	}
	return exitOK, false
}

// dnsTarget derives the sweep inputs: the ZONE from the CP row's url (hostOf
// returns the FULL host, e.g. "hex.barkpark.cloud" — the zone is everything
// after its first label, so no import of internal/provisioner's Zone constant
// is needed) and the VALUE to sweep by from the located box's IP (the same IP
// census leg 1 re-reads). A non-empty skip names the honest reason the leg
// cannot run — an absence is said, never silently passed (PDS-D287).
func (r *supportRemoveRun) dnsTarget() (zone, ip, skip string) {
	if len(r.rows) == 0 {
		return "", "", "no control-plane row — no url to derive the DNS zone from"
	}
	var host string
	for _, row := range r.rows {
		if u := strings.TrimSpace(row.URL); u != "" {
			host = hostOf(u)
			break
		}
	}
	if host == "" {
		return "", "", "the control-plane row carries no url — cannot derive the DNS zone"
	}
	if net.ParseIP(strings.Trim(host, "[]")) != nil {
		return "", "", fmt.Sprintf("the control-plane row's url points at raw IP %s — no DNS zone to sweep", host)
	}
	parts := strings.Split(host, ".")
	if len(parts) < 3 {
		return "", "", fmt.Sprintf("url host %q carries no subdomain label — cannot derive the zone", host)
	}
	if len(r.boxes) == 0 {
		return "", "", "no box was located — no box IP to sweep A-record values by"
	}
	if strings.TrimSpace(r.boxes[0].IP) == "" {
		return "", "", fmt.Sprintf("box %s has no IP on record — no value to sweep A records by", r.boxes[0].Name)
	}
	return strings.Join(parts[1:], "."), r.boxes[0].IP, ""
}

// stepDNS sweeps the support's leaked A records — by VALUE (PDF-D101): the CP
// support chain writes <name>.<zone> (TTL 60) while the main go-live path
// writes <slug>-<team>.<zone> at the SAME IP, so a by-name delete removes one
// and leaves the sibling standing while a by-name census still reads clean.
// Every A rrset in the zone resolving to the box IP is deleted. WARN-AND-
// CONTINUE, never a stop — the census's fifth leg is the truth. No CP row, no
// URL, or no box IP → the leg is SKIPPED and says so; the census repeats the
// skip and never reports the zone clean.
func (r *supportRemoveRun) stepDNS() (int, bool) {
	zone, ip, skip := r.dnsTarget()
	if skip != "" {
		r.dnsSkip = skip
		r.state("dns", fmt.Sprintf("SKIPPED — %s (the zone is NOT verified clean)", skip))
		return exitOK, false
	}
	r.dnsZone, r.dnsIP = zone, ip
	if r.dnsTokenSrc == "compute" {
		r.out.errf("⚠ dns: no dedicated DNS credential (--dns-token / BARKPARK_DNS_HCLOUD_TOKEN) — riding the compute token; the fleet project's token sees ZERO zones, so the sweep may find nothing while records survive — the census below is the truth")
	}
	r.dns = supportDNSFor(r.dnsToken)
	r.state("dns", fmt.Sprintf("sweeping A records in %s that resolve to %s — by VALUE, not name (a by-name delete leaves the go-live sibling standing)", zone, ip))
	deleted, err := cloud.SweepARecordsByValue(supportCtx(), r.dns, zone, ip)
	if err != nil {
		got := ""
		if len(deleted) > 0 {
			got = fmt.Sprintf(" (%s deleted before the failure)", strings.Join(deleted, ", "))
		}
		r.out.errf("⚠ dns: sweep failed: %s%s — continuing; the census below is the truth", err, got)
		return exitOK, false
	}
	// The sweep RAN and came back without error — the only evidence that earns
	// `?mode=detach` on the control-plane row below. A skipped or failed sweep
	// deliberately leaves this false so the CP tears the record down instead.
	r.dnsSwept = true
	r.done("dns", supportDNSNarration(zone, ip, deleted))
	return exitOK, false
}

// stepRoster deletes the listener row via the PDF-D44d dataset-in-path mutate
// (the query-param form 404s). A non-2xx is a WARNING, not a stop — delete
// responses prove nothing either way (D33); the census re-read is the truth.
func (r *supportRemoveRun) stepRoster() (int, bool) {
	r.state("roster", fmt.Sprintf("deleting roster row listener-%s on %s (dataset %s)", r.name, r.base, r.dataset))
	body := map[string]any{"mutations": []any{
		map[string]any{"delete": map[string]any{"id": "listener-" + r.name, "type": "listener"}},
	}}
	status, resp, err := supportMainJSON(http.MethodPost, r.base+"/v1/data/mutate/"+url.PathEscape(r.dataset), r.token, body)
	if err != nil {
		return r.fail("roster", "cannot reach the main: "+err.Error(),
			fmt.Sprintf("roster row listener-%s may still be present", r.name), exitGeneric)
	}
	if status < 200 || status >= 300 {
		r.out.errf("⚠ roster: the main answered %d: %s — continuing; the census below is the truth", status, supportTrim(resp))
		return exitOK, false
	}
	r.done("roster", fmt.Sprintf("listener-%s delete submitted (the census re-reads it)", r.name))
	return exitOK, false
}

// stepCPRow deletes the control-plane row(s) LAST (PDF-D68): only after the
// token, box, and roster row are gone may the sole durable token-id holder go —
// a crash before this point leaves a re-run everything it needs to converge.
//
// task-688ebffc4b0aa50a — WHICH removal this asks the control plane for depends
// on whether THIS run can prove the A record is already gone. The CP route now
// refuses to drop a live support's row on its own, because that row is the only
// thing left naming the record to delete; it enqueues a deprovision job instead
// and lets the worker sweep. That is the right default and a wrong fit HERE on
// the runs where stepDNS already swept the zone by value: the record is gone, so
// `?mode=detach` says so and the row goes now (the census still re-reads both).
// When the sweep was SKIPPED or FAILED the mode is omitted ON PURPOSE — the CLI
// has no proof, so the control plane keeps the pointer and the worker (which
// holds a DNS credential the local compute token may not have) finishes the job.
func (r *supportRemoveRun) stepCPRow() (int, bool) {
	for _, row := range r.rows {
		mode := ""
		why := "the control plane decides (this run did not prove the A record is gone)"
		if r.dnsSwept {
			mode, why = "?mode=detach", "detach — this run swept the zone by value, so the row names nothing that is still live"
		}
		r.state("cp-row", fmt.Sprintf("deleting control-plane row %s — LAST (sole durable holder of the token id); %s", row.ID, why))
		status, resp, err := supportMainJSON(http.MethodDelete, r.cpBase+"/v1/fleet/supports/"+url.PathEscape(row.ID)+mode, r.cpToken, nil)
		if err != nil {
			return r.fail("cp-row", "cannot reach the control plane: "+err.Error(),
				fmt.Sprintf("control-plane row %s still registered (token already revoked, box gone)", row.ID), exitGeneric)
		}
		switch {
		case status == http.StatusAccepted:
			// The CP took the teardown over: the row SURVIVES until its worker
			// reports the box + DNS gone. Not a failure and not a removal —
			// record it so the census names it for what it is.
			if r.cpHandedOff == nil {
				r.cpHandedOff = map[string]string{}
			}
			r.cpHandedOff[row.ID] = "deprovisioning"
			r.out.errf("⚠ cp-row: the control plane answered 202 — it kept row %s and enqueued a deprovision job so ITS worker tears the box and the A record down (this run could not prove the record was gone). The row is expected to survive the census below; re-run once the job drains", row.ID)
		case status >= 200 && status < 300:
			r.done("cp-row", row.ID+" removed")
		case status == http.StatusNotFound:
			r.done("cp-row", row.ID+" already gone (404)")
		case status == http.StatusUnauthorized:
			// A re-run cannot converge on a dead session — name the fix (the
			// same credential contract add narrates, PDF-D69/D71).
			r.out.errf("⚠ cp-row: the control plane answered 401: %s — the Cloud session is missing or dead; run `bp login`, then re-run. Continuing; the census below is the truth", supportTrim(resp))
		case status == http.StatusForbidden:
			r.out.errf("⚠ cp-row: the control plane answered 403: %s — a session needs team-admin, a PAT needs the deploy ability; fix the credential, then re-run. Continuing; the census below is the truth", supportTrim(resp))
		default:
			r.out.errf("⚠ cp-row: the control plane answered %d: %s — continuing; the census below is the truth", status, supportTrim(resp))
		}
	}
	return exitOK, false
}

// census — the deliverable (PDF-D68, five surfaces since PDF-D101): RE-READ
// every surface; delete-call 200s prove nothing (D33: bp doc delete can exit 4
// on success — verify by re-read, never by exit code). Any survivor is named
// and the exit is non-zero.
func (r *supportRemoveRun) census() int {
	r.state("census", "re-reading all five surfaces (delete responses prove nothing)")
	var residue []string

	// 1. SERVER — the label listing must come back empty.
	if boxes, err := r.lister.ListByLabel(supportCtx(), cloud.FleetSupportLabelKey, r.name); err != nil {
		residue = append(residue, "could not verify servers: "+err.Error())
	} else {
		for _, box := range boxes {
			residue = append(residue, fmt.Sprintf("server %s (ip %s) still carries %s=%s", box.Name, box.IP, cloud.FleetSupportLabelKey, r.name))
		}
	}

	// 2. ROSTER — the same read stepOnline polls must now return no row.
	if row, err := supportRosterRow(r.base, r.token, r.dataset, r.name); err != nil {
		residue = append(residue, "could not verify the roster: "+err.Error())
	} else if row != nil {
		residue = append(residue, fmt.Sprintf("roster row listener-%s still present on the main (dataset %s)", r.name, r.dataset))
	}

	// 3. CONTROL PLANE — re-list; the support row must be gone.
	if rows, status, err := supportCPBarkparks(r.cpBase, r.cpToken); err != nil {
		residue = append(residue, "could not verify the control plane: "+err.Error())
	} else if status < 200 || status >= 300 {
		residue = append(residue, fmt.Sprintf("could not verify the control plane: it answered %d", status))
	} else {
		for _, row := range rows {
			if row.FleetRole == "support" && row.Name == r.name {
				if st, ok := r.cpHandedOff[row.ID]; ok {
					residue = append(residue, fmt.Sprintf("control-plane row %s still registered — %s: the control plane kept it on purpose and its worker is tearing the box + A record down; re-run once that job drains", row.ID, st))
					continue
				}
				residue = append(residue, fmt.Sprintf("control-plane row %s still registered", row.ID))
			}
		}
	}

	// 4. TOKEN — the REAL leg when the raw secret is at hand: the admin-gated
	// mint endpoint read 403 to the support's own bearer while valid and MUST
	// read 401 after revoke. Without the secret (box already gone), the leg is
	// the revoke receipt, said plainly.
	tokenIDs := supportTokenIDs(r.rows)
	switch {
	case r.probeSecret != "":
		st, err := supportTokenProbe(r.base, r.probeSecret)
		switch {
		case err != nil:
			residue = append(residue, "could not verify the token: "+err.Error())
		case st == http.StatusUnauthorized:
			before := ""
			if r.probeBefore != 0 {
				before = fmt.Sprintf("%d before, ", r.probeBefore)
			}
			r.out.progressf("  · token: DEAD — the admin-gated mint endpoint read %s401 after revoke", before)
		case st == http.StatusForbidden:
			residue = append(residue, "support token STILL VALID — the admin-gated mint endpoint answered 403 (authenticated), not 401, to the support's own bearer")
		default:
			residue = append(residue, fmt.Sprintf("token probe answered an unexpected %d — cannot confirm the token is dead", st))
		}
	case len(tokenIDs) > 0:
		for _, id := range tokenIDs {
			if receipt, ok := r.revoked[id]; ok {
				r.out.progressf("  · token %s: %s — indirect leg (raw secret not at hand for the 403→401 probe; it is never stored)", id, receipt)
			} else {
				residue = append(residue, fmt.Sprintf("token %s has no revoke receipt", id))
			}
		}
	default:
		r.out.progressf("  · token: no token id was on record")
	}

	// 5. DNS — BY VALUE (PDF-D101): zero A rrsets in the zone may still resolve
	// to the box IP. A by-name check would read clean while the go-live sibling
	// (<slug>-<team>) survives — the VALUE is the truth. A skipped leg says so
	// and is never reported clean.
	dnsNote := "dns verified by value"
	switch {
	case r.dnsSkip != "":
		dnsNote = "dns SKIPPED — " + r.dnsSkip
		r.out.progressf("  · dns: SKIPPED — %s (the zone is NOT verified clean)", r.dnsSkip)
	case r.dns == nil:
		dnsNote = "dns SKIPPED — the dns step did not run"
		r.out.progressf("  · dns: SKIPPED — the dns step did not run (the zone is NOT verified clean)")
	default:
		if names, err := cloud.ARecordNamesByValue(supportCtx(), r.dns, r.dnsZone, r.dnsIP); err != nil {
			residue = append(residue, "could not verify dns: "+err.Error())
		} else {
			for _, n := range names {
				residue = append(residue, fmt.Sprintf("A record %s still resolves to box IP %s", cloud.Fqdn(n, r.dnsZone), r.dnsIP))
			}
		}
	}

	report := map[string]any{
		"ok":      len(residue) == 0,
		"support": r.name,
		"dataset": r.dataset,
		"residue": residue,
		"dns":     dnsNote,
	}
	if r.out.emitStructured(report) {
		if len(residue) > 0 {
			return exitGeneric
		}
		return exitOK
	}
	if len(residue) > 0 {
		r.out.userErr("✗ remove %s left residue:", r.name)
		for _, line := range residue {
			r.out.errf("  - %s", line)
		}
		r.out.errf("  next: re-run `bp cloud support remove %s` — the teardown is idempotent and converges", r.name)
		return exitGeneric
	}
	r.out.outf("")
	r.out.outf("✓ remove %s — census delta zero (server, roster, control plane, token clean; %s)", r.name, dnsNote)
	return exitOK
}

// ── control-plane helpers ────────────────────────────────────────────────────

// supportCPRow is the slice of a control-plane /v1/barkparks row this file
// needs: identity + the three fleet columns the Wave C group record carries.
type supportCPRow struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	URL           string `json:"url"`
	Host          string `json:"host"`
	FleetRole     string `json:"fleet_role"`
	FleetParentID string `json:"fleet_parent_id"`
	FleetTokenID  string `json:"fleet_token_id"`
}

// supportCPBarkparks lists the caller's fleet from the control plane. Non-2xx
// is returned as a status, not an error — callers own the honest narration.
func supportCPBarkparks(cpBase, cpToken string) ([]supportCPRow, int, error) {
	status, body, err := supportMainJSON(http.MethodGet, cpBase+"/v1/barkparks", cpToken, nil)
	if err != nil {
		return nil, 0, err
	}
	if status < 200 || status >= 300 {
		return nil, status, nil
	}
	var env struct {
		Barkparks []supportCPRow `json:"barkparks"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return nil, status, fmt.Errorf("barkparks payload not parseable: %w", jerr)
	}
	return env.Barkparks, status, nil
}

// supportCPRowLabel renders one row for candidate listings: name (id, url).
func supportCPRowLabel(row supportCPRow) string {
	return fmt.Sprintf("%s (id %s, url %s)", supportOr(row.Name, "?"), row.ID, supportOr(row.URL, "none"))
}

// supportCPErrorCode reads the flat {"error": "<code>"} shape the CP speaks.
func supportCPErrorCode(body []byte) string {
	var m struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &m); err != nil {
		return ""
	}
	return m.Error
}

// supportCPRefusalReason reads the CAUSE an authority gate names alongside the
// generic code — {"error":"forbidden","reason":"no_team","scope":"team"}. Decoded
// SEPARATELY from the code (the cloudclient idiom) so a route sending a non-string
// reason costs only the reason, never the code the branch above keys on.
func supportCPRefusalReason(body []byte) string {
	var m struct {
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(body, &m); err != nil {
		return ""
	}
	return strings.TrimSpace(m.Reason)
}

// supportCPNoTeam reports whether the control plane refused because the caller's
// login has NO ACTIVE TEAM, in either shape the team gate emits: the 422 whose
// code IS the cause, and the 403 whose code is the generic "forbidden" and whose
// `reason` names it. One predicate, so the two shapes cannot drift into two
// different narrations.
func supportCPNoTeam(status int, body []byte) bool {
	switch status {
	case http.StatusUnprocessableEntity:
		return supportCPErrorCode(body) == "no_team"
	case http.StatusForbidden:
		// Either shape at the new status: the cause in `reason` beside the generic
		// code, or the cause AS the code. Reading only the first would drop a flat
		// 403 {"error":"no_team"} into the role arm — the exact mis-narration this
		// predicate exists to prevent, one status later.
		return supportCPRefusalReason(body) == "no_team" || supportCPErrorCode(body) == "no_team"
	default:
		return false
	}
}

// supportParseCPRowID reads the created row id out of the CP's 201 {barkpark}.
func supportParseCPRowID(body []byte) string {
	var m struct {
		Barkpark struct {
			ID string `json:"id"`
		} `json:"barkpark"`
	}
	if err := json.Unmarshal(body, &m); err != nil {
		return ""
	}
	return m.Barkpark.ID
}

// supportTokenIDs collects the distinct token ids the CP rows carry.
func supportTokenIDs(rows []supportCPRow) []string {
	var ids []string
	seen := map[string]bool{}
	for _, row := range rows {
		id := strings.TrimSpace(row.FleetTokenID)
		if id != "" && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	return ids
}

// supportTokenProbe asks the MAIN's admin-gated mint endpoint who the bearer
// is: 403 = authenticated-but-not-admin (the support token is ALIVE), 401 =
// rejected (revoked/unknown — DEAD). The body is a deliberately-invalid mint
// ({"name":""} 422s) so the probe can NEVER create anything even against an
// admin bearer.
func supportTokenProbe(base, secret string) (int, error) {
	status, _, err := supportMainJSON(http.MethodPost, base+"/v1/fleet/support-tokens", secret, map[string]any{"name": ""})
	return status, err
}

// supportLastLine returns the last non-empty trimmed line of s.
func supportLastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if line := strings.TrimSpace(lines[i]); line != "" {
			return line
		}
	}
	return ""
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

// supportEnsureWorkspaceStep creates the import's target workspace on the box
// when it does not exist yet (task-2ba0270056e7da6e, mirrored from the worker
// chain in internal/provisioner/support.go). A TEMPLATE-launched main's
// bootstrap workspace slug exists on NO fresh box (only "default" is seeded),
// and importing such a bundle live-failed box-side; pre-creating an empty
// same-slug shell routes the merge-import through the live-proven PDS-D9
// adopt branch (empty shell → delete → import). 409/422 (already exists) is
// tolerated so a re-run converges. For ws=="default" this is a guaranteed 409
// no-op — but only because stepDataset runs the reset bracket FIRST: the warm
// image's baked Postgres carries seed docs, so the box's pre-existing
// "default" was never the empty shell the old "byte-neutral" claim assumed
// (three live 409s, 2026-07-26); the reset deletes it and the re-mint's
// ensure_default_scope recreates it provably empty. ws is fenced by
// supportSlugRe before any step builds.
func supportEnsureWorkspaceStep(ws, adminToken string) cloud.CaddyStep {
	script := `set -e; export BP_TOK='` + adminToken + `'
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://localhost:4000/api/workspaces \
  -H "Authorization: Bearer $BP_TOK" -H 'Content-Type: application/json' \
  --data '{"name":"` + ws + `","slug":"` + ws + `"}')
case "$code" in
  2*|409|422) exit 0 ;;
  *) echo "workspace ensure: POST /api/workspaces answered HTTP $code" >&2; exit 1 ;;
esac`
	return cloud.CaddyStep{
		Title:  "ensure the target workspace '" + ws + "' exists on the box (POST /api/workspaces — already-exists is fine)",
		Cmd:    "curl -X POST http://localhost:4000/api/workspaces {name/slug: " + ws + "} (token redacted)",
		Argv:   []string{"bash", "-lc", script},
		Redact: []string{adminToken},
	}
}

// supportImportStep merge-imports the staged bundle into the box's OWN
// localhost API with the box's minted admin token (BP_TOK env — Argv only,
// redacted; never in the narrated Title/Cmd). Delegates to the ONE shared
// builder (cloud.SupportMergeImportStep) so this chain and the worker chain
// cannot drift, and so the on-box failure carries its evidence (bp's error
// body + the box's barkpark journal tail — task-63a199c0a0ce2a06 fired blind
// without them).
func supportImportStep(ws, adminToken string) cloud.CaddyStep {
	return cloud.SupportMergeImportStep(ws, adminToken)
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
  bp cloud support add <name>    [--agent claude|codex] [--workspace <slug>]
                                 [--dataset <slug>] [--parent <cp-row-id>]
                                 [--dry-run] [-o json|yaml]
  bp cloud support remove <name> [--dataset <slug>] [--dry-run] [-o json|yaml]

WHAT IT DOES (eight named states, in order)
  create      provision an x86 warm-image box on hetzner, labeled
              barkpark-fleet-support=<name>. A placement failure writes NOTHING.
  wait-ready  poll sshd on the new box.
  roster-row  publish listener-<name> {status:provisioning, ttl_s:1800} on the
              MAIN's ledger (only now that a box exists — the row never lies).
  configure   the reduced go-live chain on the box: freshen → per-instance
              secrets → migrate → admin token → LOCAL health probe. No DNS, no
              TLS, no public identity — a support serves the main, not the web.
  bind        mint a support token on the MAIN (/v1/fleet/support-tokens) and
              register the fleet group record on the CONTROL PLANE
              (/v1/fleet/supports, via your bp-login Cloud session — PDF-D69).
              Without --parent, the main's control-plane row is auto-resolved
              by matching its URL host (never the raw-IP host column).
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
                         record (default: auto-resolved by url-host match;
                         zero or many matches refuse with candidates)
  --dry-run              print the named states and do nothing
  -o json|yaml           one machine-readable receipt on stdout

REMOVE (the mirror verb — PDF-D68, five surfaces since PDF-D101)
  Tears one support down across all FIVE surfaces, in a crash-safe order:
  read the control-plane record first (it alone holds the token id), revoke
  the token on the main, delete the box (identity-fenced by its
  barkpark-fleet-support label — a foreign identity is refused loudly),
  sweep every A record in the zone that resolves to the box IP (by VALUE,
  not name — the go-live sibling record leaks too; credential:
  --dns-token > BARKPARK_DNS_HCLOUD_TOKEN > compute), delete the roster
  row, and delete the control-plane row LAST. Then a census RE-READS every
  surface — delete responses prove nothing — and any survivor is named
  with a non-zero exit. Idempotent: run it again and it reports
  already-gone; partial state converges.

RELATED
  bp fleet roster        the fleet's presence table (who is online, with what)`
	out.outf("%s", help)
}
