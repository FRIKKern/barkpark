package cli

// cloud_site_cmd.go is `bp cloud site …` — the verb family that spawns a website
// which builds and serves RIGHT NEXT TO Phoenix, reading a Barkpark dataset over
// the internal link and riding the co-located instance's own Caddy + blue/green +
// webhook machinery (cloud-site-spawner charter D10). Astro is the flagship
// (spawnable first); Next.js, TanStack Start, Hugo and others ride the same engine
// on the roadmap.
//
//	bp cloud site create   --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro] [--kind static|node]
//	bp cloud site deploy    <site> [--no-follow] [--wait-for-live <deadline>]   (alias: build)
//	bp cloud site rollback  <site>
//	bp cloud site delete    <site> [--yes]         (alias: rm)
//	bp cloud site status    <site>
//	bp cloud site open      <site> [--print-only]
//
// It is a THIN driver over internal/cloudclient's spawner methods, rendered
// through the shared writer table/JSON helpers — the cloud_deploy_cmd.go idiom.
//
// Deliberately DISTINCT from two neighbours, and the copy says so, so the three
// never blur:
//   - `bp cloud deploy` / `bp cloud rollback` operate on an INSTANCE (the
//     blue/green CODE-slot flip of a whole Barkpark box);
//   - the top-level `bp sites` / `bp deploy` operate on the CONTAINER model (a
//     long-running app image);
//   - `bp cloud site …` operates on a SPAWNED site — its deploy walks the six
//     visible stages PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE, health-gated
//     so a broken build never reaches visitors. One state machine drives TWO
//     runtime targets (charter D62): a static site (Astro) whose rollback is a
//     sub-second symlink flip, and a node site (`--kind node`, Next.js first) that
//     runs a long-running SSR process on a per-slot port and whose SWITCH/rollback
//     is a Caddy reverse_proxy upstream flip to the warm previous node slot.
//
// Like every control-plane verb it NEVER writes bp config: it resolves the site
// by name/id via the fleet list and the Cloud session token, exactly like
// `bp cloud rollback` / `bp cloud verify`.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// siteDeployPoll is the interval `deploy` re-reads the deployment at while
// streaming the six stages. A package var so the unit tests poll instantly.
var siteDeployPoll = 2 * time.Second

// siteDeployPollMax bounds the stream loop (~10 min at 2s) so a wedged build can
// never spin forever — the loop then prints an honest "still in progress, watch
// with status" verdict rather than hanging.
const siteDeployPollMax = 300

// runCloudSite routes `bp cloud site <verb> …` to its verb. `build` is an alias
// of `deploy` (both enqueue a build); `sites` is accepted as a plural alias at
// the dispatcher above.
func runCloudSite(out *writer, g globals, args []string) int {
	// `preflight` owns its OWN -h/--help (a dedicated page that disambiguates it
	// from the box-side --rollback-preflight), so route it before the family-level
	// help catch below would swallow `preflight -h` into the family usage.
	isPreflight := len(args) > 0 && args[0] == "preflight"
	if !isPreflight {
		for _, a := range args {
			if a == "-h" || a == "--help" {
				printCloudSiteHelp(out)
				return exitOK
			}
		}
		if g.help || (len(args) > 0 && args[0] == "help") {
			printCloudSiteHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing site command (run `bp cloud site -h` for usage)", exitUsage)
	}
	verb := args[0]
	rest := args[1:]
	switch verb {
	// THE TWO-NOUN RULING (dr-w14-bl-owner-cannot-list-own-sites): `bp sites`
	// and `bp cloud site` are BOTH real and deliberately split — `bp sites` is
	// the team-wide site surface (list/show/create/deployments/env/domains),
	// `bp cloud site` is the spawner's lifecycle verbs on ONE site
	// (create/deploy/rollback/delete/status/open/preflight/settings). The
	// overlap is resolved by ALIASING, not by exclusivity: enumeration lives in
	// runSitesList and `bp cloud site ls` routes THERE, so an owner standing at
	// either noun can enumerate their own sites — the wave-14 verifier found
	// their 13 sites only by curling /v1/sites because THIS noun refused `ls`
	// while the other noun answered it.
	case "ls", "list":
		return runSitesList(out, rest)
	case "create":
		return runCloudSiteCreate(out, g, rest)
	case "deploy", "build":
		return runCloudSiteDeploy(out, g, rest)
	case "rollback":
		return runCloudSiteRollback(out, g, rest)
	case "delete", "rm":
		return runCloudSiteDelete(out, g, rest)
	case "status":
		return runCloudSiteStatus(out, g, rest)
	case "open":
		return runCloudSiteOpen(out, g, rest)
	case "preflight":
		return runCloudSitePreflight(out, g, rest)
	case "settings":
		return runCloudSiteSettings(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown site command %q (run `bp cloud site -h` for usage; to list your team's sites: `bp sites` or `bp cloud site ls`)", verb), exitUsage)
	}
}

// siteCloudConfig loads the config and gates on a Cloud session — the shared
// preamble every spawner verb runs. A logged-out user gets one plain auth error
// with a `bp login` hint and makes no network call.
func siteCloudConfig(out *writer, action string) (*Config, bool) {
	cfg, cerr := LoadConfig()
	if cerr != nil {
		useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
		return nil, false
	}
	if !cfg.HasCloudToken() {
		useError(out, "auth", "not logged in — run `bp login` to "+action, exitAuth)
		return nil, false
	}
	return cfg, true
}

// parseDatasetTriple splits a `ws/proj/ds` selector into its three parts, with a
// clear usage error for anything that is not exactly three non-empty segments.
func parseDatasetTriple(s string) (ws, proj, ds string, err error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", "", "", fmt.Errorf("--dataset is required (want ws/proj/ds)")
	}
	parts := strings.Split(s, "/")
	if len(parts) != 3 {
		return "", "", "", fmt.Errorf("--dataset wants three slash-separated parts ws/proj/ds, got %q", s)
	}
	ws, proj, ds = strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]), strings.TrimSpace(parts[2])
	if ws == "" || proj == "" || ds == "" {
		return "", "", "", fmt.Errorf("--dataset ws/proj/ds must have no empty part, got %q", s)
	}
	return ws, proj, ds, nil
}

// siteInstanceRequired is the actionable error for a `create` with no --instance.
// A site is spawned ON a specific Barkpark box (sites.barkpark_id is NOT NULL, and
// nothing in the control plane infers one from the workspace), so the flag is
// mandatory — the CLI says so HERE rather than letting the server answer with a
// 422 that names the wrong field.
const siteInstanceRequired = "--instance is required: a site is spawned on a specific Barkpark instance, " +
	"and the control plane does not infer one from the workspace. " +
	"List your fleet with `bp cloud status` (the same id/name list --instance resolves against; " +
	"`bp cloud instances list` shows the provider-side view), then re-run with --instance <id-or-name>."

// runCloudSiteCreate is `bp cloud site create` — POST /v1/sites with the spawner
// body (kind + dataset triple + name + framework + the instance it lives on).
// Astro/static are the defaults; --instance has no default because there is no
// honest one.
func runCloudSiteCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud site create --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro] [--kind static|node] [--doc-type <type>] [--template astro-starter|next-starter|search-starter|astro-search-starter] [--deploy]"
	a, err := parseHzArgs(args, []string{"name", "dataset", "framework", "kind", "instance", "doc-type", "template", "theme"}, []string{"deploy"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := strings.TrimSpace(a.val("name"))
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	// --dataset COLLIDES with the global -d/--dataset: parseGlobals consumes it
	// wherever it appears in argv (by design for every other noun), so the value
	// never reaches this verb's own flag set — it lands in g.dataset instead.
	// Honor both spellings: the local flag when a future parser change delivers
	// it, else the global capture. (Live-caught: the verb was unusable end-to-end
	// while its direct-call unit tests stayed green.)
	rawTriple := a.val("dataset")
	if rawTriple == "" {
		rawTriple = g.dataset
	}
	ws, proj, ds, derr := parseDatasetTriple(rawTriple)
	if derr != nil {
		return useError(out, "usage", derr.Error(), exitUsage)
	}
	// --instance is MANDATORY and is checked before any network call: the server
	// rejects a missing barkpark_id, and it does so through a shared branch that
	// reports `name_required` — a misleading answer we refuse to make the user read.
	inst := strings.TrimSpace(a.val("instance"))
	if inst == "" {
		return useError(out, "usage", siteInstanceRequired, exitUsage)
	}
	framework := strings.TrimSpace(a.val("framework"))
	if framework == "" {
		framework = "astro"
	}
	// --kind FOLLOWS --framework when omitted. The dashboard's create form
	// derives it (cloud/priv/static/app.js siteKindFor) and the CLI used to
	// hard-default to "static", so `--framework nextjs` alone built a kind=static
	// request the server rejected with a bare enum — a mistake the console cannot
	// even express. An explicit --kind still wins: the flag is not advisory.
	kind := strings.TrimSpace(a.val("kind"))
	if kind == "" {
		kind = siteKindForFramework(framework)
	}

	cfg, ok := siteCloudConfig(out, "spawn a site")
	if !ok {
		return exitAuth
	}
	// Resolve the instance id-or-name to its barkpark id — the box the site is
	// spawned on and builds next to.
	barkparkID, rerr := resolveOpenBarkparkID(cfg, inst)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	req := cloudclient.SpawnSiteCreate{
		Name:       name,
		Framework:  framework,
		Kind:       kind,
		Workspace:  ws,
		Project:    proj,
		Dataset:    ds,
		BarkparkID: barkparkID,
		// --doc-type binds the content type the build's flagship fetch reads. Left
		// empty the control plane defaults it to "post"; the flag is here because
		// guerrilla's content is `paper`, and passing it via an env prefix is inert
		// (the allowlist drops it) — it has to reach the box through create (D35).
		DocType: strings.TrimSpace(a.val("doc-type")),
		// --template selects the shipped starter tree explicitly (search-template
		// W2, D8) — e.g. the flagship search-starter on a node site. Empty keeps
		// the framework-derived default.
		Template: strings.TrimSpace(a.val("template")),
		// --theme pins the palette for this site's deploys (W6) — empty keeps
		// the template default.
		Theme: strings.TrimSpace(a.val("theme")),
	}

	created, cerr := cfg.CloudClient().CreateSpawnSite(cloudCtx(), req)
	if cerr != nil {
		// The create refusal rides the SAME #11784 ladder as delete/rollback — one
		// dialect, never a second. POST /v1/sites emits no top-level 403 and no 409,
		// so the exit families that land here are: 401 → cloudFail fallthrough (the
		// shared `bp login` sentence, byte-identical "create site" label), no_team →
		// 1 with the `bp team use` fix, barkpark_not_found 404 → 4, every 422 → 1,
		// node_ports_exhausted 503 / read_token_mint_failed 502 → 8 relaying detail.
		return siteRefusalFail(out, siteRefusedCreate, name, cerr)
	}

	// --deploy (D19) turns create into the one-motion: on a successful create the CLI
	// chains CLIENT-SIDE straight into the deploy stream and ends on the live URL — no
	// second command, no copy-pasting the ref. Without it, behavior is byte-identical:
	// the create envelope is the whole machine-mode result and the human view prints
	// the `deploy it with …` hint.
	wantDeploy := a.bools["deploy"]

	// The row and the VERDICT are two different facts and the receipt needs both:
	// the row says which type was stored, the verdict says whether the control
	// plane could read it through this site's own token at create time.
	site, binding := created.Site, created.ContentBinding

	if !wantDeploy && out.emitStructured(siteCreatedEnvelope(site, binding)) {
		return exitOK
	}
	ref := spawnSiteRef(site)
	// The create summary. In the one-motion it rides progressf so a machine-mode
	// caller still gets a single deployment envelope on stdout (the deploy stream
	// owns it); a plain create keeps its outf lines byte-identical.
	emit := out.outf
	if wantDeploy {
		emit = out.progressf
	}
	renderSiteCreated(emit, site, binding, req, wantDeploy)
	if wantDeploy {
		return chainSiteDeploy(out, cfg, ref, site)
	}
	return exitOK
}

// renderSiteCreated writes the `create` receipt from the site row the CONTROL
// PLANE returned — the persisted record, never the request. It is a pure render
// (no network, no config) so the success-claim registry can probe it with a
// backing and a contradicting response; `emit` is out.outf on a plain create and
// out.progressf inside the create --deploy one-motion.
//
// The request is still passed, for exactly one job: telling APART "the server
// echoed what you asked for" from "the server said nothing about it". Where the
// two diverge the line says which one it is printing, because a create that
// echoes your own flag back at you is not evidence the control plane bound it.
//
// `binding` is the control plane's CREATE-TIME READ of the bound type (charter
// D73) — a different fact from the row, and the one an operator actually needs.
// It arrives on a top-level `content_binding` key beside `site`, so it is a
// separate parameter rather than a field of the row.
func renderSiteCreated(emit func(string, ...any), site cloudclient.SpawnSite, binding cloudclient.ContentBinding, req cloudclient.SpawnSiteCreate, wantDeploy bool) {
	ref := spawnSiteRef(site)
	emit("✓ site %s created — %s build, kind %s",
		hzCell(siteOr(site.Name, req.Name)),
		hzCell(siteOr(site.Framework, req.Framework)),
		hzCell(siteOr(site.Kind, req.Kind)))
	emit("  dataset: %s", siteDatasetClaim(site, req))
	renderSiteContentClaim(emit, site, binding, req)
	if t := siteOr(site.Template, req.Template); strings.TrimSpace(t) != "" {
		emit("  starter: %s", hzCell(t))
	}
	if t := siteOr(site.Theme, req.Theme); strings.TrimSpace(t) != "" {
		emit("  theme:   %s", hzCell(t))
	}
	// A plain create can only promise the URL goes live after the first deploy; the
	// one-motion is ABOUT to deploy, so it skips the caveat and lets the deploy stream
	// print the real live URL when it lands.
	if u := spawnSiteURL(site); u != "" && !wantDeploy {
		emit("  url:     %s (live after the first deploy)", u)
	}
	// Runtime-target note: a node site runs a long-running SSR process on its own
	// slot port (health-gated, Caddy-fronted); the flagship container framework is
	// Next.js, the rest ride the same node-slot engine on the roadmap. A static site
	// keeps the Astro-is-flagship note. Both are measured — neither over-promises a
	// build that may not land yet.
	effFramework := siteOr(site.Framework, req.Framework)
	switch {
	case siteIsNode(siteOr(site.Kind, req.Kind), site.RuntimeTarget):
		emit("  runtime: %s — a long-running node SSR process on its own slot port, health-gated behind Caddy", hzCell(siteOr(site.RuntimeTarget, cloudclient.RuntimeTargetNode)))
		if effFramework != "nextjs" {
			emit("  note:    nextjs is the flagship container framework; %q rides the same node-slot engine on the roadmap and may not build yet", effFramework)
		}
	case effFramework != "astro":
		emit("  note:    astro is the flagship static framework; %q rides the same engine on the roadmap and may not build yet", effFramework)
	}
	if !wantDeploy {
		emit("  deploy it with `bp cloud site deploy %s`", ref)
	}
}

// siteDatasetClaim is the create receipt's dataset line. siteDatasetLabel prefers
// the server's values and silently falls back to what the user typed, which makes
// a control plane that echoed NOTHING look like one that confirmed the binding.
// Here the fallback is labelled: a fully-echoed triple prints bare, a partially or
// wholly un-echoed one says it is the request.
func siteDatasetClaim(s cloudclient.SpawnSite, req cloudclient.SpawnSiteCreate) string {
	label := siteDatasetLabel(s, req.Workspace, req.Project, req.Dataset)
	if strings.TrimSpace(s.Workspace) != "" && strings.TrimSpace(s.Project) != "" && strings.TrimSpace(s.Dataset) != "" {
		return label
	}
	return label + " (as requested — the control plane did not echo the binding back)"
}

// chainSiteDeploy is the create --deploy one-motion tail: it enqueues the first
// build for the just-created site and hands off to streamSiteDeploy, which narrates
// the six visible stages and ends on the live URL. The site's own id drives the
// deploy — no fleet-list resolve, the create response already carries it.
//
// instance-not-live is handled honestly: a box that is still provisioning answers
// the deploy with a 422 instance_not_live, and the site IS created — so the CLI says
// exactly that and points at `bp cloud site deploy <ref>` to retry, never a crash or
// a bare error slug. Every other deploy error rides the shared cloudFail contract.
func chainSiteDeploy(out *writer, cfg *Config, ref string, site cloudclient.SpawnSite) int {
	dep, derr := cfg.CloudClient().DeploySpawnSite(cloudCtx(), site.ID, false, "", "")
	if derr != nil {
		if siteInstanceNotLive(derr) {
			out.userErr("site %s created, but its instance is still provisioning — deploy it in a moment with `bp cloud site deploy %s`", ref, ref)
			return exitGeneric
		}
		return cloudFail(out, "deploy site", derr)
	}
	code, _ := streamSiteDeploy(out, cfg, ref, site.ID, dep, true)
	return code
}

// siteInstanceNotLive reports whether a deploy error is the control plane's 422
// instance_not_live — the box the site lives on is still provisioning and cannot
// build yet. cloudError renders the wire code (optionally `code: detail`) into the
// message, so the substring is the honest, decode-independent signal; the create
// --deploy one-motion degrades to a retry hint on it rather than a bare failure.
func siteInstanceNotLive(err error) bool {
	return err != nil && strings.Contains(err.Error(), "instance_not_live")
}

// runCloudSiteDeploy is `bp cloud site deploy <site>` (alias `build`) — enqueue a
// build, then stream the six visible stages until the deploy lands or fails.
func runCloudSiteDeploy(out *writer, g globals, args []string) int {
	const usage = "bp cloud site deploy <site> [--prebuilt <dir> [--deployment <id>]] [--no-follow] [--force] [--via cloudflare --domain <host>] [--wait-for-live <deadline>]"
	a, err := parseHzArgs(args, []string{"via", "domain", "prebuilt", "deployment", "wait-for-live"}, []string{"no-follow", "force"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	// cf-in-front: `--via cloudflare --domain <host>` asks the control plane to
	// point the domain at the box origin through Cloudflare (DNS + orange-cloud
	// proxy) BEFORE the build. `--domain` without `--via` is meaningless; catch
	// it locally rather than letting the server 4xx. Both ride the deploy body
	// ONLY when set (mirror `--force`), so a plain deploy is byte-identical.
	via := strings.TrimSpace(a.val("via"))
	domain := strings.TrimSpace(a.val("domain"))
	if domain != "" && via == "" {
		return useError(out, "usage", "--domain needs --via cloudflare (usage: "+usage+")", exitUsage)
	}

	// --wait-for-live <deadline> (dr-w32-bl-deploy-wait-for-live-flag): the
	// opt-in for callers that genuinely need LIVENESS — a CD pipeline gating a
	// release on the site actually serving the new bytes. D543 keeps a deferral
	// at exit 0 for everybody (a deferral loses nothing and is ~74% of settled
	// attempts); this flag is the other half of that ruling: keep polling PAST a
	// deferral until a live deployment for the same site+environment appears, or
	// exit non-zero when the caller's own deadline expires. Without it, nothing
	// below behaves differently in any way.
	waitForLive, werr := siteDeployWaitDeadline(a)
	if werr != nil {
		return useError(out, "usage", werr.Error()+" (usage: "+usage+")", exitUsage)
	}
	if waitForLive > 0 {
		if a.bools["no-follow"] {
			return useError(out, "usage", "--wait-for-live needs the follow stream to see the deferral settle — drop --no-follow (usage: "+usage+")", exitUsage)
		}
		if out.output == "json" || out.output == "yaml" {
			return useError(out, "usage", "--wait-for-live speaks through the exit code and the human stream; with -o "+out.output+" the single-envelope stdout contract would need two envelopes. Drop -o "+out.output+" (the exit code IS the machine answer) or poll `bp cloud site status -o json` instead", exitUsage)
		}
	}

	// --prebuilt <dir> is the lane where the build already happened somewhere
	// else (charter D85): the bytes ship, the serving box runs no npm. It is a
	// different two-call flow, so it branches before the one-call deploy — and
	// the dir is validated here, with no network touched, so a mistyped path can
	// never mint a deployment.
	prebuilt := strings.TrimSpace(a.val("prebuilt"))
	deploymentID := strings.TrimSpace(a.val("deployment"))
	if prebuilt != "" {
		if via != "" || domain != "" {
			return useError(out, "usage", "--prebuilt does not take --via/--domain: bind the domain with a plain deploy (or `bp cloud site settings`) and ship the bytes separately (usage: "+usage+")", exitUsage)
		}
		if waitForLive > 0 {
			return useError(out, "usage", "--wait-for-live is not wired for the --prebuilt lane: a prebuilt deploy switches on upload rather than riding the box's build queue, so the deferral this flag waits past does not occur there (usage: "+usage+")", exitUsage)
		}
		if _, verr := validatePrebuiltDir(prebuilt); verr != nil {
			return useError(out, "usage", verr.Error(), exitUsage)
		}
	} else if deploymentID != "" {
		return useError(out, "usage", "--deployment only applies to --prebuilt: it names the already-minted deployment whose build id your bytes carry (usage: "+usage+")", exitUsage)
	}

	cfg, ok := siteCloudConfig(out, "deploy a site")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	if prebuilt != "" {
		return runCloudSitePrebuiltDeploy(out, cfg, ref, id, prebuilt, deploymentID, a.bools["force"], !a.bools["no-follow"])
	}
	dep, derr := cfg.CloudClient().DeploySpawnSite(cloudCtx(), id, a.bools["force"], via, domain)
	if derr != nil {
		return cloudFail(out, "deploy site", derr)
	}
	code, final := streamSiteDeploy(out, cfg, ref, id, dep, !a.bools["no-follow"])
	if waitForLive <= 0 {
		return code
	}
	if !siteDeployDeferred(final.Status) {
		// The wait rides past a DEFERRAL and nothing else: live already answered,
		// failed/cancelled are drops no amount of waiting will cure, and a stream
		// that ran out of poll budget mid-build is narrated by the stream itself.
		// Say which case declined the wait rather than silently ignoring the flag.
		if !strings.EqualFold(final.Status, "live") {
			out.progressf("→ --wait-for-live not engaged: the deploy settled %s, not deferred — the wait only rides past a deferral (a re-queued rebuild it can watch for); this outcome has nothing queued to wait on", hzCell(strings.ToLower(strings.TrimSpace(final.Status))))
		}
		return code
	}
	return waitSiteDeployLive(out, cfg, ref, id, final, waitForLive)
}

// siteDeployWaitDeadline reads --wait-for-live: absent means no wait (zero), a
// value must be a positive Go duration — the caller's OWN deadline, stated up
// front, because an unbounded wait would turn a CD gate into a hang and a
// default deadline would be this CLI guessing how urgent someone's release is.
func siteDeployWaitDeadline(a *hzArgs) (time.Duration, error) {
	raw, has := lastVal(a, "wait-for-live")
	if !has {
		return 0, nil
	}
	raw = strings.TrimSpace(raw)
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("--wait-for-live wants a positive deadline as a Go duration (e.g. 10m, 90s), got %q", raw)
	}
	return d, nil
}

// waitSiteDeployWatchLimit is how many newest-first rows each wait poll reads
// from the site's deployment list. The re-queued rebuild is by definition one of
// the newest rows, so a page this size cannot miss it.
const waitSiteDeployWatchLimit = 20

// waitSiteDeployLive is the --wait-for-live loop (dr-w32-bl): the deploy above
// settled DEFERRED — the honest deferral narration has already printed, exit 0
// is everybody else's contract — and this caller opted into waiting for the
// re-queued rebuild to actually go LIVE.
//
// WHAT COUNTS AS ARRIVAL: a deployment row for this site that (a) reads status
// live, (b) belongs to the same environment as the deferred row (when both name
// one — a row that names no environment cannot be held to a match it never
// claimed), and (c) PROVABLY postdates the deferral by inserted_at. (c) is not
// pedantry: the site usually HAS a live row already — the previous build, the
// one visitors still see — and accepting it would declare victory on exactly
// the bytes the caller is waiting to replace. A live row whose inserted_at is
// missing is skipped, and the skip is narrated once rather than silently.
//
// ON THE DEADLINE it exits non-zero, naming the deadline it was given and the
// newest status it last read — never a bare timeout. The rebuild it was
// watching for is still queued; expiring the WAIT does not lose it.
func waitSiteDeployLive(out *writer, cfg *Config, ref, id string, deferred cloudclient.SiteDeployment, deadline time.Duration) int {
	env := strings.TrimSpace(deferred.Environment)
	scope := "any environment (the deferred row named none)"
	if env != "" {
		scope = "environment " + sanitizeCell(env)
	}
	out.progressf("→ --wait-for-live: watching for a live deployment for this site (%s) for up to %s — the re-queued rebuild carries this same content", scope, deadline)

	start := time.Now()
	lastStatus := strings.ToLower(strings.TrimSpace(deferred.Status))
	warnedUnprovable := false
	for time.Since(start) < deadline {
		time.Sleep(siteDeployPoll)
		page, err := cfg.CloudClient().ListSpawnSiteDeployments(cloudCtx(), id, waitSiteDeployWatchLimit, "")
		if err != nil {
			return cloudFail(out, "poll for a live deployment", err)
		}
		for _, d := range page.Deployments {
			if st := strings.ToLower(strings.TrimSpace(d.Status)); st != "" && d.ID != deferred.ID {
				lastStatus = st
			}
			if !strings.EqualFold(strings.TrimSpace(d.Status), "live") {
				continue
			}
			if env != "" && strings.TrimSpace(d.Environment) != "" && !strings.EqualFold(strings.TrimSpace(d.Environment), env) {
				continue
			}
			if strings.TrimSpace(d.InsertedAt) == "" || strings.TrimSpace(deferred.InsertedAt) == "" {
				if !warnedUnprovable {
					warnedUnprovable = true
					out.progressf("  skipping live deployment %s — without inserted_at on both rows the CLI cannot prove it postdates the deferral, and the site's PREVIOUS build is usually live too", sanitizeCell(d.ID))
				}
				continue
			}
			if d.InsertedAt <= deferred.InsertedAt {
				continue // the previous build, or an older round — not the rebuild we queued behind
			}
			return renderSiteDeployVerdict(out, ref, d)
		}
	}

	elapsed := time.Since(start).Round(time.Second)
	out.userErr("--wait-for-live deadline %s expired after %s — no live deployment for this site (%s) provably postdates the deferral; the newest status read was %s. Nothing was lost: the re-queued rebuild is still queued — watch it land with `bp cloud site status %s`",
		deadline, elapsed, scope, hzCell(lastStatus), ref)
	return exitGeneric
}

// runCloudSitePrebuiltDeploy is `bp cloud site deploy <site> --prebuilt <dir>` —
// the lane where the build ALREADY HAPPENED off the serving box (charter D85)
// and only the output travels. It is two calls, and the order is forced:
//
//  1. MINT — POST /deploy {"source":"prebuilt"} creates the deployment row
//     WITHOUT starting a build and answers with the build_id the bytes must
//     carry (HEALTH asserts that marker by value) and the content_rev only the
//     box can compute.
//  2. UPLOAD — the packed tar.gz goes to the deployment-scoped artifact route
//     with a real Content-Length and its sha256, and only then does the box
//     stage, health-gate and switch.
//
// Between the two the CLI REFUSES bytes that do not carry the minted build_id.
// That refusal is the honest one: such an upload is not a coin flip, it is a
// deploy that will fail at HEALTH after burning the round trip.
//
// THE LOOP MUST TERMINATE, and that is why `--deployment` exists. A prebuilt
// mint is deliberately NON-IDEMPOTENT on the control plane (it folds a nonce, so
// two different `dist/` uploads for the same content can never collide on one
// build_id), which means a plain re-run mints a DIFFERENT build id than the one
// the user just built against and the refusal would repeat forever. So the
// refusal names the deployment it minted, and the second run passes it back with
// `--deployment <id>`: no new mint, the same build id, the upload lands.
func runCloudSitePrebuiltDeploy(out *writer, cfg *Config, ref, id, dir, deploymentID string, force, follow bool) int {
	dep, code := resolvePrebuiltDeployment(out, cfg, id, deploymentID, force)
	if code != exitOK {
		return code
	}
	buildID := strings.TrimSpace(dep.BuildID)
	if buildID == "" {
		return useError(out, "failed", "the control plane minted a prebuilt deployment with no build_id — nothing to stamp the bytes with, so the upload would fail at HEALTH; re-run without --prebuilt to build on the box, or upgrade the control plane", exitGeneric)
	}

	marker, merr := prebuiltBuildMarker(dir)
	if merr != nil {
		return useError(out, "failed", merr.Error(), exitGeneric)
	}
	if marker != buildID {
		out.progressf("  export BARKPARK_BUILD_ID=%s", buildID)
		if cr := strings.TrimSpace(dep.ContentRev); cr != "" {
			out.progressf("  export BARKPARK_CONTENT_REV=%s", cr)
		}
		base, exact := prebuiltSiteBase(cfg, id, ref)
		out.progressf("  export BARKPARK_SITE_BASE=%s", base)
		if !exact {
			out.progressf(
				"  (could not read the site row, and %q is an id rather than a slug — replace <slug> above with the site's slug before you build; a wrong base 404s every asset and HEALTH cannot see it)",
				ref)
		}
		have := marker
		if have == "" {
			have = "(none)"
		}
		return useError(out, "failed", fmt.Sprintf(
			"%s/index.html carries build id %s, not the %s this deployment minted — HEALTH asserts that marker by value, so these bytes would be rejected on the box. Re-run your build with the exports above, then ship it to THIS deployment:\n\n  bp cloud site deploy %s --prebuilt %s --deployment %s\n\n(a plain re-run would mint a new build id — a prebuilt mint is nonced on purpose — and refuse again.)",
			dir, have, buildID, ref, dir, dep.ID), exitGeneric)
	}

	art, perr := packPrebuiltDir(dir)
	if perr != nil {
		return useError(out, "failed", perr.Error(), exitGeneric)
	}
	defer art.Cleanup()
	out.progressf("→ packed %s — %d bytes on the wire, sha256 %s", dir, art.WireBytes, art.SHA256)

	f, oerr := os.Open(art.Path)
	if oerr != nil {
		return useError(out, "failed", "read packed artifact: "+oerr.Error(), exitGeneric)
	}
	defer f.Close()
	up, uerr := cfg.CloudClient().UploadDeploymentArtifact(cloudCtx(), id, dep.ID, f, art.WireBytes, art.SHA256)
	if uerr != nil {
		return cloudFail(out, "upload artifact", uerr)
	}
	if n := up.Bytes; n > 0 && n != art.WireBytes {
		out.progressf("  control plane recorded %d bytes (client sent %d)", n, art.WireBytes)
	}
	out.progressf("→ uploaded — the box verifies the digest, then stages these bytes (BUILD is skipped: no npm runs there)")

	streamCode, _ := streamSiteDeploy(out, cfg, ref, id, dep, follow)
	return streamCode
}

// prebuiltSiteBase is the value BARKPARK_SITE_BASE must carry: the PATH the site
// is served under, `/sites/<slug>/` — byte-for-byte what the deploy engine exports
// for an on-box build (deploy/site-deploy.sh: BARKPARK_SITE_BASE="/sites/$SITE_SLUG/").
//
// It used to be printed from the DEPLOYMENT'S URL, and only when that URL was
// non-empty. Both halves were wrong, and the two hid each other:
//
//   - DEAD. The control plane's deployment_url is nil for anything not live, and a
//     prebuilt mint is deliberately queued — so the guard was never true at mint
//     time and this export, one of the three the help promises, could never print.
//     The live walk saw exactly two.
//   - WRONG IF IT HAD FIRED. A base is a PATH. astro.config.mjs prefixes a leading
//     slash to anything not already leading-slashed, so an absolute URL here bakes
//     base="/https://host/sites/slug/" and every asset href on the page 404s. The
//     box's HEALTH gate cannot see it: it asserts bp-build-id, bp-content-rev and
//     bp-doc-id by value, and never looks at bp-site-base.
//
// So it prints UNCONDITIONALLY, from the slug. The site row is the authoritative
// slug; when that read fails the ref the caller typed is the best slug available
// (it is the slug or name in every path that reaches here), because a missing
// export is precisely the failure being fixed.
//
// The second return value is whether the printed base is KNOWN-GOOD. There is one
// case where it cannot be: the site read failed AND the caller addressed the site
// by its UUID, so no slug exists anywhere in scope. Guessing there would bake the
// id into `base=` — a page whose every asset href 404s, which is exactly the class
// of silent breakage this function was written to end, and which HEALTH cannot see
// (it asserts bp-build-id/bp-content-rev/bp-doc-id, never bp-site-base). So that
// case prints a PLACEHOLDER the caller flags rather than a plausible wrong value.
func prebuiltSiteBase(cfg *Config, id, ref string) (string, bool) {
	if site, err := cfg.CloudClient().GetSpawnSite(cloudCtx(), id); err == nil {
		if slug := strings.TrimSpace(site.Slug); slug != "" {
			return "/sites/" + slug + "/", true
		}
	}
	slug := strings.Trim(strings.TrimSpace(ref), "/")
	if slug == "" || uuidLike.MatchString(slug) {
		return "/sites/<slug>/", false
	}
	return "/sites/" + slug + "/", true
}

// resolvePrebuiltDeployment gets the deployment the bytes will be attached to:
// the one named by `--deployment` (the resume half of the loop) or a freshly
// minted one. A named deployment is FETCHED rather than trusted, because the
// only two states that can accept an upload are "prebuilt" and "queued" — and a
// stale id from a shell history is otherwise a 409 several seconds later, after
// the pack.
func resolvePrebuiltDeployment(out *writer, cfg *Config, id, deploymentID string, force bool) (cloudclient.SiteDeployment, int) {
	if deploymentID == "" {
		dep, derr := cfg.CloudClient().MintPrebuiltDeployment(cloudCtx(), id, force)
		if derr != nil {
			return dep, cloudFail(out, "mint prebuilt deployment", derr)
		}
		out.progressf("→ minted prebuilt deployment %s (build %s) — no build started on the box", sanitizeCell(dep.ID), sanitizeCell(dep.BuildID))
		return dep, exitOK
	}

	dep, gerr := cfg.CloudClient().SpawnSiteDeployment(cloudCtx(), id, deploymentID)
	if gerr != nil {
		return dep, cloudFail(out, "read deployment "+deploymentID, gerr)
	}
	if src := strings.TrimSpace(dep.Source); src != "" && src != "prebuilt" {
		return dep, useError(out, "failed", fmt.Sprintf("deployment %s is a %s deploy — it will never read an uploaded artifact; drop --deployment to mint a prebuilt one", deploymentID, src), exitGeneric)
	}
	if st := strings.TrimSpace(dep.Status); st != "" && st != "queued" {
		return dep, useError(out, "failed", fmt.Sprintf("deployment %s is already %s — an artifact can only be attached while it is queued; drop --deployment to mint a fresh one and build against its build id", deploymentID, st), exitGeneric)
	}
	out.progressf("→ shipping to the already-minted deployment %s (build %s) — no new deployment, no build on the box", sanitizeCell(dep.ID), sanitizeCell(dep.BuildID))
	return dep, exitOK
}

// prebuiltBuildMarker reads the `bp-build-id` meta marker out of a built
// directory's root index.html — the same HTML-naive first-occurrence read the
// box's HEALTH gate does, deliberately, so the CLI and the gate agree about what
// a page claims. An unreadable index.html is an error; a page with no marker
// returns "" so the caller can say "(none)" rather than guess.
func prebuiltBuildMarker(dir string) (string, error) {
	path := filepath.Join(dir, "index.html")
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	defer f.Close()
	// The marker lives in <head>; a couple of MB is far past any real one and
	// keeps a stray huge index.html from being slurped whole.
	raw, err := io.ReadAll(io.LimitReader(f, 2<<20))
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	return metaMarkerValue(string(raw), "bp-build-id"), nil
}

// metaMarkerValue pulls `content="…"` out of the FIRST `<meta name="<name>">`
// tag in the document. Single and double quotes are both accepted (frameworks
// emit either); anything more structural than that belongs to a parser, and the
// gate this mirrors does not use one.
func metaMarkerValue(html, name string) string {
	lower := strings.ToLower(html)
	for _, q := range []string{`"`, `'`} {
		needle := `name=` + q + strings.ToLower(name) + q
		i := strings.Index(lower, needle)
		if i < 0 {
			continue
		}
		rest := html[i+len(needle):]
		ci := strings.Index(strings.ToLower(rest), "content=")
		if ci < 0 {
			continue
		}
		rest = rest[ci+len("content="):]
		if rest == "" {
			continue
		}
		quote := rest[:1]
		if quote != `"` && quote != `'` {
			continue
		}
		end := strings.Index(rest[1:], quote)
		if end < 0 {
			continue
		}
		return strings.TrimSpace(rest[1 : 1+end])
	}
	return ""
}

// streamSiteDeploy renders the deploy as a stage-aware progress stream: each
// completed stage is printed once, in order, then polls the deployment until it
// reaches a terminal state (live / failed / cancelled). Progress rides progressf so
// `-o json` keeps stdout a single envelope; the final deployment is the return value.
// It returns the LAST deployment it read beside the exit code, so an opted-in
// --wait-for-live caller can branch on how the stream settled without a second
// read; the default path ignores it and behaves exactly as before.
func streamSiteDeploy(out *writer, cfg *Config, ref, id string, dep cloudclient.SiteDeployment, follow bool) (int, cloudclient.SiteDeployment) {
	prov := siteTriggerNarration(dep.Trigger)
	if b := strings.TrimSpace(dep.BuildID); b != "" {
		out.progressf("→ deploy queued for %s (build %s)%s", ref, sanitizeCell(b), prov)
	} else {
		out.progressf("→ deploy queued for %s%s", ref, prov)
	}

	// printed is keyed by (name + status), NOT name alone: a stage that walks
	// running → done owes the reader TWO lines — the "… BUILD" that says work
	// started (the box streams `started` as status running; BUILD alone is ~38s of
	// silence otherwise) and the terminal "✓ BUILD". A name-only key would let the
	// running line SWALLOW the done line and the bar would never resolve (D39).
	printed := map[string]bool{}
	render := func(d cloudclient.SiteDeployment) {
		for _, st := range d.Stages {
			s := strings.ToLower(strings.TrimSpace(st.Status))
			if !siteStageNarratable(s) {
				continue
			}
			key := st.Name + "\x00" + s
			if printed[key] {
				continue
			}
			printed[key] = true
			out.progressf("  %s", siteStageLine(st))
		}
	}
	render(dep)

	d := dep
	for i := 0; follow && !cloudclient.SiteDeploymentTerminal(d.Status) && i < siteDeployPollMax; i++ {
		time.Sleep(siteDeployPoll)
		fresh, ferr := cfg.CloudClient().SpawnSiteDeployment(cloudCtx(), id, d.ID)
		if ferr != nil {
			return cloudFail(out, "poll deployment", ferr), d
		}
		d = fresh
		render(d)
	}

	if out.emitStructured(map[string]any{"deployment": siteDeploymentMap(d)}) {
		return siteDeployExit(d), d
	}
	return renderSiteDeployVerdict(out, ref, d), d
}

// renderSiteDeployVerdict is the human verdict on a deployment the stream stopped
// on — the extracted, network-free render the success-claim registry probes. Its
// ONLY input is the deployment record the control plane returned, and the exit
// code it returns is siteDeployExit's contract (a deploy that was DROPPED never
// exits 0; a deferred one — re-queued, nothing lost — deliberately does, see the
// D543 note on siteDeployExit).
//
// THE LIMIT IT SPEAKS. "live" is the control plane's record of its own SWITCH,
// and the CLI never fetches the URL — so the receipt names the deployment it read
// and says the URL is reported, not fetched, in the same breath as the checkmark.
// That is the `bp cloud deploy` idiom (an unperformable read-back is stated, not
// hidden) applied to the spawner: this render claims the RECORD, not the page.
func renderSiteDeployVerdict(out *writer, ref string, d cloudclient.SiteDeployment) int {
	switch {
	case strings.EqualFold(d.Status, "failed"):
		stage, reason := siteFailure(d)
		out.userErr("site deploy failed at %s — %s", sanitizeCell(stage), sanitizeCell(reason))
		return exitGeneric
	case siteDeployCancelled(d.Status):
		stage, reason := siteFailure(d)
		if reason == siteFailureFallback {
			// Nothing to elaborate: a cancel is not a build failure, so say only
			// what is true — the deploy stopped and the live build is untouched.
			out.userErr("site deploy cancelled at %s — nothing was switched, visitors still see the previous build", sanitizeCell(stage))
		} else {
			out.userErr("site deploy cancelled at %s — %s (nothing was switched, visitors still see the previous build)", sanitizeCell(stage), sanitizeCell(reason))
		}
		return exitGeneric
	case siteDeployDeferred(d.Status):
		// The MAJORITY outcome (73.7% of settled attempts, charter D209) and, until
		// wave 32, the one this verdict lied about: it fell through to the default
		// arm and printed "deploy in progress" over a row the control plane had
		// already settled. Nothing is in progress; the box refused this round and
		// re-queued a rebuild carrying the same content. Say all three things —
		// what happened, how deep the refusal chain is (siteDeferralLine, which
		// spells out that the depth counts consecutive same-cause refusals rather
		// than counting down to a drop), and that the operator must NOT re-publish
		// by hand to make it happen.
		//
		// THE STAGE IS QUOTED, NEVER GUESSED. An earlier cut defaulted an empty
		// stage to "PLAN", which is the stage a deferral plausibly stops at — and
		// a plausible guess printed as a reading is exactly the lie this epic
		// exists to remove. A control plane that sends no stage gets a sentence
		// that says so.
		if st := strings.TrimSpace(d.Stage); st != "" {
			out.outf("↺ site deploy deferred at %s — the box refused this round; nothing was built and nothing was switched, so visitors still see the previous build", sanitizeCell(st))
		} else {
			out.outf("↺ site deploy deferred before it named a stage — the box refused this round; nothing was built and nothing was switched, so visitors still see the previous build")
		}
		out.outf("  %s", siteDeferralLine(d))
		out.outf("  a rebuild carrying this same content is already queued — do NOT re-publish to force it; watch it land with `bp cloud site status %s`", ref)
		return siteDeployExit(d)
	case strings.EqualFold(d.Status, "live"):
		prov := siteTriggerNarration(d.Trigger)
		if u := strings.TrimSpace(d.URL); u != "" {
			out.outf("✓ site live — %s%s", u, prov)
			out.outf("  deployment %s reports live after SWITCH; the CLI did not fetch that URL, so this is the control plane's record, not a proof the page serves — confirm with `curl -sI %s`", hzCell(d.ID), u)
		} else {
			out.outf("✓ site live%s", prov)
			out.outf("  deployment %s reports live after SWITCH and carries no URL — the CLI has nothing to point you at; read one with `bp cloud site open %s`", hzCell(d.ID), ref)
		}
		return exitOK
	default:
		out.outf("… deploy in progress (stage %s) — watch it land with `bp cloud site status %s`", hzCell(d.Stage), ref)
		return exitOK
	}
}

// siteDeployExit is the exit code for a terminal deployment in machine-output
// mode: failed or cancelled → generic, otherwise 0. A deploy that was DROPPED
// must never exit 0 — a script that greps for success would ship a lie.
//
// DEFERRED KEEPS EXIT 0, DELIBERATELY (deploy-reliability charter D543 — decided,
// not an oversight, and pinned by TestRunCloudSiteDeployDeferredKeepsExitZero).
// A deferral is not a drop: wave 32 measured content coverage at 100.00% on
// settled deferrals, because the control plane re-queues a rebuild carrying the
// same content and it lands. Deferral is also 73.7% of settled attempts, so
// flipping it non-zero would break every `deploy && notify` chain and every
// `set -e` script for an outcome that loses nothing — cry-wolf on the operator
// surface, which is the exact failure this epic exists to prevent. What was
// dishonest here was the SENTENCE and the ten minutes of polling, both fixed in
// the deferred arm of renderSiteDeployVerdict; the code was always right.
// An opt-in `--wait-for-live` for callers that genuinely need liveness is filed
// separately (dr-w32-bl-deploy-wait-for-live-flag) and is NOT this function's job.
func siteDeployExit(d cloudclient.SiteDeployment) int {
	if strings.EqualFold(d.Status, "failed") || siteDeployCancelled(d.Status) {
		return exitGeneric
	}
	return exitOK
}

// siteTriggerNarration is the provenance suffix on the deploy stream's queued and
// terminal lines: a content-auto deploy announces it was fired by a publish on the
// bound dataset (the CMS self-updating), a manual one says so plainly. Empty when
// the control plane omitted the field (a pre-wave-5 box) so the CLI never claims a
// provenance it wasn't told — the wish's "observable, auto-vs-manual" bar.
func siteTriggerNarration(trigger string) string {
	switch strings.ToLower(strings.TrimSpace(trigger)) {
	case "content-auto":
		return " — auto: content publish"
	case "":
		return ""
	default:
		return " — manual"
	}
}

// siteTriggerLabel is the human status-table value for the deploy's provenance:
// content-auto reads as a self-triggered rebuild, manual as a hand-run deploy;
// any other non-empty value passes through sanitized rather than being dropped.
func siteTriggerLabel(trigger string) string {
	switch strings.ToLower(strings.TrimSpace(trigger)) {
	case "content-auto":
		return "content publish (auto)"
	case "manual":
		return "manual"
	default:
		return sanitizeCell(trigger)
	}
}

// siteDeployCancelled reports the control plane's `cancelled` deploy status. Both
// spellings are accepted because the wire word is a human-authored enum and a
// silent miss here is exactly the bug this function exists to kill: an unmatched
// terminal status polls the full budget (~10 min) and then reports "in progress".
func siteDeployCancelled(status string) bool {
	s := strings.ToLower(strings.TrimSpace(status))
	return s == "cancelled" || s == "canceled"
}

// siteDeployFailed is the one status that means the build DIED (as opposed to a
// human stopping it, which siteDeployCancelled owns). Named so the status verb's
// staleness arm reads on the same word the control plane writes.
func siteDeployFailed(status string) bool {
	return strings.EqualFold(strings.TrimSpace(status), "failed")
}

// siteFailureFallback is the last-resort explanation when neither the deployment
// nor its failed stage says anything — the ONLY honest thing left to say.
const siteFailureFallback = "the build did not pass its health gate — nothing was switched, visitors still see the previous build"

// siteFailure is what actually went wrong, in the order of decreasing truth:
// the deployment's own failure_reason, then the failed stage's `detail` (the line
// the deploy engine streamed for that stage), and only then the canned fallback.
// The stage name likewise prefers the deployment's in-flight stage, then the name
// of the stage that actually carries the failure.
func siteFailure(d cloudclient.SiteDeployment) (stage, reason string) {
	var failedName, failedDetail string
	for _, st := range d.Stages {
		s := strings.ToLower(strings.TrimSpace(st.Status))
		if s != "failed" && s != "error" {
			continue
		}
		failedName = strings.TrimSpace(st.Name)
		failedDetail = strings.TrimSpace(st.Detail)
		break
	}
	stage = siteOr(d.Stage, siteOr(failedName, "build"))
	reason = siteOr(strings.TrimSpace(d.FailureReason), siteOr(failedDetail, siteFailureFallback))
	return stage, reason
}

// siteDeployDeferred is the control plane's `deferred` status: a SETTLED row
// that is not a failure. The box refused this round (its concurrent-build cap is
// full, or a deploy for this site is already running) and a rebuild carrying the
// same content was re-queued. It is terminal in the transition table, so a
// deferred row never becomes anything else — but it is also not a drop, which is
// exactly why it must not be rendered with the failure vocabulary.
func siteDeployDeferred(status string) bool {
	return strings.EqualFold(strings.TrimSpace(status), "deferred")
}

// siteDeferralChainRe reads the chain depth the control plane writes into a
// deferred row (deploy-reliability charter D99, PR #9905): "refusal 3 of 12".
// The producer literal is in cloud/lib/barkpark_cloud/sites/deploy.ex defer/3 —
// this pattern and that sentence are ONE contract, and a pre-D99 control plane
// simply has no match, which is why every caller has an honest no-match arm
// instead of printing a zero.
var siteDeferralChainRe = regexp.MustCompile(`refusal (\d+) of (\d+)`)

// siteDeferralText is what a DEFERRED row says, in the same order of decreasing
// truth siteFailure uses — minus its fallback, which names a health gate that a
// deferred row never reached. Silence stays silence here.
func siteDeferralText(d cloudclient.SiteDeployment) string {
	if r := strings.TrimSpace(d.FailureReason); r != "" {
		return r
	}
	for _, st := range d.Stages {
		if det := strings.TrimSpace(st.Detail); det != "" {
			return det
		}
	}
	return ""
}

// siteDeferralChain is the chain's DEPTH and the bound its cause is measured
// against: the control plane's own COLUMNS first, and only then the row's words.
// ok is false against a control plane that reports neither.
//
// COLUMN-FIRST, PROSE-FALLBACK, AND THE FALLBACK IS NOT A COURTESY (charter
// D221). deferral_depth/deferral_bound went on the wire in #10301 and are stamped
// on 116 of 1,934 post-boundary deferred rows (6.0%), first written at
// 2026-08-07T10:12:35Z. That boundary is a HARD STEP: a row is NULL exactly when
// it predates that instant, so a column-only reader pointed at any pre-boundary
// window reads 100% NULL for the WHOLE window — it does not degrade by a
// fraction, it loses everything. The prose regex is what renders those rows
// today, and it is retired only when no un-backfilled deferred row can still be
// read, which no backfill has been proposed to reach.
//
// A PRESENT-BUT-UNUSABLE PAIR IS "NO CHAIN", NEVER A PROSE RE-READ. When the
// columns are there and say depth < 1 or bound < 1, the control plane has
// answered — with a value that describes no chain — and falling through to the
// regex would let a stale sentence CONTRADICT the column the same row carries.
// The two arms disagreeing is the one outcome this order exists to prevent.
//
// THE TWO ARMS ALSO COUNT DIFFERENT THINGS, which is why the depth is never
// presented as a chain identity: the column's notion is consecutive deferrals of
// the same CAUSE at the head of the site's stream, NOT the (site_id, content_rev)
// grouping — a content-rev chain of length 4 carries a stamped depth of 5.
func siteDeferralChain(d cloudclient.SiteDeployment) (depth, bound int, ok bool) {
	if d.DeferralDepth != nil && d.DeferralBound != nil {
		cd, cb := *d.DeferralDepth, *d.DeferralBound
		if cd < 1 || cb < 1 {
			return 0, 0, false
		}
		return cd, cb, true
	}
	m := siteDeferralChainRe.FindStringSubmatch(siteDeferralText(d))
	if m == nil {
		return 0, 0, false
	}
	depth, derr := strconv.Atoi(m[1])
	bound, berr := strconv.Atoi(m[2])
	if derr != nil || berr != nil || depth < 1 || bound < 1 {
		return 0, 0, false
	}
	return depth, bound, true
}

// --- the ABANDONED chain: the same numbers, the OPPOSITE fact ------------------

// siteDeployAbandoned is DeployLedger's abandonment cohort, read off the row's
// NAMED class (ABANDONED_AT_CAPACITY / ABANDONED_BOX_STUCK /
// ABANDONED_UNCLASSIFIED — deploy_ledger.ex abandoned_class/1).
//
// IT IS A CLASS PREDICATE, NEVER `deferral_depth >= 12` (deploy-reliability
// charter D195). Thresholding the depth would be right for the wrong reason on
// the capacity cause and simply WRONG on the busy/stuck one, whose bound is 6 —
// and it would answer zero forever against the pre-column rows.
//
// The prefix, not an exact set, on purpose: the day the ledger names a fourth
// abandonment cause, this reader keeps counting it instead of quietly dropping
// the row out of the cohort — the same inversion dr-w28-s4 fixed inside
// abandoned_class/1 itself.
func siteDeployAbandoned(class string) bool {
	return strings.HasPrefix(strings.ToUpper(strings.TrimSpace(class)), "ABANDONED_")
}

// siteAbandonmentChainRe reads the depth out of the terminal round's own
// sentence. The producer literal is Sites.Deploy.abandonment_reason/3
// (cloud/lib/barkpark_cloud/sites/deploy.ex:1424), and the control plane's own
// classifier anchors on the SAME clause (deploy_ledger.ex @abandoned) — three
// readers, one sentence, so a reword reds on the producer side first.
//
// It is NOT `refusal N of M`: that clause is written only on the DEFERRED branch
// (deploy.ex:1302). An abandoned row has never carried it, and a reader keyed on
// it matches nothing at all.
var siteAbandonmentChainRe = regexp.MustCompile(`— and it has now refused (\d+) rebuilds in a row for this site,`)

// siteAbandonmentText is the row's words in decreasing order of truth. The RAW
// capture is consulted too, because FailureReason can be the humanizer's generic
// arm — and the clause the depth lives in is in what the box actually said.
func siteAbandonmentText(d cloudclient.SiteDeployment) string {
	for _, s := range []string{d.FailureReason, d.FailureReasonRaw} {
		if t := strings.TrimSpace(s); t != "" && siteAbandonmentChainRe.MatchString(t) {
			return t
		}
	}
	for _, st := range d.Stages {
		if det := strings.TrimSpace(st.Detail); det != "" && siteAbandonmentChainRe.MatchString(det) {
			return det
		}
	}
	return ""
}

// siteAbandonmentDepth is how many rounds in a row the box refused before the
// publish was GIVEN UP ON — column-first, prose-fallback, exactly the order
// charter D221 already ruled for the deferral chain, and for the same reason:
// the columns were first written at a hard instant, so a column-only reader is
// blind to every row older than it rather than degraded by a fraction. Seven
// live abandoned rows carry NULL columns today and the sentence is all they have.
//
// On `main` today the prose arm is the ONLY reachable one — nothing writes the
// columns on an abandoned row until PR #11209 merges (see
// `siteAbandonmentBound`). The column-first order is kept anyway because it is
// the ruled one and because it needs no edit the day #11209 lands, whose
// `deferral_depth: prior + 1` is by construction the number this regex reads
// out of the same call's sentence.
//
// A PRESENT-BUT-UNUSABLE COLUMN IS "NO DEPTH", NEVER A PROSE RE-READ: the
// control plane has answered, and falling through would let a stale sentence
// contradict the column on the same row.
func siteAbandonmentDepth(d cloudclient.SiteDeployment) (int, bool) {
	if d.DeferralDepth != nil {
		if *d.DeferralDepth < 1 {
			return 0, false
		}
		return *d.DeferralDepth, true
	}
	m := siteAbandonmentChainRe.FindStringSubmatch(siteAbandonmentText(d))
	if m == nil {
		return 0, false
	}
	depth, err := strconv.Atoi(m[1])
	if err != nil || depth < 1 {
		return 0, false
	}
	return depth, true
}

// siteAbandonmentBound is the budget that depth was measured against, and it is
// COLUMN-ONLY on purpose. The bound is not in the sentence, and re-deriving
// "12 unless capacity, then 6" in Go would hardcode the control plane's
// per-cause budget in a second place — the precise mistake charter D195 names.
//
// So on a row without the column, depth and cause render and the bound does
// NOT. That asymmetry is the coverage signal, honestly rendered: a zero here
// would read as "abandoned against a budget of nothing".
//
// ON `main` TODAY THAT IS EVERY ABANDONED ROW, verified in the producer rather
// than taken on trust: the abandonment arm is `fail(ctx,
// abandonment_reason(reason, prior + 1, cause))` and `fail/2` writes only
// `status` / `failure_reason` / `detail` — the column triple is written on the
// DEFERRED arm alone. PR #11209 (`dr-w28-s6-abandonment-stamps-its-own-columns`,
// open, unmerged) is what starts writing them, with `deferral_depth: prior + 1`
// — the SAME number `abandonment_reason/3` interpolates, pinned there by
// `assert abandoned.failure_reason =~ "refused #{abandoned.deferral_depth}
// rebuilds in a row"`. So the two arms below cannot disagree, and this key is
// simply unreachable until #11209 lands: MERGE THAT FIRST, or ship this knowing
// `abandonment_bound` is dead until it does.
func siteAbandonmentBound(d cloudclient.SiteDeployment) (int, bool) {
	if d.DeferralBound == nil || *d.DeferralBound < 1 {
		return 0, false
	}
	return *d.DeferralBound, true
}

// siteDeferralLine is the operator's one-line read of a deferral chain.
//
// THE HONEST BOUND, and the reason this line spells out what is being counted
// rather than printing a bare "3 of 12": the depth is the number of CONSECUTIVE
// deferrals OF THE SAME CAUSE at the head of this site's deployment stream,
// scanned only @deferral_scan_depth (14) rows deep by the control plane's
// consecutive_deferrals/2. It is NOT a lifetime count — one successful deploy,
// or one deferral of a different cause, resets it to zero — so a site that
// deferred 75 times in 12h can legitimately read 3 here, and one did. A bare
// "3 of 12" would read as a countdown to a drop a merely-slow box may never
// reach, which is the opposite of the truth.
func siteDeferralLine(d cloudclient.SiteDeployment) string {
	depth, bound, ok := siteDeferralChain(d)
	if !ok {
		return "the box refused this deploy — this control plane does not report how deep the refusal chain is"
	}
	return fmt.Sprintf(
		"refusal %d of %d consecutive — counts only back-to-back refusals of the SAME cause, so any successful deploy resets it to 0; it is a zero-progress guard, not a countdown",
		depth, bound,
	)
}

// siteDeferredRow picks which row a status header's deferral section describes:
// the NEWEST one when it deferred (that is the round the operator is waiting
// on), else the live pointer if it is itself a deferred row. nil when neither
// deferred — the common case, where nothing is printed at all.
func siteDeferredRow(dep, newest *cloudclient.SiteDeployment) *cloudclient.SiteDeployment {
	if newest != nil && siteDeployDeferred(newest.Status) {
		return newest
	}
	if dep != nil && siteDeployDeferred(dep.Status) {
		return dep
	}
	return nil
}

// siteRequeueVisible answers the ONE question the deferral copy used to assume:
// does the page this status read actually carry a re-queued attempt for the row
// that was refused?
//
// It is deliberately narrow. A re-queue would arrive as a NEWER row on the same
// site that has not settled — so the evidence is "a non-terminal row whose
// inserted_at is strictly after the refused row's", and nothing else counts. A
// newer FAILED or LIVE row is not the refused round being retried, and an
// unparseable or absent stamp on either side proves nothing: both refuse rather
// than guess, because guessing here is exactly how the unconditional promise got
// written in the first place.
//
// In the shape the status header hits, this is nearly always false — the refused
// row IS the newest row on a newest-first page, so by construction there is
// nothing newer to see. That is the finding, not a defect in this function: from
// this page a re-queue is usually UNOBSERVABLE, and the copy must say so instead
// of asserting it.
func siteRequeueVisible(dd cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) bool {
	at, ok := siteParseStamp(dd.InsertedAt)
	if !ok {
		return false
	}
	for _, r := range ledger {
		if strings.EqualFold(strings.TrimSpace(r.ID), strings.TrimSpace(dd.ID)) {
			continue
		}
		if !siteDeployWaiting(r.Status) {
			continue
		}
		rt, rok := siteParseStamp(r.InsertedAt)
		if !rok || !rt.After(at) {
			continue
		}
		return true
	}
	return false
}

// siteRequeueClause is the parenthetical the deferred-newest status line ends on
// — a claim when the page proves one, and a named blind spot when it does not.
func siteRequeueClause(dd cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) string {
	if siteRequeueVisible(dd, ledger) {
		return "(a newer attempt is already on this site's ledger)"
	}
	return "(nothing newer than it is on the page this status read, so whether a rebuild has been re-queued is not visible from here — it is not evidence your publish was dropped)"
}

// runCloudSiteRollback is `bp cloud site rollback <site>` — the sub-second
// symlink flip to the previous good build.
func runCloudSiteRollback(out *writer, g globals, args []string) int {
	const usage = "bp cloud site rollback <site>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, ok := siteCloudConfig(out, "roll a site back")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	res, rberr := cfg.CloudClient().RollbackSpawnSite(cloudCtx(), id)
	if rberr != nil {
		return siteRefusalFail(out, siteRefusedRollback, ref, rberr)
	}

	if out.output == "json" {
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
		return exitOK
	}
	if out.output == "yaml" {
		out.renderRaw(res.Raw)
		return exitOK
	}
	renderSiteRolledBack(out, ref, res)
	return exitOK
}

// renderSiteRolledBack writes the rollback receipt from the envelope the control
// plane returned after the flip — the A1 case: the server measured the serving
// slot AFTER the swap and relays it, so the deployment id in the sentence IS the
// post-condition read. Extracted (network-free) so the success-claim registry can
// probe it with a backing and a contradicting envelope.
func renderSiteRolledBack(out *writer, ref string, res cloudclient.SiteRollbackResult) {
	if dep := strings.TrimSpace(res.DeploymentID); dep != "" {
		out.outf("✓ site rolled back — %s is now serving deployment %s.", ref, sanitizeCell(dep))
	} else {
		out.outf("✓ site rolled back — %s is now serving its previous build.", ref)
	}
	if prev := strings.TrimSpace(res.PreviousDeploymentID); prev != "" {
		out.outf("  was: %s", sanitizeCell(prev))
	}
	out.outf("  %s", siteRollbackMechanismLine(res.RuntimeTarget))
	if u := strings.TrimSpace(res.URL); u != "" {
		out.outf("  url: %s", sanitizeCell(u))
	}
}

// siteRollbackMechanismLine is the one-line explanation of HOW the rollback flipped,
// branched by runtime target (charter D62). The two runtime targets undo a bad
// build by DIFFERENT mechanisms, and the copy must not lie about which:
//
//   - static: an atomic symlink swap — the previous `dist/` symlink is re-pointed,
//     a broken build never reached a visitor and this reverses it instantly.
//   - node:   a Caddy reverse_proxy upstream flip back to the warm previous node
//     slot — a node process that failed its health probe never took the upstream,
//     so the flip back is sub-second and nothing cold-starts.
//
// The signal is the envelope's runtime_target (the rollback path never fetches the
// site row); an empty / static target falls back to the symlink copy the CLI has
// always printed — it never claims a node mechanism it wasn't told about.
func siteRollbackMechanismLine(runtimeTarget string) string {
	if cloudclient.RuntimeTargetIsNode(runtimeTarget) {
		return "the flip re-points the Caddy upstream to the previous warm node slot (<1s) — a node process that failed its health probe never took the upstream, and this reverses it instantly."
	}
	return "the flip is an atomic symlink swap (sub-second) — a broken build never reached visitors, and this reverses it instantly."
}

// siteIsNode reports whether a spawned site runs on the node-slot SSR runtime
// target (charter D62) — the container-framework path (Next.js/Nuxt/SvelteKit).
// siteKindForFramework is the runtime kind a framework deploys as when the
// caller does not pin one. It MIRRORS the dashboard's create form
// (cloud/priv/static/app.js `siteKindFor`): astro is the static
// symlink-swap flagship, every other framework rides the node slot. Keep the two
// in step â a divergence means the same inputs build different sites depending
// on which surface the user reached for.
func siteKindForFramework(framework string) string {
	if strings.TrimSpace(strings.ToLower(framework)) == "astro" {
		return "static"
	}
	return "node"
}

// The truth is the server's runtime_target when present; absent that, the `kind`
// discriminator ("node" is the user-facing verb, "container" the server enum) is
// the fallback so a node site still renders as node before its first deploy has
// stamped a runtime_target.
func siteIsNode(kind, runtimeTarget string) bool {
	if cloudclient.RuntimeTargetIsNode(runtimeTarget) {
		return true
	}
	k := strings.ToLower(strings.TrimSpace(kind))
	return k == "node" || k == "container"
}

// runCloudSiteStatus is `bp cloud site status <site>` — the current deployment +
// its stage. Honest empty state when the site has never deployed.
// runCloudSiteSettings is `bp cloud site settings <site> [--theme <p>]
// runCloudSiteDelete is `bp cloud site delete <site>`: the inverse of a spawn.
// It tears the site down on its box (stop slots + disarm the Caddy route + delete
// the tree) and deregisters the row — the CP does both, box-first, so a failed
// teardown never orphans a still-serving box. IRREVERSIBLE, so a TTY confirms the
// site name unless --yes; a non-TTY (script / `-o json`) skips the prompt.
func runCloudSiteDelete(out *writer, g globals, args []string) int {
	const usage = "bp cloud site delete <site> [--yes]"
	a, err := parseHzArgs(args, nil, []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, ok := siteCloudConfig(out, "delete a site")
	if !ok {
		return exitAuth
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "site (teardown + deregister — unrecoverable)", ref, g.yes || a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	res, derr := cfg.CloudClient().DeleteSpawnSite(cloudCtx(), id)
	if derr != nil {
		return siteRefusalFail(out, siteRefusedDelete, ref, derr)
	}

	if out.output == "json" {
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
		return exitOK
	}
	if out.output == "yaml" {
		out.renderRaw(res.Raw)
		return exitOK
	}
	renderSiteDeleted(out, ref, res)
	return exitOK
}

// renderSiteDeleted writes the delete receipt from the DELETE envelope — the
// extracted, network-free render the success-claim registry probes.
//
// WHAT IT STOPPED CLAIMING. The old line was "✓ site deleted — <slug> is torn
// down on its box and deregistered." The deregistration half is backed: the
// envelope is written after Registry.delete_site and carries the deleted row's
// slug. The TEARDOWN half was backed by nothing readable here — the control plane
// runs the box teardown first and refuses to deregister when it fails (so a
// success envelope does mean a teardown that did not report an error), but the
// box's own teardown report is unconditional (ssw8-teardown-truth), and this
// envelope carries no measured box state at all: no route, no slot, no tree. So
// the receipt claims the record and names the unread half in the same breath.
//
// An envelope that is not the success shape (ok:false, or a status that is not
// "deleted") gets no checkmark: an HTTP 200 is not the post-condition.
func renderSiteDeleted(out *writer, ref string, res cloudclient.SiteDeleteResult) {
	slug := strings.TrimSpace(res.Slug)
	if slug == "" {
		slug = ref
	}
	status := strings.ToLower(strings.TrimSpace(res.Status))
	if !res.OK || status != "deleted" {
		out.outf("site delete UNCONFIRMED — the control plane answered ok=%t status=%q for %s, which is not its deleted receipt; re-read it with `bp cloud site status %s`.",
			res.OK, sanitizeCell(res.Status), sanitizeCell(slug), ref)
		return
	}
	out.outf("✓ site deregistered — %s is deleted from the control plane (status: %s).", sanitizeCell(slug), sanitizeCell(res.Status))
	out.outf("  the box teardown ran first (the control plane refuses to deregister a site whose teardown errored), but this envelope carries no measured box state — nothing here read the route, the slots or the tree, so the teardown itself is UNVERIFIED by this receipt.")
}

// siteRefusalKind names WHICH site verb was refused. The three share the exit
// ladder and the label, but not their sentences: a refused rollback flipped
// nothing, a refused teardown leaves a site that is BOTH still registered and
// still serving, and a refused create never wrote a row at all — copy that blurs
// them tells the reader the wrong thing about what state their site is now in.
type siteRefusalKind int

const (
	siteRefusedRollback siteRefusalKind = iota
	siteRefusedDelete
	// siteRefusedCreate is `bp cloud site create`'s refusal arm (cch-w70). It joins
	// the ONE #11784 dialect rather than minting a second ladder: POST /v1/sites
	// emits no top-level 403 and no 409, so its refusals resolve on the SAME
	// status-family exit map (401 → cloudFail, no_team → 1, 404 → 4, 422 → 1,
	// 5xx → 8) — only its sentences differ, because a refused create wrote nothing.
	siteRefusedCreate
)

// what is the cloudFail fallthrough label — byte-unchanged from the strings these
// verbs have always printed ("roll site back: …", "delete site: …", "create
// site: …"), so the shared auth seam reads identically before and after this slice.
func (k siteRefusalKind) what() string {
	switch k {
	case siteRefusedDelete:
		return "delete site"
	case siteRefusedCreate:
		return "create site"
	default:
		return "roll site back"
	}
}

// noun is how a sentence refers to the refused act.
func (k siteRefusalKind) noun() string {
	switch k {
	case siteRefusedDelete:
		return "the deletion of"
	case siteRefusedCreate:
		return "the creation of"
	default:
		return "the rollback of"
	}
}

// verb is the bare action, for a sentence that already names the site ("not
// allowed to delete site %q").
func (k siteRefusalKind) verb() string {
	switch k {
	case siteRefusedDelete:
		return "delete"
	case siteRefusedCreate:
		return "create"
	default:
		return "roll back"
	}
}

// nothingClause is the honesty tail: what did NOT happen, stated positively so a
// deny path never reads like a partial action.
func (k siteRefusalKind) nothingClause() string {
	switch k {
	case siteRefusedDelete:
		return "Nothing was torn down and the site is still registered."
	case siteRefusedCreate:
		return "No site was created."
	default:
		return "Nothing was flipped."
	}
}

// siteRefusalFail maps a refused site rollback / delete onto the unified `bp:`
// error seam — the rollbackFail idiom (cloud_rollback_cmd.go), retargeted at the
// TYPED refusal both site verbs already carry.
//
// Both verbs used to hand the error to the bare `cloudFail`, which branches only
// on the substring "unauthorized": a 409 the box refused, a 404 that is not our
// site and a 500 the plane crashed on all printed the label "failed" and exited 1,
// and `-o json` named none of them. The refusal has been typed since #11711 —
// cloudError returns *cloudclient.CloudRefusal and both DeleteSpawnSite and
// RollbackSpawnSite route non-2xx through it — so the evidence was already on the
// wire and only the last inch discarded it.
//
// TWO fallthroughs are deliberate. A refusal that is not a *CloudRefusal at all (a
// transport error, a gateway page) and a 401 both route through cloudFail, so the
// "session expired? run `bp login` again" sentence stays the SAME one every other
// cloud verb prints for the one refusal that is never about the site.
func siteRefusalFail(out *writer, kind siteRefusalKind, ref string, err error) int {
	var re *cloudclient.CloudRefusal
	if errors.As(err, &re) && re.HTTPStatus != 401 {
		return useErrorDetailed(out, siteRefusalLabel(re.Code), siteRefusalMessage(kind, ref, re),
			siteRefusalExit(re.HTTPStatus, re.Reason, re.Code), siteRefusalDetails(re))
	}
	return cloudFail(out, kind.what(), err)
}

// siteRefusalDetails builds the machine-only `error.details` payload for a refused
// site verb. Today its sole member is the readable-types menu a
// `content_binding_empty` create refusal carries: the cleaned array (junk rows
// with an empty `type` already dropped by cloudError) is nested under
// `readable_types` so a script reading `bp cloud site create -o json` gets
// `error.details.readable_types` — the SAME list the console renders. The bytes
// are re-serialized from the decoded rows, NOT the server's raw bytes: row order
// and `type`-before-`count` key order are fixed by the ReadableType struct tags
// (never a Go map that would alphabetize), so the fingerprint is stable while
// junk rows stay out of the machine channel. Returns nil when the refusal
// carried no menu, so every other refusal emits a detail-less envelope
// byte-identical to the pre-menu shape.
func siteRefusalDetails(re *cloudclient.CloudRefusal) json.RawMessage {
	if len(re.ReadableTypesRaw) == 0 {
		return nil
	}
	return json.RawMessage(`{"readable_types":` + string(re.ReadableTypesRaw) + `}`)
}

// siteReadableTypesMenu renders the readable-types menu in the console's grammar
// (cloud/priv/static/app.js siteReadableTypesMenu): `type (count)` when the row
// carries a magnitude, the bare `type` when it does not, joined with ", ". A row
// with an empty type is skipped (cloudError already drops those, so this is a
// belt-and-braces guard). Empty when nothing usable survives — the caller's signal
// to relay the server's own sentence rather than promise a menu it cannot fill.
func siteReadableTypesMenu(types []cloudclient.ReadableType) string {
	parts := make([]string, 0, len(types))
	for _, t := range types {
		name := strings.TrimSpace(t.Type)
		if name == "" {
			continue
		}
		if t.Count != nil {
			parts = append(parts, fmt.Sprintf("%s (%d)", name, *t.Count))
		} else {
			parts = append(parts, name)
		}
	}
	return strings.Join(parts, ", ")
}

// siteRefusalLabel is the `bp:` error-code label — the control plane's own code
// where present, so the machine-readable envelope names the exact refusal, with a
// stable "failed" fallback for a codeless body.
func siteRefusalLabel(code string) string {
	if strings.TrimSpace(code) == "" {
		return "failed"
	}
	return code
}

// siteRefusalExit maps the refusal's HTTP status onto the CLI's stable exit
// ladder, by STATUS FAMILY (not by code) so a new refusal code the control plane
// adds is exit-coded correctly without a CLI change.
//
// The ONE exception is a CAUSE the CLI RECOGNISES, and it is the same doctrine
// `rollbackExit` carries: a teamless caller stays exitGeneric on both sides of the
// 422 {"error":"no_team"} → 403 {"error":"forbidden","reason":"no_team"}
// conversion. Exit 3 means "your credential is bad" — a script retries auth — and
// that is false here: the login is fine, it simply has no active team, and the fix
// is `bp team use <team>`. Only a recognised reason may override a status, so an
// unknown cause can never move an exit code.
func siteRefusalExit(status int, reason, code string) int {
	if reason == "no_team" || code == "no_team" {
		return exitGeneric // 1 — the cause, not the status family
	}
	switch {
	case status == 404:
		return exitNotFound // 4
	case status == 409:
		return exitConflict // 6 — the box refused (identity_refused)
	case status == 401 || status == 403:
		return exitAuth // 3
	case status >= 500:
		return exitServer // 8 — the plane or the box failed, not a measured refusal
	default:
		return exitGeneric // 1 — 422 teardown_failed / not_rollbackable
	}
}

// siteRefusalMessage is the one human sentence per refusal, per verb. Each says
// WHAT happened, what was NOT changed, and where the fix is. The control plane's
// own `detail` is RELAYED, never re-worded: `identity_refused` in particular is
// byte-frozen on the plane (deploy.ex `unreachable/2` deliberately echoes the
// instance seam), and a CLI that paraphrased it would make the console, the CLI and
// the plane tell three stories about one fact.
func siteRefusalMessage(kind siteRefusalKind, ref string, re *cloudclient.CloudRefusal) string {
	// The CAUSE the server named outranks the code, exactly as in the exit ladder:
	// "forbidden" alone would send a teamless caller to re-authenticate a
	// credential that is not the problem.
	if re.Reason == "no_team" || re.Code == "no_team" {
		return fmt.Sprintf("your Cloud login has no active team, so the control plane refused %s %q — run `bp team use <team>` and retry. %s",
			kind.noun(), ref, kind.nothingClause())
	}
	detail := strings.TrimSpace(re.Detail)
	switch re.Code {
	case "content_binding_empty":
		// The create door refused because the site's read token sees nothing at the
		// bound dataset, and it shipped the STRUCTURED menu of types it CAN read.
		// The console renders that menu from the array and STRIPS the CLI re-run
		// line (it is CLI-voiced); the CLI is that line's home, so it keeps it.
		// When the array survived, compose the receipt from the parts the CLI
		// controls — the verdict, the menu rendered in the console grammar, and the
		// re-run incantation the server built with the real dataset triple — so the
		// menu the user reads is the machine-readable list, not a prose copy that a
		// terser server might not send. With no usable array, the server's own
		// sentence is the most specific true thing, so relay it whole.
		if menu := siteReadableTypesMenu(re.ReadableTypes); menu != "" {
			verdict := detail
			if i := strings.Index(detail, ". "); i != -1 {
				verdict = detail[:i+1]
			}
			reRun := ""
			if i := strings.Index(detail, "Re-run naming a type"); i != -1 {
				reRun = strings.TrimSpace(detail[i:])
			}
			msg := fmt.Sprintf("%s It can read: %s.", siteRefusalDetail(verdict, "this site would build from nothing."), menu)
			if reRun != "" {
				msg += " " + reRun
			}
			return msg + " " + kind.nothingClause()
		}
		if detail != "" {
			return fmt.Sprintf("the control plane refused %s %q (%s): %s %s",
				kind.noun(), ref, sanitizeCell(re.Code), sanitizeCell(detail), kind.nothingClause())
		}
		return fmt.Sprintf("the control plane refused %s %q (%s) — nothing there is readable by this site's token. %s",
			kind.noun(), ref, sanitizeCell(re.Code), kind.nothingClause())
	case "identity_refused":
		// The box answered our stored admin credential with a 401, so nothing went
		// on the wire at all — a CONFLICT with the box's verdict about our
		// credential, not a network fault.
		return fmt.Sprintf("%s %q was refused before anything went on the wire: %s %s",
			kind.noun(), ref, siteRefusalDetail(detail, "the instance rejected our access credential."), kind.nothingClause())
	case "teardown_failed":
		return fmt.Sprintf("the instance could not tear site %q down: %s The site is still registered and may still be serving — the control plane refuses to deregister a site whose teardown errored, so retry once the box is healthy.",
			ref, siteRefusalDetail(detail, "the box reported no reason."))
	case "not_found":
		return fmt.Sprintf("no such site %q (or it is not in your team)", ref)
	case "barkpark_not_found":
		// create-only: the 404 is about the INSTANCE named to host the site, never
		// the site (which does not exist yet). Point the reader at --instance, not
		// at a site slug they never typed.
		return fmt.Sprintf("the instance named to host site %q is not in your team (or no longer exists) — list your fleet with `bp cloud status` and re-run with a valid --instance. %s",
			ref, kind.nothingClause())
	case "forbidden":
		return fmt.Sprintf("your Cloud login is not allowed to %s site %q — %s %s",
			kind.verb(), ref, siteRefusalDetail(detail, "it needs the `write` ability on the team that owns the site."), kind.nothingClause())
	case "server_error":
		// The plane crashed partway. For a delete that is the one genuinely
		// ambiguous state (the box teardown runs FIRST), and saying so is the
		// difference between a retry and a look.
		switch kind {
		case siteRefusedDelete:
			return fmt.Sprintf("the control plane errored while deleting %q: %s The box teardown runs BEFORE the row is deregistered, so the site may be torn down yet still registered — read `bp cloud site status %s` before retrying.",
				ref, siteRefusalDetail(detail, "it gave no reason."), ref)
		case siteRefusedCreate:
			// create's real 5xx paths carry their own codes (node_ports_exhausted
			// 503 / read_token_mint_failed 502, both handled by the default relay
			// arm) — a bare server_error is an unexpected crash. The read token is
			// minted BEFORE the row is inserted and no row is written unless the whole
			// pipeline succeeds, so a crash leaves no site.
			return fmt.Sprintf("the control plane errored while creating %q: %s %s",
				ref, siteRefusalDetail(detail, "it gave no reason."), kind.nothingClause())
		default:
			return fmt.Sprintf("the control plane errored while rolling %q back: %s %s",
				ref, siteRefusalDetail(detail, "it gave no reason."), kind.nothingClause())
		}
	default:
		// Every other code — including the flat `teardown_failed`/`rollback_failed`
		// twins' detail, `not_rollbackable`, and `registration_not_removed` when it
		// lands — relays the plane's sentence rather than flattening it to a slug.
		if detail != "" {
			return fmt.Sprintf("the control plane refused %s %q (%s): %s",
				kind.noun(), ref, sanitizeCell(re.Code), sanitizeCell(detail))
		}
		return fmt.Sprintf("the control plane refused %s %q (%s)", kind.noun(), ref, sanitizeCell(siteRefusalLabel(re.Code)))
	}
}

// siteRefusalDetail relays the plane's own sentence when it sent one, and falls
// back to a short clause when it did not — so a detail-less body still reads as a
// sentence instead of trailing off after a colon.
func siteRefusalDetail(detail, fallback string) string {
	if detail == "" {
		return fallback
	}
	return sanitizeCell(detail)
}

// [--doc-type <t>]` — PATCH the between-deploys-safe fields. Infrastructural
// fields stay immutable (name/slug/kind/framework/template/ports); an empty
// change is an honest usage error. The new values take effect on the NEXT
// deploy — the receipt says so.
func runCloudSiteSettings(out *writer, g globals, args []string) int {
	const usage = "bp cloud site settings <site> [--theme evergreen|ember|fjord|charple] [--doc-type <type>] [--prebuilt-enabled true|false]"
	a, err := parseHzArgs(args, []string{"theme", "doc-type", "prebuilt-enabled"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	patch := map[string]any{}
	if v := strings.TrimSpace(a.val("theme")); v != "" {
		patch["theme"] = v
	}
	if v := strings.TrimSpace(a.val("doc-type")); v != "" {
		patch["doc_type"] = v
	}
	// The per-site opt-in for `--prebuilt` deploys. Without a flag here the
	// control plane's `prebuilt_not_enabled` 422 would be unanswerable from bp:
	// the lane exists and nothing in the CLI could turn it on.
	if v := strings.TrimSpace(a.val("prebuilt-enabled")); v != "" {
		switch strings.ToLower(v) {
		case "true", "yes", "on", "1":
			patch["prebuilt_enabled"] = true
		case "false", "no", "off", "0":
			patch["prebuilt_enabled"] = false
		default:
			return useError(out, "usage",
				fmt.Sprintf("--prebuilt-enabled wants true or false, got %q (usage: %s)", v, usage), exitUsage)
		}
	}
	if len(patch) == 0 {
		return useError(out, "usage",
			"nothing to change — pass --theme, --doc-type and/or --prebuilt-enabled (usage: "+usage+")", exitUsage)
	}

	cfg, ok := siteCloudConfig(out, "update a site's settings")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	site, serr := cfg.CloudClient().UpdateSpawnSiteSettings(cloudCtx(), id, patch)
	if serr != nil {
		return cloudFail(out, "update site settings", serr)
	}

	if out.emitStructured(map[string]any{"site": spawnSiteMap(site)}) {
		return exitOK
	}
	renderSiteSettingsUpdated(out, ref, site)
	return exitOK
}

// renderSiteSettingsUpdated writes the settings receipt from the PATCHed row the
// control plane returned — a persisted-record echo (class A2), which backs a claim
// ABOUT THE RECORD, which is exactly what this sentence claims. Extracted and
// network-free so the success-claim registry can probe it: a server that stored
// something other than what you sent prints different values here.
func renderSiteSettingsUpdated(out *writer, ref string, site cloudclient.SpawnSite) {
	out.outf("✓ %s settings updated", hzCell(site.Name))
	if site.Theme != "" {
		out.outf("  theme:   %s", hzCell(site.Theme))
	}
	if site.Template != "" {
		out.outf("  starter: %s", hzCell(site.Template))
	}
	// W10: echo the doc_type you just set — this narration confirmed theme and
	// starter and stayed silent about the one field `--doc-type` changes.
	if site.DocType != "" {
		out.outf("  content: %s", hzCell(site.DocType))
	}
	out.outf("  (the values above are the row the control plane stored; they take effect on the next deploy — run `bp cloud site deploy %s`)", ref)
}

func runCloudSiteStatus(out *writer, g globals, args []string) int {
	const usage = "bp cloud site status <site>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, ok := siteCloudConfig(out, "read a site's status")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	site, serr := cfg.CloudClient().GetSpawnSite(cloudCtx(), id)
	if serr != nil {
		return cloudFail(out, "get site", serr)
	}

	// The current deployment: embedded in the site row when present, else fetched
	// by its pointer id — so status is stage-aware without depending on the server
	// always inlining it.
	dep := site.CurrentDeployment
	if dep == nil && strings.TrimSpace(site.CurrentDeploymentID) != "" {
		if d, derr := cfg.CloudClient().SpawnSiteDeployment(cloudCtx(), id, site.CurrentDeploymentID); derr == nil {
			dep = &d
		}
	}

	// THE SECOND READ, and the reason this verb stopped lying. The current pointer
	// can never read `failed` — it has three writers, all gated on status "live",
	// and `live` is terminal in the control plane's transition table — so a status
	// that resolves ONLY the pointer prints a serene "live" while the newest deploy
	// is a wall of red. The newest row is one bounded call away (limit=1, the same
	// route the console reads), and it carries the ledger's named failure_class.
	//
	// A control plane that cannot answer this list is NOT a reason to fail the
	// whole verb — the live pointer is still true — but it IS a reason to say the
	// staleness check did not run, rather than to imply it passed.
	//
	// W11: the SAME single call now asks for siteStatusLedgerPage rows instead of
	// one. limit=1 sees only the NEWEST pending row — i.e. the SHORTEST wait among
	// everything still queued — so a two-day-old stranded sibling behind a fresh
	// re-queue was invisible and the "still waiting" bound printed the most
	// flattering number available. Erring optimistic is the direction this epic
	// exists to eliminate. Row [0] is still the newest, so every existing reader of
	// `newest` is unchanged; the rest of the page feeds the censored bound only.
	var newest *cloudclient.SiteDeployment
	var ledger []cloudclient.SiteDeployment
	page, lerr := cfg.CloudClient().ListSpawnSiteDeployments(cloudCtx(), id, siteStatusLedgerPage, "")
	switch {
	case lerr != nil:
		out.errf("could not read this site's newest deployment (%v) — the header below describes the LIVE build only, and a newer failed deploy would not show here", lerr)
	case len(page.Deployments) > 0:
		ledger = page.Deployments
		n := page.Deployments[0]
		newest = &n
	}

	if out.machineOut() {
		payload := map[string]any{"site": spawnSiteMap(site)}
		// `deployment` stays the LIVE-pointer contract — every existing reader of
		// this envelope means "what is serving". The newest row rides beside it
		// under its own key, with the comparison spelled out rather than left for
		// the reader to redo.
		if dep != nil {
			payload["deployment"] = siteDeploymentMap(*dep)
		}
		if newest != nil {
			payload["latest_deployment"] = siteDeploymentMap(*newest)
			payload["staleness"] = siteStalenessMap(dep, newest, ledger)
		}
		// The window rides as its OWN node, present only when a page was actually
		// read — an absent `window` means "this status could not read the ledger",
		// which is the one thing a zeroed census would hide.
		if w, ok := siteReadWindow(ledger); ok {
			payload["window"] = siteWindowMap(w)
		}
		out.emitStructured(payload)
		return exitOK
	}

	renderKV(out, spawnSiteStatusMap(site, dep, newest, ledger))
	if w, ok := siteReadWindow(ledger); ok {
		renderSiteWindow(out, w)
	}
	if dep == nil {
		out.outf("")
		if newest != nil && siteDeployFailed(newest.Status) {
			out.outf("this site has never gone live — its last deploy failed. See why above, fix it, then re-run `bp cloud site deploy %s`", ref)
		} else {
			out.outf("no deployment yet — kick the first build with `bp cloud site deploy %s`", ref)
		}
		return exitOK
	}
	out.outf("")
	out.outf("stages:")
	for _, st := range siteStagesInOrder(*dep) {
		out.outf("  %s", siteStageLine(st))
	}
	return exitOK
}

// runCloudSiteOpen is `bp cloud site open <site>` — print (and, on a tty, open)
// the live PATH url https://<instance>.barkpark.cloud/sites/<slug>/.
func runCloudSiteOpen(out *writer, g globals, args []string) int {
	const usage = "bp cloud site open <site> [--print-only]"
	a, err := parseHzArgs(args, nil, []string{"print-only"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, ok := siteCloudConfig(out, "open a site")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	site, serr := cfg.CloudClient().GetSpawnSite(cloudCtx(), id)
	if serr != nil {
		return cloudFail(out, "get site", serr)
	}
	url := spawnSiteURL(site)
	if url == "" {
		return useError(out, "failed", fmt.Sprintf("site %q has no live URL yet — deploy it first with `bp cloud site deploy %s`", ref, ref), exitGeneric)
	}

	opened := false
	if !a.bools["print-only"] && out.isTTY {
		if berr := browserOpener(url); berr == nil {
			opened = true
		} else {
			out.errf("could not open a browser (%v) — copy the URL above", berr)
		}
	}

	if out.machineOut() {
		out.emitStructured(map[string]any{"ok": true, "site": spawnSiteRef(site), "url": url, "opened": opened})
		return exitOK
	}
	out.outf("%s", url)
	if opened {
		out.info("opening in your browser…")
	}
	return exitOK
}

// ---------------------------------------------------------------------------
// rendering helpers
// ---------------------------------------------------------------------------

// spawnSiteRef prefers the slug for a human-facing reference, falling back to the
// id — the token the user re-types into the next verb.
func spawnSiteRef(s cloudclient.SpawnSite) string {
	if slug := strings.TrimSpace(s.Slug); slug != "" {
		return slug
	}
	return s.ID
}

// spawnSiteURL returns the live path url: the control-plane-computed URL when
// present, else derived from the instance host + slug, else "". Never fabricates
// a host it does not know.
func spawnSiteURL(s cloudclient.SpawnSite) string {
	if u := strings.TrimSpace(s.URL); u != "" {
		return u
	}
	inst := strings.TrimSpace(s.Instance)
	slug := strings.TrimSpace(s.Slug)
	if inst == "" || slug == "" {
		return ""
	}
	host := inst
	if !strings.Contains(host, ".") {
		host = inst + ".barkpark.cloud"
	}
	return "https://" + host + "/sites/" + slug + "/"
}

// siteDatasetLabel renders the ws/proj/ds triple, preferring the server-echoed
// values and falling back to what the user typed.
func siteDatasetLabel(s cloudclient.SpawnSite, ws, proj, ds string) string {
	return fmt.Sprintf("%s/%s/%s", siteOr(s.Workspace, ws), siteOr(s.Project, proj), siteOr(s.Dataset, ds))
}

// siteOr returns v when non-blank, else the fallback.
func siteOr(v, fallback string) string {
	if strings.TrimSpace(v) != "" {
		return v
	}
	return fallback
}

// siteStageMark is the one-glyph status marker for a stage cell.
func siteStageMark(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "done", "ok", "passed", "live":
		return "✓"
	case "failed", "error":
		return "✗"
	case "running", "started", "in_progress", "building":
		return "…"
	case "skipped":
		return "–"
	default:
		return "·"
	}
}

// siteStageNarratable reports whether a stage status is worth a stream line: the
// running/started transition and every terminal outcome, but NOT the neutral
// pending/queued fill (those are silence, not progress). It is exactly the set of
// statuses siteStageMark gives a real glyph — the deploy stream and the status
// table stay in lockstep on what counts as "something happened".
func siteStageNarratable(status string) bool {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "running", "started", "in_progress", "building",
		"done", "ok", "passed", "live",
		"failed", "error", "skipped":
		return true
	default:
		return false
	}
}

// siteStageLine renders one stage: marker, name, and any detail — the streamed
// progress line and the status table row share this.
func siteStageLine(st cloudclient.SiteStage) string {
	line := fmt.Sprintf("%s %-6s", siteStageMark(st.Status), hzCell(st.Name))
	if d := strings.TrimSpace(st.Detail); d != "" {
		line += "  " + sanitizeCell(d)
	}
	return line
}

// siteStagesInOrder returns the deployment's stages in the canonical
// PLAN→RETIRE order, filling any the payload omitted as pending — so the status
// view always shows the full six-stage bar even for a lean server reply.
func siteStagesInOrder(d cloudclient.SiteDeployment) []cloudclient.SiteStage {
	by := map[string]cloudclient.SiteStage{}
	for _, st := range d.Stages {
		by[strings.ToUpper(strings.TrimSpace(st.Name))] = st
	}
	out := make([]cloudclient.SiteStage, 0, len(cloudclient.SpawnSiteStages))
	for _, name := range cloudclient.SpawnSiteStages {
		if st, ok := by[name]; ok {
			out = append(out, st)
		} else {
			out = append(out, cloudclient.SiteStage{Name: name, Status: "pending"})
		}
	}
	return out
}

// spawnSiteMap is the structured (json/yaml) shape of a spawned site.
// siteCreatedEnvelope is the machine-mode create result: the row, plus the
// control plane's create-time binding verdict WHEN IT SENT ONE. The key is
// omitted entirely for a create that carried no verdict, so a script can tell
// "the control plane did not probe this kind" from "the probe came back
// unverified" without parsing prose — the same distinction the human line makes.
func siteCreatedEnvelope(s cloudclient.SpawnSite, binding cloudclient.ContentBinding) map[string]any {
	env := map[string]any{"site": spawnSiteMap(s)}
	if m := contentBindingMap(binding); m != nil {
		env["content_binding"] = m
	}
	return env
}

// contentBindingMap re-emits the verdict for the machine channel, key-for-key with
// the producer: an absent `count` stays ABSENT (never a fabricated 0), `detail`
// keeps its name (it is not `reason`), and a verdict-less binding is nil so the
// caller can drop the key rather than emit an empty object that reads like a
// verdict of its own.
func contentBindingMap(b cloudclient.ContentBinding) map[string]any {
	if strings.TrimSpace(b.Status) == "" {
		return nil
	}
	m := map[string]any{"status": b.Status}
	if strings.TrimSpace(b.DocType) != "" {
		m["doc_type"] = b.DocType
	}
	if b.Count != nil {
		m["count"] = *b.Count
	}
	if strings.TrimSpace(b.Detail) != "" {
		m["detail"] = b.Detail
	}
	return m
}

// renderSiteContentClaim writes the create receipt's `content:` line — the one
// place two different facts about the same doc type have to be told apart:
//
//	the ROW's doc_type      what the control plane STORED on the site
//	the BINDING verdict     what the control plane READ, through this site's own
//	                        token, before it answered 201 (charter D73)
//
// A stored type is not a proven read, and the line says which one it is printing.
// The three verdicts and what each may claim:
//
//   - BOUND WITH A COUNT — the box published a total for the type, so the receipt
//     names it. This is the strongest thing the create can honestly say.
//   - BOUND WITHOUT A COUNT — the producer OMITS `count` when the box published no
//     total, and an absent count is not a zero one. The line says bound and prints
//     NO number: "0 documents" about a site nobody counted is a worse lie than
//     silence, and it is exactly the lie a non-pointer Count would tell.
//   - UNVERIFIED — the read could not be confirmed. This is the case the whole
//     surfacing exists for: it used to print the same confident line as a
//     confirmed binding, so a CLI user was told nothing and believed the binding
//     had been checked. It now says NOT confirmed and relays the server's own
//     reason (the key is `detail`; the arm carries no doc type, so the type comes
//     from the row or the request).
//
// A verdict-less envelope (an empty Status — the control plane does not probe
// every kind) falls through to the stored-row line ALONE. Absent is not
// unverified: printing a failure for a probe that never ran would be the same
// class of invention this line exists to prevent.
func renderSiteContentClaim(emit func(string, ...any), site cloudclient.SpawnSite, binding cloudclient.ContentBinding, req cloudclient.SpawnSiteCreate) {
	switch strings.ToLower(strings.TrimSpace(binding.Status)) {
	case "bound":
		typ := siteOr(binding.DocType, siteOr(site.DocType, req.DocType))
		if binding.Count != nil {
			emit("  content: %s — bound: the control plane read %d of them through this site's own token at create", hzCell(typ), *binding.Count)
			return
		}
		emit("  content: %s — bound: the control plane confirmed this site can read the type at create, and the box published no total, so none is claimed", hzCell(typ))
		return
	case "unverified":
		typ := siteOr(site.DocType, req.DocType)
		emit("  content: %s — the control plane could NOT confirm this site can read the type: %s", hzCell(typ), siteBindingReason(binding.Detail))
		return
	}
	switch {
	case strings.TrimSpace(site.DocType) != "":
		emit("  content: %s (the type stored on the site row; this envelope carried no create-time verdict about it)", hzCell(site.DocType))
	case strings.TrimSpace(req.DocType) != "":
		emit("  content: %s requested — the control plane echoed no doc type back, so the binding is UNCONFIRMED", hzCell(req.DocType))
	}
}

// siteBindingReason relays the server's stated reason, and says so plainly when
// there is none — an unverified verdict with an empty detail is still a refusal to
// confirm, and blank space after a colon would read like one that was confirmed.
func siteBindingReason(detail string) string {
	if d := strings.TrimSpace(detail); d != "" {
		return d
	}
	return "the control plane gave no reason"
}

func spawnSiteMap(s cloudclient.SpawnSite) map[string]any {
	m := map[string]any{
		"id":        s.ID,
		"name":      s.Name,
		"slug":      s.Slug,
		"kind":      s.Kind,
		"framework": s.Framework,
		"template":  s.Template,
		"theme":     s.Theme,
		// W10: always echoed like template/theme — an empty string honestly means
		// the control plane predates the field, never that the site has no type.
		"doc_type":  s.DocType,
		"workspace": s.Workspace,
		"project":   s.Project,
		"dataset":   s.Dataset,
	}
	if s.BarkparkID != "" {
		m["barkpark_id"] = s.BarkparkID
	}
	if u := spawnSiteURL(s); u != "" {
		m["url"] = u
	}
	if s.Instance != "" {
		m["instance"] = s.Instance
	}
	// Node-slot fields (charter D62): surfaced ONLY when the server sent them, so a
	// static site's JSON is byte-identical to before. These are the fields Go's
	// json.Unmarshal would silently drop if SpawnSite didn't declare them.
	if s.RuntimeTarget != "" {
		m["runtime_target"] = s.RuntimeTarget
	}
	if s.Port != 0 {
		m["port"] = s.Port
	}
	if s.PortBase != 0 {
		m["port_base"] = s.PortBase
	}
	if s.CurrentDeploymentID != "" {
		m["current_deployment_id"] = s.CurrentDeploymentID
	}
	return m
}

// spawnSiteStatusMap is the KV view of a site's status header (the human table
// above the stage list).
//
// It takes BOTH deployments the status verb reads: `dep` is the live pointer (what
// is serving) and `newest` is the newest row in the ledger (what happened last).
// They are usually the same row. When they are not — and the newest one failed —
// the header must not print a bare "live", because "live" then describes an OLD
// build while the site's actual last word was a failure. `newest` is nil when the
// list read failed or the site has no deployments at all; in neither case does
// this function claim the two agree.
//
// `ledger` is the rest of that same page (newest first, `newest` included) — it
// feeds ONE thing: the right-censored "still waiting" bound in the time-to-web
// line, which must be taken from the OLDEST waiting row, not the newest.
func spawnSiteStatusMap(s cloudclient.SpawnSite, dep, newest *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) map[string]any {
	m := map[string]any{
		"site":      spawnSiteRef(s),
		"kind":      hzCell(s.Kind),
		"framework": hzCell(s.Framework),
		"dataset":   siteDatasetLabel(s, "", "", ""),
	}
	// W10: the featured content type this site's build reads. Guarded like every
	// other optional row here — a pre-W10 control plane sends nothing and the
	// header stays exactly as it was.
	if dt := strings.TrimSpace(s.DocType); dt != "" {
		m["doc type"] = hzCell(dt)
	}
	// Runtime target + slot port (charter D62): a node site advertises the node-slot
	// SSR runtime and the port its live process is bound to, so a user reading
	// `status` sees it runs a process, not files. Shown for node sites only — a
	// static site's status header is unchanged.
	if siteIsNode(s.Kind, s.RuntimeTarget) {
		m["runtime"] = hzCell(siteOr(s.RuntimeTarget, cloudclient.RuntimeTargetNode))
		if s.Port != 0 {
			m["port"] = fmt.Sprintf("%d", s.Port)
		}
	}
	if u := spawnSiteURL(s); u != "" {
		m["url"] = u
	}
	if dep != nil {
		m["deployment"] = hzCell(dep.ID)
		m["status"] = hzCell(dep.Status)
		if st := strings.TrimSpace(dep.Stage); st != "" {
			m["stage"] = st
		}
		// Provenance: was this deploy hand-triggered or fired by a content publish
		// on the bound dataset? Only surface it when the control plane sent it (a
		// pre-wave-5 box omits the key entirely).
		if tr := strings.TrimSpace(dep.Trigger); tr != "" {
			m["trigger"] = siteTriggerLabel(tr)
		}
		// THE BUILD IDENTITY (dr-w23-s6). The control plane has shipped these three
		// on this payload all along — `site_deployment_json/3` pipes the narrow
		// `deployment_json/1` — but `cloudclient.SiteDeployment` declared no field
		// for them, so `json.Unmarshal` dropped them and this page could not print
		// what `bp sites` prints from the narrow route. "Which build is this?" is
		// the question a status header exists to answer.
		//
		// Guarded individually, like every other optional row here: a control plane
		// that omits one (a static site has no image tag; a content deploy has no
		// git ref) leaves that row out rather than printing an empty cell.
		if gr := strings.TrimSpace(dep.GitRef); gr != "" {
			m["git ref"] = hzCell(gr)
		}
		if it := strings.TrimSpace(dep.ImageTag); it != "" {
			m["image tag"] = hzCell(it)
		}
		if au := strings.TrimSpace(dep.ArtifactURL); au != "" {
			m["artifact"] = hzCell(au)
		}
		// A deploy that did not go live owes the reader a reason — the deployment's
		// failure_reason, else the failed stage's streamed detail.
		if strings.EqualFold(dep.Status, "failed") || siteDeployCancelled(dep.Status) {
			_, reason := siteFailure(*dep)
			m["reason"] = sanitizeCell(reason)
		}
		// THE DEPLOYMENT'S OWN CAPTION, and it is not `reason`. The wire's
		// top-level `detail` is `Sites.Deploy.stage_caption(d.status, d.detail)` —
		// the same string family the failure arms above render, which is exactly
		// why it is printed only when it says something they did NOT already say.
		// Printing both unconditionally would put the same sentence on the screen
		// twice and teach a reader that one of the two rows is noise.
		if dt := strings.TrimSpace(dep.Detail); dt != "" {
			if existing, ok := m["reason"].(string); !ok || !strings.EqualFold(strings.TrimSpace(existing), dt) {
				m["detail"] = sanitizeCell(dt)
			}
		}
	} else {
		m["status"] = "never deployed"
	}
	// THE STALENESS ARM. The live pointer and the newest ledger row disagree, and
	// the newest one failed — so "live" alone is a half-truth: it names a build the
	// box is still serving BECAUSE the next one never got switched in. Say both.
	newestFailedStale := newest != nil && siteDeployFailed(newest.Status) && (dep == nil || !strings.EqualFold(newest.ID, dep.ID))
	if newestFailedStale {
		if dep != nil {
			m["status"] = "live — but the NEWEST deploy FAILED (visitors still see this older build)"
		} else {
			m["status"] = "never went live — the newest deploy FAILED"
		}
		m["newest deployment"] = hzCell(newest.ID)
		m["newest status"] = hzCell(newest.Status)
		// FEED the failure renderer, do not rewrite it: siteFailure prefers the
		// deployment's own failure_reason and falls back to the failed stage's
		// streamed detail. Its input was simply unreachable until this second read.
		_, reason := siteFailure(*newest)
		m["reason"] = sanitizeCell(reason)
	}
	// The ledger's NAMED cause, from whichever failed row this header describes —
	// the server has computed it from the raw column all along and no Go type
	// declared it, so it decoded to nothing and printed as nothing.
	if fc := siteFailureClass(dep, newest); fc != "" {
		m["failure class"] = hzCell(fc)
	}
	// DEFERRED IS NOT FAILED, and until D99 it rendered as NOTHING at all here:
	// the reason arm above fires only on failed/cancelled, so a settled `deferred`
	// row printed a bare status word and the operator could not tell a first blip
	// from a chain eight rounds deep. The chain gets its own row rather than a
	// sentence buried in prose, because "how deep am I" is the whole question a
	// deferral raises.
	//
	// REVIEW FIX (dr-w7): gated on `!newestFailedStale`. The two arms both write
	// `reason`, and this one runs SECOND — so when the newest row FAILED while the
	// live pointer happened to be a deferred row, the header said "the NEWEST
	// deploy FAILED" and then printed the older deferral's sentence underneath it,
	// describing a different row than the status line names. The failure is the
	// louder truth and it wins; the live pointer is only ever written on a `live`
	// transition today, so this is a defensive ordering guard, not a live bug.
	if dd := siteDeferredRow(dep, newest); dd != nil && !newestFailedStale {
		if newest != nil && siteDeployDeferred(newest.Status) && (dep == nil || !strings.EqualFold(newest.ID, dep.ID)) {
			// Same shape as the staleness arm above, for the sibling half-truth:
			// "live" alone names a build the box is still serving BECAUSE the next
			// one was refused.
			//
			// THE RE-QUEUE IS NOW CONDITIONAL, and this is the sharpest correction
			// on this surface (charter D213). Both lines used to end "(a rebuild is
			// already re-queued)" UNCONDITIONALLY, and the comment that stood here
			// said so out loud — "the difference being that this one is re-queued,
			// not lost". The CLI cannot see that. On site `search`, 47 of 523
			// content_rev chains are deferred-only with no live and no failed row,
			// and every one of them printed that promise. So the clause is asserted
			// only where the page actually carries a newer attempt, and otherwise
			// the header says what it can and cannot see from here.
			//
			// IT IS NOT ESCALATED INTO A LOSS CLAIM (charter D212): of 227 settled
			// abandoned chains, 227 have a later live row on the same site and ZERO
			// do not — the abandonment is benign supersession. "We cannot see one
			// from here" is the honest register; "your publish was lost" would be a
			// second false claim pointing the other way.
			requeue := siteRequeueClause(*newest, ledger)
			if dep != nil {
				m["status"] = "live — the NEWEST deploy was DEFERRED by the box " + requeue
			} else {
				m["status"] = "never went live — the newest deploy was DEFERRED by the box " + requeue
			}
			m["newest deployment"] = hzCell(newest.ID)
			m["newest status"] = hzCell(newest.Status)
		}
		m["deferral"] = siteDeferralLine(*dd)
		if txt := siteDeferralText(*dd); txt != "" {
			m["reason"] = sanitizeCell(txt)
		}
	}
	// THE CLOCK, slotted LAST and deliberately in a key of its own. Every other arm
	// above competes over `status` and `reason`; this one writes only "time to web"
	// and reads nothing either arm wrote, which is what keeps it structurally clear
	// of the dr-w7 precedence bug (two arms writing `reason`, the second describing
	// a different row than the status line named). Empty means the stamps could not
	// support a sentence — never an imputed zero.
	if line := siteTimeToWebLine(dep, ledger); line != "" {
		m["time to web"] = line
	}
	return m
}

// siteStatusLedgerPage is how many ledger rows `status` asks for in its ONE list
// call. See the comment at the call site: the newest row alone answers "did the
// last thing that happened fail?", but it CANNOT answer "how long has anything
// been waiting?" — that answer lives in the oldest still-pending row, which a
// limit of 1 structurally hides. 20 is a bounded page, not a walk.
const siteStatusLedgerPage = 20

// siteClock is now, injectable so the duration tests are not a race.
var siteClock = func() time.Time { return time.Now().UTC() }

// siteShortDur renders a duration in TWO units — "4m25s", "2h39m", "3d04h".
//
// It exists because package cli's only duration renderer, deployCensusWidth,
// floors at whole minutes ("%.0f minutes"), which is right for a census WINDOW
// and wrong for a publish: a 265-second deploy prints "4 minutes" there, and
// anything under 30 seconds prints "0 minutes" — a number that reads as "instant"
// for a deploy that took half a minute. The two renderers are deliberately
// different functions and a test pins that they disagree.
func siteShortDur(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	default:
		return fmt.Sprintf("%dd%02dh", int(d.Hours())/24, int(d.Hours())%24)
	}
}

// siteParseStamp reads one control-plane timestamp, refusing everything it cannot
// prove. The refusal is the whole point: SiteDeployment.BecameLiveAt is a BARE
// string, so an absent stamp arrives as "" — and time.Parse("") does not error
// into nothing, it is simply never allowed to reach the arithmetic, because the
// zero instant minus a 2026 timestamp is a time-to-web of roughly two millennia
// printed as fact.
func siteParseStamp(s string) (time.Time, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, false
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05.999999", "2006-01-02T15:04:05"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.UTC(), true
		}
	}
	return time.Time{}, false
}

// siteTimeToWeb is how long this deployment took to reach visitors: the gap
// between the control plane accepting it (inserted_at) and the switch that put it
// in front of traffic (became_live_at).
//
// NAME THE CLOCK, because this one is easy to over-claim: t0 is inserted_at — the
// moment the CONTROL PLANE picked the work up — not the moment a human hit
// publish. Publish→insert is debounced (up to 60s) and measured to understate the
// human-felt wait by ~4.8x over a 24h window, so every renderer of this number
// must say whose clock it is. A later wave re-keys it to a true publish stamp.
//
// It refuses three ways and imputes nothing: an empty stamp (never went live), an
// unparseable stamp (a control plane speaking a shape we do not model), and a
// became_live_at that precedes inserted_at (clock skew or a repointed row — a
// negative duration is not a fast deploy).
func siteTimeToWeb(d cloudclient.SiteDeployment) (time.Duration, bool) {
	live, lok := siteParseStamp(d.BecameLiveAt)
	ins, iok := siteParseStamp(d.InsertedAt)
	if !lok || !iok {
		return 0, false
	}
	gap := live.Sub(ins)
	if gap < 0 {
		return 0, false
	}
	return gap, true
}

// siteDeployWaiting reports a row whose CONTENT has not reached the web and is
// not going to stop trying: anything the transition table has not settled as live,
// failed or cancelled.
//
// DEFERRED COUNTS, and this predicate used to say the opposite (`&& !siteDeployDeferred(s)`,
// dr-w7). A deferred row is settled as a ROW and unsettled as a PUBLISH: the box
// refused the round and the control plane re-queued a rebuild carrying the same
// content, so nothing has reached visitors and nothing has been given up on. That
// is the definition of a wait — and it is the ONE shape that is genuinely
// unbounded, since a refusal can be followed by a refusal forever. Excluding it
// meant siteWaitingSince structurally could not see the very case it exists to
// bound, while deferrals grew to 53.6% of attempts.
//
// A deferred row is still not a FAILURE, and nothing here changes that vocabulary:
// the failure arms in spawnSiteStatusMap key off siteDeployFailed and never off
// this predicate.
//
// THE `|| siteDeployDeferred(s)` ARM IS LEVEL WITH THAT PARAGRAPH, NOT REDUNDANT
// WITH IT. Wave 32 made `deferred` TERMINAL in cloudclient.SiteDeploymentTerminal
// (it is settled server-side, so the deploy stream must stop polling it), which
// would otherwise have silently reverted dr-w12 S7 by dropping deferred out of
// this predicate — four tests named that revert, TestSiteWaitingSinceMeasures-
// ADeferralChainFromItsStart loudest. The two questions are genuinely different
// and now read differently: SiteDeploymentTerminal asks "can this ROW still
// change?" (no), this asks "has the CONTENT reached the web?" (also no, and a
// re-queued rebuild is still trying). Deleting this arm re-breaks the clock.
func siteDeployWaiting(status string) bool {
	s := strings.TrimSpace(status)
	if s == "" {
		return false
	}
	return !cloudclient.SiteDeploymentTerminal(s) || siteDeployDeferred(s)
}

// siteWaitingSince is the RIGHT-CENSORED bound for a revision that has not reached
// the web yet: how long the OLDEST still-waiting row newer than the live pointer
// has been waiting. Censored because the wait is not over — the true time-to-web
// is at least this, and unknowable until the switch happens.
//
// OLDEST, not newest, on purpose. The page arrives newest-first, so reading row
// [0] reports the SHORTEST wait among everything pending and hides a stranded
// two-day-old sibling behind a fresh re-queue. This function takes the maximum,
// so it is order-independent, and it refuses any row whose inserted_at will not
// parse rather than guessing a start.
//
// THAT MAXIMUM IS ALSO WHAT MEASURES A DEFERRAL CHAIN FROM ITS START. A chain is
// n separate rows — refusal 1, refusal 2, … — each with its own inserted_at, and
// the newest one is the SHORTEST wait in the chain. Now that siteDeployWaiting
// admits deferred rows, every round of the chain is a candidate and the maximum
// lands on the FIRST refused attempt, which is when the operator actually started
// waiting. Rows at or below the live pointer are still excluded, so a chain that a
// successful deploy already broke does not leak back in — the same reset rule the
// control plane's consecutive_deferrals/2 applies.
//
// It stays a LOWER bound in one more way with deferrals in scope: the page is
// siteStatusLedgerPage rows, so a chain whose start has fallen off the page is
// measured from the oldest round still visible. "At least" is the only claim this
// function ever makes.
func siteWaitingSince(dep *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) (time.Duration, string, bool) {
	waited, row, ok := siteWaitingWorst(dep, ledger)
	if !ok {
		return 0, "", false
	}
	return waited, strings.TrimSpace(row.ID), true
}

// siteWaitingWorst is siteWaitingSince's measurement, returning the ROW rather
// than its id — the renderers need the row itself to say WHY it is waiting (a
// refused round reads differently from a slow build), and re-finding it by id in
// the caller would be a second scan that could disagree with this one.
func siteWaitingWorst(dep *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) (time.Duration, cloudclient.SiteDeployment, bool) {
	now := siteClock()
	var (
		worst    time.Duration
		worstRow cloudclient.SiteDeployment
		found    bool
	)
	for _, r := range sitePendingRows(dep, ledger) {
		ins, ok := siteParseStamp(r.InsertedAt)
		if !ok {
			continue
		}
		waited := now.Sub(ins)
		if waited <= 0 {
			continue
		}
		if !found || waited > worst {
			worst, worstRow, found = waited, r, true
		}
	}
	return worst, worstRow, found
}

// siteWaitingChainHead is the NEWEST refused round among the pending rows — the
// one whose sentence carries the chain's CURRENT depth.
//
// The clock and the depth deliberately come off different rows, because they are
// different facts: the wait started at the first refusal (the oldest row), while
// "how deep am I now" is only true on the latest one. Reading the depth off the
// row the clock was measured from would print "refusal 1 of 12" over a chain four
// rounds deep — an understatement produced by the fix itself.
func siteWaitingChainHead(dep *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) (cloudclient.SiteDeployment, bool) {
	// Newest-first, so the first deferred row in the pending set is the head.
	for _, r := range sitePendingRows(dep, ledger) {
		if siteDeployDeferred(r.Status) {
			return r, true
		}
	}
	return cloudclient.SiteDeployment{}, false
}

// sitePendingRows is the shared scoping rule behind every waiting question: the
// rows on this page that have not reached the web and are NEWER than what is being
// served, in the page's own newest-first order.
//
// It is one function rather than a rule copied per caller on purpose — the clock
// and the chain-depth reader must agree on which rows are "pending", or the header
// can measure one chain and quote another's depth.
func sitePendingRows(dep *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) []cloudclient.SiteDeployment {
	out := make([]cloudclient.SiteDeployment, 0, len(ledger))
	liveIdx := -1
	if dep != nil {
		for i, r := range ledger {
			if strings.EqualFold(strings.TrimSpace(r.ID), strings.TrimSpace(dep.ID)) {
				liveIdx = i
				break
			}
		}
	}
	for i, r := range ledger {
		if !siteDeployWaiting(r.Status) {
			continue
		}
		if dep != nil {
			if strings.EqualFold(strings.TrimSpace(r.ID), strings.TrimSpace(dep.ID)) {
				continue
			}
			switch {
			case liveIdx >= 0:
				// Newest-first: anything at or below the live pointer's index is
				// OLDER than what is serving and cannot be a pending newer revision.
				if i > liveIdx {
					continue
				}
			default:
				// The live pointer is off this page. Fall back to stamps, and when
				// they will not order the pair, KEEP the row: showing a waiter that
				// might be old is the pessimistic direction, and this epic exists to
				// stop erring the other way.
				rt, rok := siteParseStamp(r.InsertedAt)
				dt, dok := siteParseStamp(dep.InsertedAt)
				if rok && dok && !rt.After(dt) {
					continue
				}
			}
		}
		out = append(out, r)
	}
	return out
}

// siteTimeToWebLine is the sentence this epic was founded on — how long it took
// for what you are being served to actually reach the web, and whether anything
// newer is still stuck behind it.
//
// POINTER-SCOPED WORDING, and this is load-bearing rather than style: a rollback
// (cloud/lib/barkpark_cloud/sites/deploy.ex finish_rollback) repoints
// current_deployment_id at an OLDER row WITHOUT restamping became_live_at, so
// "your last publish" would name a build the user never published last. "The build
// you are being served" is true under a rollback, a stale-live pointer and a
// normal deploy alike.
//
// Returns "" when the stamps cannot support a sentence — the row simply gets no
// clock, which is the honest shape of "we do not know".
func siteTimeToWebLine(dep *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) string {
	line := ""
	if dep != nil {
		if ttw, ok := siteTimeToWeb(*dep); ok {
			line = fmt.Sprintf("the build you are being served went live %s after the control plane picked it up (publishes are debounced up to 60s)", siteShortDur(ttw))
		}
	}
	if waited, row, ok := siteWaitingWorst(dep, ledger); ok {
		clause := fmt.Sprintf(
			"a newer revision is still waiting — at least %s so far, measured from the control plane's inserted_at on the OLDEST pending row (not from your publish, which it can understate by up to 60s of debounce)",
			siteShortDur(waited),
		)
		if note := siteWaitingDeferralNote(row, dep, ledger); note != "" {
			clause += " — " + note
		}
		if line == "" {
			return clause
		}
		line += " (" + clause + ")"
	}
	return line
}

// siteWaitingDeferralNote is what the censored wait owes the reader when the row it
// was measured from is a REFUSED round rather than a queued one: the wait is not
// one attempt taking a long time, it is a chain of attempts being turned away.
//
// It leads with the CLOCK, never with the depth, and the ordering is the finding
// rather than taste: the chain is bounded and small (24h p50 depth 3, max 11, wall
// p50 121.6s) while the wait it produces is not, so a header that opened with "3"
// would name the least alarming number on the row. Depth arrives afterwards, as a
// detail, and only ever through siteDeferralLine — which prints it as depth-of-
// fence with what is actually being counted, and which degrades honestly to "this
// control plane does not report how deep the refusal chain is" against a pre-D99
// box. That degraded arm is deliberately kept: a reader that cannot lose cannot be
// believed when it says it has not lost.
//
// No rate is computed here and none may be (charter D174/D142): chains carry no
// key, they are reconstructible only positionally, and the resulting closed-live
// rate is era-unstable (48.4% over 7d vs 28.3% over 24h).
func siteWaitingDeferralNote(measured cloudclient.SiteDeployment, dep *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) string {
	// Only when the wait we just PRINTED is itself a refusal chain. A stranded
	// queued row that happens to share the page with a deferral is a different
	// wait, and describing it as refused would be a lie about the louder number.
	if !siteDeployDeferred(measured.Status) {
		return ""
	}
	head, ok := siteWaitingChainHead(dep, ledger)
	if !ok {
		head = measured
	}
	return "the box REFUSED that round and re-queued a rebuild, so this clock runs from the FIRST refused attempt, not the newest: " + siteDeferralLine(head)
}

// siteFailureClass is the named failure class to show in a status header: the
// newest row's when the newest one failed, else the live row's (which is empty on
// every live row — the control plane classifies failures only).
func siteFailureClass(dep, newest *cloudclient.SiteDeployment) string {
	if newest != nil && siteDeployFailed(newest.Status) {
		if fc := strings.TrimSpace(newest.FailureClass); fc != "" {
			return fc
		}
	}
	if dep != nil {
		return strings.TrimSpace(dep.FailureClass)
	}
	return ""
}

// siteWindow is the WINDOW this status actually read, and the outcomes inside it.
//
// WHY IT EXISTS. `bp cloud site status` is the one deploy surface a site owner
// runs, and it could print six green stage ticks over a stream that was three
// quarters refused: measured on search-capstone, the reachable 200-row window
// (2026-08-07T01:32:34Z → 10:29:17Z) was 148 deferred / 47 live / 5 failed, and
// the header named none of it and named no window over which anyone could
// contest it. A surface that does not print the window it read is already
// mis-reporting, because it invites the reader to generalise a bounded page into
// a site's whole history.
//
// EVERY COUNT SHIPS WITH ITS DENOMINATOR (charter D3) and none of them is a rate:
// the counts are over THIS page, not over the site, and dividing them would
// manufacture a percentage that is era-unstable and unfalsifiable (D174/D142).
// The span is the stamps the page ACTUALLY carried — never siteClock(), never an
// imputed "last 24h" — and rows whose inserted_at will not parse are counted out
// loud rather than silently dropped from the span.
// THE BUCKETS SUM TO Rows, AND THAT IS A CONTRACT, NOT AN ACCIDENT (review, W14).
// The first cut counted deferred/live/failed/waiting and nothing else — so a
// `cancelled` row landed in NO bucket and a reader who subtracted the printed
// counts from the denominator got an unexplained remainder with no name. That is
// the same defect as the unnamed window one layer down: a census that does not
// account for every row it read invites exactly the generalisation it exists to
// stop. `cancelled` is a status this file already names (siteDeployCancelled), so
// it gets its own count; Other is the catch-all for a status word the control
// plane may add tomorrow, printed as "in another state" rather than silently
// dropped. TestSiteWindowAccountsForEveryRowItRead pins the identity.
type siteWindow struct {
	Rows      int
	Deferred  int
	Failed    int
	Live      int
	Waiting   int
	Cancelled int
	Other     int
	Stampless int
	Oldest    string
	Newest    string
	PageFull  bool
	PageLimit int
}

// siteReadWindow measures the page. It reports only what the rows say.
func siteReadWindow(ledger []cloudclient.SiteDeployment) (siteWindow, bool) {
	if len(ledger) == 0 {
		return siteWindow{}, false
	}
	w := siteWindow{Rows: len(ledger), PageLimit: siteStatusLedgerPage, PageFull: len(ledger) >= siteStatusLedgerPage}
	var oldest, newest time.Time
	for _, r := range ledger {
		switch {
		case siteDeployDeferred(r.Status):
			w.Deferred++
		case siteDeployFailed(r.Status):
			w.Failed++
		case strings.EqualFold(strings.TrimSpace(r.Status), "live"):
			w.Live++
		case siteDeployCancelled(r.Status):
			w.Cancelled++
		case siteDeployWaiting(r.Status):
			w.Waiting++
		default:
			w.Other++
		}
		t, ok := siteParseStamp(r.InsertedAt)
		if !ok {
			w.Stampless++
			continue
		}
		if oldest.IsZero() || t.Before(oldest) {
			oldest = t
		}
		if newest.IsZero() || t.After(newest) {
			newest = t
		}
	}
	if !oldest.IsZero() {
		w.Oldest = oldest.Format(time.RFC3339)
		w.Newest = newest.Format(time.RFC3339)
	}
	return w, true
}

// renderSiteWindow prints the census as its OWN block after the KV table.
//
// NOT KV ROWS, and that is mechanical rather than aesthetic: renderKV sorts its
// keys ALPHABETICALLY and pads every key to the widest one, so census rows would
// scatter between `dataset` and `framework` and widen the whole header away from
// the facts it exists to show. `stages:` already established the block shape on
// this surface.
func renderSiteWindow(out *writer, w siteWindow) {
	out.outf("")
	out.outf("recent attempts (the window this status read — not this site's whole history):")
	if w.Oldest != "" {
		out.outf("  %d attempts read, from %s to %s", w.Rows, w.Oldest, w.Newest)
	} else {
		out.outf("  %d attempts read — none of them carried a readable inserted_at, so this window has no span", w.Rows)
	}
	parts := make([]string, 0, 6)
	parts = append(parts, fmt.Sprintf("%d of %d deferred by the box", w.Deferred, w.Rows))
	parts = append(parts, fmt.Sprintf("%d of %d live", w.Live, w.Rows))
	parts = append(parts, fmt.Sprintf("%d of %d failed", w.Failed, w.Rows))
	if w.Waiting > 0 {
		parts = append(parts, fmt.Sprintf("%d of %d still running or queued", w.Waiting, w.Rows))
	}
	// Printed only when non-zero, but never omitted when non-zero: the three
	// headline counts plus these two are exhaustive over the page, so the reader
	// can subtract and land on nothing left over.
	if w.Cancelled > 0 {
		parts = append(parts, fmt.Sprintf("%d of %d cancelled", w.Cancelled, w.Rows))
	}
	if w.Other > 0 {
		parts = append(parts, fmt.Sprintf("%d of %d in another state this CLI does not name", w.Other, w.Rows))
	}
	out.outf("  %s", strings.Join(parts, " · "))
	if w.Stampless > 0 && w.Oldest != "" {
		out.outf("  %d of %d rows carried no readable inserted_at and are outside that span", w.Stampless, w.Rows)
	}
	if w.PageFull {
		out.outf("  the page came back full at %d rows, so older attempts exist that this status did not read", w.PageLimit)
	}
}

// siteWindowMap is the census's `-o json` twin. It is its OWN sibling node, NOT a
// `staleness` key: staleness answers "is what is serving also the last thing that
// happened?" about TWO rows, while this answers "what did I read, and how did it
// go?" about a page — folding them would let a reader threshold a page-scoped
// count as if it were a property of the live pointer.
func siteWindowMap(w siteWindow) map[string]any {
	m := map[string]any{
		"attempts_read":  w.Rows,
		"page_limit":     w.PageLimit,
		"page_full":      w.PageFull,
		"deferred_count": w.Deferred,
		"failed_count":   w.Failed,
		"live_count":     w.Live,
		"waiting_count":  w.Waiting,
		// Always emitted, zero included: a machine reader checks the identity
		// deferred+live+failed+waiting+cancelled+other == attempts_read, and an
		// absent key would make that check unwritable.
		"cancelled_count": w.Cancelled,
		"other_count":     w.Other,
	}
	// Absent, never zero-valued: a span the page could not support must read as
	// unknown, and "1970-01-01" is the most confident lie this node could tell.
	if w.Oldest != "" {
		m["oldest_inserted_at"] = w.Oldest
		m["newest_inserted_at"] = w.Newest
	}
	if w.Stampless > 0 {
		m["attempts_without_a_stamp"] = w.Stampless
	}
	return m
}

// siteStalenessMap is the `-o json` twin of the staleness arm above: the explicit
// comparison, so a script does not have to re-derive "is what is serving also the
// last thing that happened?" by diffing two ids. Emitted only when the newest read
// actually succeeded — an absent node means unknown, never "in sync".
func siteStalenessMap(dep, newest *cloudclient.SiteDeployment, ledger []cloudclient.SiteDeployment) map[string]any {
	m := map[string]any{
		"latest_deployment_id": newest.ID,
		"latest_status":        newest.Status,
	}
	live := ""
	if dep != nil {
		live = dep.ID
		m["live_deployment_id"] = dep.ID
	}
	m["live_is_latest"] = live != "" && strings.EqualFold(live, newest.ID)
	m["latest_failed"] = siteDeployFailed(newest.Status)
	if fc := strings.TrimSpace(newest.FailureClass); fc != "" {
		m["failure_class"] = fc
	}
	// The censored wait, as a NUMBER a script can threshold on — and never as a
	// bare duration. The pair is emitted together on purpose: a lone
	// latest_waiting_seconds reads like a finished measurement, when it is a lower
	// bound on a wait that has not ended. It is the OLDEST waiting row's, so
	// alerting on it cannot be fooled by a fresh re-queue in front of a stranded
	// sibling.
	if waited, row, ok := siteWaitingWorst(dep, ledger); ok {
		id := strings.TrimSpace(row.ID)
		m["latest_waiting_seconds_at_least"] = int64(waited.Seconds())
		m["latest_waiting_censored"] = true
		// WHY it is waiting, for the half of the wait that is now a refusal chain
		// rather than a slow build. The flag is written only on a deferred row —
		// never a `false` on the others, which would read as a measurement the CLI
		// did not make — and the depth pair rides the control plane's own sentence
		// (absent against a pre-D99 box, exactly as in siteDeploymentMap). No rate,
		// no percentage: chains have no key (charter D174/D142).
		if siteDeployDeferred(row.Status) {
			m["latest_waiting_deferred"] = true
			head, hok := siteWaitingChainHead(dep, ledger)
			if !hok {
				head = row
			}
			if depth, bound, dok := siteDeferralChain(head); dok {
				m["latest_waiting_deferral_depth"] = depth
				m["latest_waiting_deferral_bound"] = bound
			}
		}
		// AS-OF, because a censored bound without one is undated arithmetic: the
		// same pinned window was measured returning 3 → 2 → 0 waiters in five
		// minutes (charter D163), so a captured JSON blob carrying only a duration
		// cannot say whether it describes now or an hour ago.
		m["latest_waiting_as_of"] = siteClock().Format(time.RFC3339)
		if id != "" {
			m["latest_waiting_deployment_id"] = id
		}
	}
	return m
}

// siteDeploymentMap is the structured shape of one deployment, stages included.
func siteDeploymentMap(d cloudclient.SiteDeployment) map[string]any {
	stages := make([]map[string]any, 0, len(d.Stages))
	for _, st := range siteStagesInOrder(d) {
		row := map[string]any{"name": st.Name, "status": st.Status}
		if st.Detail != "" {
			row["detail"] = st.Detail
		}
		stages = append(stages, row)
	}
	m := map[string]any{
		"id":     d.ID,
		"status": d.Status,
		"stages": stages,
	}
	if d.SiteID != "" {
		m["site_id"] = d.SiteID
	}
	if d.Stage != "" {
		m["stage"] = d.Stage
	}
	if d.BuildID != "" {
		m["build_id"] = d.BuildID
	}
	if d.URL != "" {
		m["url"] = d.URL
	}
	if d.Trigger != "" {
		m["trigger"] = d.Trigger
	}
	// Node-slot deployment fields (charter D62): the runtime target it ran on and
	// the slot port its process bound — omitted for a static deployment so the JSON
	// stays byte-identical there.
	if d.RuntimeTarget != "" {
		m["runtime_target"] = d.RuntimeTarget
	}
	if d.Port != 0 {
		m["port"] = d.Port
	}
	if d.FailureReason != "" {
		m["failure_reason"] = d.FailureReason
	}
	// deploy-reliability W2: the ledger's named class and the un-humanized capture.
	// A new field costs THREE edits to reach this envelope — the struct, the list
	// decoder, and this map — and skipping any one of them drops it silently.
	if d.FailureClass != "" {
		m["failure_class"] = d.FailureClass
	}
	if d.FailureReasonRaw != "" {
		m["failure_reason_raw"] = d.FailureReasonRaw
	}
	// deploy-reliability W7 (charter D99, PR #9905): the deferral chain, as
	// NUMBERS a script can threshold on rather than a sentence it must grep. Only
	// on a deferred row, and only when the control plane actually said it — a
	// pre-D99 box carries no pair and gets no keys, never a zero that would read
	// as "no chain".
	if siteDeployDeferred(d.Status) {
		if depth, bound, ok := siteDeferralChain(d); ok {
			m["deferral_depth"] = depth
			m["deferral_bound"] = bound
		}
		// deploy-reliability W29: the chain's NAMED cause. It has been decoded
		// since #10248 and emitted NOWHERE — "decode is not readership" on a
		// column populated on 1,332 live rows, so a script could see how deep a
		// chain ran and never WHY. Written only when the control plane sent it.
		if d.DeferralCause != nil {
			if c := strings.TrimSpace(*d.DeferralCause); c != "" {
				m["deferral_cause"] = c
			}
		}
	}
	// deploy-reliability W29 (charter D504): an ABANDONED publish — a chain the
	// control plane GAVE UP on — carries its own depth, bound and cause, under
	// their own key names.
	//
	// NEW KEYS, NOT THE DEFERRAL ONES, and the gate is the class rather than a
	// relaxed siteDeployDeferred. The two facts are semantically OPPOSITE: on a
	// deferred row depth means "refused N times, RE-QUEUED"; here it means
	// "refused N times, WE STOPPED". A dashboard summing one key across both
	// would count a lost publish as a waiting one — the exact confusion
	// TestSiteDeferralChainNotOnFailedRows exists to refuse, and it keeps
	// refusing it.
	//
	// Each key is written only when it is KNOWN. The bound is column-only, so an
	// old row renders depth and cause without it; that gap is the coverage
	// signal, and a zero in its place would be a measurement nobody made.
	if siteDeployAbandoned(d.FailureClass) {
		if depth, ok := siteAbandonmentDepth(d); ok {
			m["abandonment_depth"] = depth
		}
		if bound, ok := siteAbandonmentBound(d); ok {
			m["abandonment_bound"] = bound
		}
		m["abandonment_cause"] = d.FailureClass
	}
	if d.Environment != "" {
		m["environment"] = d.Environment
	}
	if d.Branch != "" {
		m["branch"] = d.Branch
	}
	// deploy-reliability W11: the two clocks the wire has carried all along and
	// this envelope threw away — it shipped 16 keys and not one timestamp, so a
	// script reading `-o json` could see WHAT happened and never WHEN.
	//
	// time_to_web_seconds is ABSENT, never 0, whenever the stamps cannot prove it:
	// a queued row has no became_live_at, and a zero there would read as "went live
	// instantly" — the single most flattering lie this envelope could tell.
	if ins := strings.TrimSpace(d.InsertedAt); ins != "" {
		m["inserted_at"] = ins
	}
	if live := strings.TrimSpace(d.BecameLiveAt); live != "" {
		m["became_live_at"] = live
	}
	if ttw, ok := siteTimeToWeb(d); ok {
		m["time_to_web_seconds"] = int64(ttw.Seconds())
	}
	return m
}

// printCloudSiteHelp writes `bp cloud site` usage.
func printCloudSiteHelp(out *writer) {
	const help = `bp cloud site — spawn a website that builds and serves next to your Barkpark.

USAGE
  bp cloud site ls                                  list your team's sites (alias of 'bp sites')
  bp cloud site create   --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro|nextjs] [--kind static|node] [--doc-type <type>] [--template <starter>] [--theme <palette>] [--deploy]
  bp cloud site deploy    <site> [--prebuilt <dir> [--deployment <id>]] [--no-follow] [--force] [--wait-for-live <deadline>]  (alias: build)
  bp cloud site rollback  <site>
  bp cloud site delete    <site> [--yes]                            tear the site down  (alias: rm)
  bp cloud site status    <site>
  bp cloud site open       <site> [--print-only]
  bp cloud site preflight [--dir <path>] [--skip-build]
  bp cloud site settings  <site> [--theme <palette>] [--doc-type <type>] [--prebuilt-enabled true|false]

  --instance is REQUIRED: a site is spawned on a specific Barkpark instance (it
  builds and serves on that box). List yours with 'bp cloud status'.

  --kind FOLLOWS --framework when you omit it (astro â static, every container
  framework â node), the same derivation the dashboard's create form uses â pass it
  only to override.
  --kind static builds a dist/ tree served as files (Astro). --kind node
  runs a container framework (Next.js first, then nuxt/sveltekit) as a long-running
  SSR process on its own slot port, health-gated behind Caddy.
  --doc-type binds the content type the build reads (default 'post'); pass it
  when your dataset serves another type (e.g. 'paper').
  --template picks a shipped starter tree instead of the framework default:
  astro-starter, next-starter, search-starter (the flagship: finder + corpus
  graph + PortableDoc pages), astro-search-starter. --theme pins the palette
  (evergreen|ember|fjord|charple) â both are also settable later with
  'bp cloud site settings'.
  --wait-for-live <deadline> (e.g. 10m) keeps watching past a DEFERRAL until a
  live deployment for the same site+environment appears, then exits 0; when the
  deadline expires first it exits non-zero, naming the deadline and the last
  status it read. Without it a deferral still exits 0 (nothing is lost — the
  re-queued rebuild carries the same content); this flag is for callers that
  need LIVENESS, e.g. a CD pipeline gating a release on the site serving the
  new bytes.
  --prebuilt <dir> ships a build you already made — the OUTPUT directory (./dist),
  not the project. The serving box runs NO npm for that deploy: it verifies the
  upload's sha256, stages those exact bytes, and BUILD reports skipped. It is two
  calls: bp mints the deployment first and prints the BARKPARK_BUILD_ID /
  BARKPARK_CONTENT_REV / BARKPARK_SITE_BASE your build must be stamped with, then
  uploads. Bytes carrying a different build id are refused BEFORE the upload —
  HEALTH asserts that marker by value — so build with those exports and then ship
  to THAT deployment with --deployment <id>, which the refusal prints for you
  (a prebuilt mint is nonced, so a plain re-run would mint a new id and refuse
  again). Secrets (.env*) and .git are never packed. The site must opt in first:
  bp cloud site settings <site> --prebuilt-enabled true
  --force re-runs a build even when content and config are unchanged — it folds a
  fresh nonce so a new release is minted instead of the cached deployment.
  --deploy on create is the one-motion: it chains straight into the deploy stream
  and ends on the live URL, so create-and-deploy is a single command. If the box is
  still provisioning it says so and points you at 'bp cloud site deploy <site>'.

WHAT IT DOES
  Spawns a site that reads your Barkpark content over the internal link and serves
  from the co-located instance's own Caddy + blue/green + webhook machinery.
  Publish-to-live keeps it fresh as content changes. ONE deploy state machine
  drives TWO runtime targets: static (Astro — the flagship; Hugo and other static
  frameworks on the roadmap) and node-slot SSR (Next.js — the flagship container
  framework; nuxt/sveltekit on the roadmap).

  deploy streams the SIX visible stages — PLAN → BUILD → STAGE → HEALTH →
  SWITCH → RETIRE — health-gated so a broken build never reaches visitors.
  rollback is a sub-second flip to the previous good build: an atomic symlink swap
  for a static site, a Caddy upstream port-flip to the warm previous slot for node.
  preflight catches a broken build on your laptop BEFORE it reaches the box — it
  runs the engine's own --self-test harnesses plus a real npm build + marker scan
  of your site. It is offline and needs no login (see 'bp cloud site preflight -h').

  <site> is a site name or id; needs 'bp login'.

NOT TO BE CONFUSED WITH
  bp cloud deploy / bp cloud rollback  — the blue/green CODE-slot flip of a whole
                                         INSTANCE.
  bp sites / bp deploy                 — the long-running CONTAINER app model.

OUTPUT + EXIT
  a stage-aware human stream; -o json emits the deployment / site envelope.
  0 ok · 1 build failed or cancelled · 2 usage · 3 not logged in · 4 no such site.
  rollback and delete exit-code the control plane's typed refusal: 6 refused (the
  box refused our credential) · 8 the plane or the box failed · 1 anything else,
  each with the plane's own code in the -o json envelope.`
	out.outf("%s", help)
}
