package cli

// cloud_site_cmd.go is `bp cloud site …` — the verb family that spawns a website
// which builds and serves RIGHT NEXT TO Phoenix, reading a Barkpark dataset over
// the internal link and riding the co-located instance's own Caddy + blue/green +
// webhook machinery (cloud-site-spawner charter D10). Astro is the flagship
// (spawnable first); Next.js, TanStack Start, Hugo and others ride the same engine
// on the roadmap.
//
//	bp cloud site create   --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro] [--kind static|node]
//	bp cloud site deploy    <site> [--no-follow]   (alias: build)
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
	"fmt"
	"io"
	"os"
	"path/filepath"
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
		return useError(out, "usage", fmt.Sprintf("unknown site command %q (run `bp cloud site -h` for usage)", verb), exitUsage)
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
	kind := strings.TrimSpace(a.val("kind"))
	if kind == "" {
		kind = "static"
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

	site, cerr := cfg.CloudClient().CreateSpawnSite(cloudCtx(), req)
	if cerr != nil {
		return cloudFail(out, "create site", cerr)
	}

	// --deploy (D19) turns create into the one-motion: on a successful create the CLI
	// chains CLIENT-SIDE straight into the deploy stream and ends on the live URL — no
	// second command, no copy-pasting the ref. Without it, behavior is byte-identical:
	// the create envelope is the whole machine-mode result and the human view prints
	// the `deploy it with …` hint.
	wantDeploy := a.bools["deploy"]

	if !wantDeploy && out.emitStructured(map[string]any{"site": spawnSiteMap(site)}) {
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
	renderSiteCreated(emit, site, req, wantDeploy)
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
func renderSiteCreated(emit func(string, ...any), site cloudclient.SpawnSite, req cloudclient.SpawnSiteCreate, wantDeploy bool) {
	ref := spawnSiteRef(site)
	emit("✓ site %s created — %s build, kind %s",
		hzCell(siteOr(site.Name, req.Name)),
		hzCell(siteOr(site.Framework, req.Framework)),
		hzCell(siteOr(site.Kind, req.Kind)))
	emit("  dataset: %s", siteDatasetClaim(site, req))
	// The bound content type. The record's doc_type is the only thing that says the
	// control plane STORED the binding; echoing req.DocType back would claim a
	// binding nothing confirmed.
	//
	// WHAT THIS LINE MAY NOT SAY. The control plane now READS the binding back at
	// create time (charter D73) and refuses 422 content_binding_empty when the
	// site's own token cannot see the type — so "whether the dataset serves that
	// type is proven by the first deploy, not here" became FALSE the moment that
	// landed. But the verdict rides a top-level `content_binding` key that
	// cloudclient.SpawnSite (the site ROW) does not carry, so this render cannot
	// see it either way. It therefore claims exactly what it holds — the stored
	// row — and names the verdict it is not being shown, rather than narrating
	// someone else's read from memory. Surfacing it is ssw8-surface-the-create-binding-verdict.
	switch {
	case strings.TrimSpace(site.DocType) != "":
		emit("  content: %s (the type stored on the site row; the control plane also checks at create that this site can read it, but that verdict is not in this envelope)", hzCell(site.DocType))
	case strings.TrimSpace(req.DocType) != "":
		emit("  content: %s requested — the control plane echoed no doc type back, so the binding is UNCONFIRMED", hzCell(req.DocType))
	}
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
	return streamSiteDeploy(out, cfg, ref, site.ID, dep, true)
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
	const usage = "bp cloud site deploy <site> [--prebuilt <dir> [--deployment <id>]] [--no-follow] [--force] [--via cloudflare --domain <host>]"
	a, err := parseHzArgs(args, []string{"via", "domain", "prebuilt", "deployment"}, []string{"no-follow", "force"}, usage)
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
	return streamSiteDeploy(out, cfg, ref, id, dep, !a.bools["no-follow"])
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
		if u := strings.TrimSpace(dep.URL); u != "" {
			out.progressf("  export BARKPARK_SITE_BASE=%s", u)
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

	return streamSiteDeploy(out, cfg, ref, id, dep, follow)
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
func streamSiteDeploy(out *writer, cfg *Config, ref, id string, dep cloudclient.SiteDeployment, follow bool) int {
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
			return cloudFail(out, "poll deployment", ferr)
		}
		d = fresh
		render(d)
	}

	if out.emitStructured(map[string]any{"deployment": siteDeploymentMap(d)}) {
		return siteDeployExit(d)
	}
	return renderSiteDeployVerdict(out, ref, d)
}

// renderSiteDeployVerdict is the human verdict on a deployment the stream stopped
// on — the extracted, network-free render the success-claim registry probes. Its
// ONLY input is the deployment record the control plane returned, and the exit
// code it returns is siteDeployExit's contract (a deploy that never went live
// never exits 0).
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
// mode: failed or cancelled → generic, otherwise 0. A deploy that never went live
// must never exit 0 — a script that greps for success would ship a lie.
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
		return cloudFail(out, "roll site back", rberr)
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
		return cloudFail(out, "delete site", derr)
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

	if out.machineOut() {
		payload := map[string]any{"site": spawnSiteMap(site)}
		if dep != nil {
			payload["deployment"] = siteDeploymentMap(*dep)
		}
		out.emitStructured(payload)
		return exitOK
	}

	renderKV(out, spawnSiteStatusMap(site, dep))
	if dep == nil {
		out.outf("")
		out.outf("no deployment yet — kick the first build with `bp cloud site deploy %s`", ref)
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
func spawnSiteStatusMap(s cloudclient.SpawnSite, dep *cloudclient.SiteDeployment) map[string]any {
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
		// A deploy that did not go live owes the reader a reason — the deployment's
		// failure_reason, else the failed stage's streamed detail.
		if strings.EqualFold(dep.Status, "failed") || siteDeployCancelled(dep.Status) {
			_, reason := siteFailure(*dep)
			m["reason"] = sanitizeCell(reason)
		}
	} else {
		m["status"] = "never deployed"
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
	return m
}

// printCloudSiteHelp writes `bp cloud site` usage.
func printCloudSiteHelp(out *writer) {
	const help = `bp cloud site — spawn a website that builds and serves next to your Barkpark.

USAGE
  bp cloud site create   --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro] [--kind static|node] [--doc-type <type>] [--deploy]
  bp cloud site deploy    <site> [--prebuilt <dir> [--deployment <id>]] [--no-follow] [--force]  (alias: build)
  bp cloud site rollback  <site>
  bp cloud site status    <site>
  bp cloud site open       <site> [--print-only]
  bp cloud site preflight [--dir <path>] [--skip-build]
  bp cloud site settings  <site> [--theme <palette>] [--doc-type <type>] [--prebuilt-enabled true|false]

  --instance is REQUIRED: a site is spawned on a specific Barkpark instance (it
  builds and serves on that box). List yours with 'bp cloud status'.

  --kind static (default) builds a dist/ tree served as files (Astro). --kind node
  runs a container framework (Next.js first, then nuxt/sveltekit) as a long-running
  SSR process on its own slot port, health-gated behind Caddy.
  --doc-type binds the content type the build reads (default 'post'); pass it
  when your dataset serves another type (e.g. 'paper').
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
  0 ok · 1 build failed or cancelled · 2 usage · 3 not logged in · 4 no such site.`
	out.outf("%s", help)
}
