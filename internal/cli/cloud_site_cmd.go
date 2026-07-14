package cli

// cloud_site_cmd.go is `bp cloud site …` — the verb family that spawns a website
// which builds and serves RIGHT NEXT TO Phoenix, reading a Barkpark dataset over
// the internal link and riding the co-located instance's own Caddy + blue/green +
// webhook machinery (cloud-site-spawner charter D10). Astro is the flagship
// (spawnable first); Next.js, TanStack Start, Hugo and others ride the same engine
// on the roadmap.
//
//	bp cloud site create   --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro] [--kind static]
//	bp cloud site deploy    <site> [--no-follow]   (alias: build)
//	bp cloud site rollback  <site>
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
//   - `bp cloud site …` operates on a SPAWNED static site — its deploy walks the
//     six visible stages PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE,
//     health-gated so a broken build never reaches visitors, and its rollback is
//     the sub-second symlink flip to the previous good build.
//
// Like every control-plane verb it NEVER writes bp config: it resolves the site
// by name/id via the fleet list and the Cloud session token, exactly like
// `bp cloud rollback` / `bp cloud verify`.

import (
	"fmt"
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
	case "status":
		return runCloudSiteStatus(out, g, rest)
	case "open":
		return runCloudSiteOpen(out, g, rest)
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
	const usage = "bp cloud site create --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro] [--kind static] [--doc-type <type>]"
	a, err := parseHzArgs(args, []string{"name", "dataset", "framework", "kind", "instance", "doc-type"}, nil, usage)
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
	ws, proj, ds, derr := parseDatasetTriple(a.val("dataset"))
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
	}

	site, cerr := cfg.CloudClient().CreateSpawnSite(cloudCtx(), req)
	if cerr != nil {
		return cloudFail(out, "create site", cerr)
	}

	if out.emitStructured(map[string]any{"site": spawnSiteMap(site)}) {
		return exitOK
	}
	ref := spawnSiteRef(site)
	out.outf("✓ site %s created — %s build, kind %s", hzCell(site.Name), hzCell(siteOr(site.Framework, framework)), hzCell(siteOr(site.Kind, kind)))
	out.outf("  dataset: %s", siteDatasetLabel(site, ws, proj, ds))
	if req.DocType != "" {
		out.outf("  content: %s docs", hzCell(req.DocType))
	}
	if u := spawnSiteURL(site); u != "" {
		out.outf("  url:     %s (live after the first deploy)", u)
	}
	if framework != "astro" {
		out.outf("  note:    astro is the flagship framework; %q rides the same engine on the roadmap and may not build yet", framework)
	}
	out.outf("  deploy it with `bp cloud site deploy %s`", ref)
	return exitOK
}

// runCloudSiteDeploy is `bp cloud site deploy <site>` (alias `build`) — enqueue a
// build, then stream the six visible stages until the deploy lands or fails.
func runCloudSiteDeploy(out *writer, g globals, args []string) int {
	const usage = "bp cloud site deploy <site> [--no-follow] [--force]"
	a, err := parseHzArgs(args, nil, []string{"no-follow", "force"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <site> (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, ok := siteCloudConfig(out, "deploy a site")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	dep, derr := cfg.CloudClient().DeploySpawnSite(cloudCtx(), id, a.bools["force"])
	if derr != nil {
		return cloudFail(out, "deploy site", derr)
	}
	return streamSiteDeploy(out, cfg, ref, id, dep, !a.bools["no-follow"])
}

// streamSiteDeploy renders the deploy as a stage-aware progress stream: each
// completed stage is printed once, in order, then polls the deployment until it
// reaches a terminal state (live / failed / cancelled). Progress rides progressf so
// `-o json` keeps stdout a single envelope; the final deployment is the return value.
func streamSiteDeploy(out *writer, cfg *Config, ref, id string, dep cloudclient.SiteDeployment, follow bool) int {
	if b := strings.TrimSpace(dep.BuildID); b != "" {
		out.progressf("→ deploy queued for %s (build %s)", ref, sanitizeCell(b))
	} else {
		out.progressf("→ deploy queued for %s", ref)
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
		if u := siteOr(d.URL, ""); u != "" {
			out.outf("✓ site live — %s", u)
		} else {
			out.outf("✓ site live")
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
	if dep := strings.TrimSpace(res.DeploymentID); dep != "" {
		out.outf("✓ site rolled back — %s is now serving deployment %s.", ref, sanitizeCell(dep))
	} else {
		out.outf("✓ site rolled back — %s is now serving its previous build.", ref)
	}
	if prev := strings.TrimSpace(res.PreviousDeploymentID); prev != "" {
		out.outf("  was: %s", sanitizeCell(prev))
	}
	out.outf("  the flip is an atomic symlink swap (sub-second) — a broken build never reached visitors, and this reverses it instantly.")
	if u := strings.TrimSpace(res.URL); u != "" {
		out.outf("  url: %s", sanitizeCell(u))
	}
	return exitOK
}

// runCloudSiteStatus is `bp cloud site status <site>` — the current deployment +
// its stage. Honest empty state when the site has never deployed.
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
	if u := spawnSiteURL(s); u != "" {
		m["url"] = u
	}
	if dep != nil {
		m["deployment"] = hzCell(dep.ID)
		m["status"] = hzCell(dep.Status)
		if st := strings.TrimSpace(dep.Stage); st != "" {
			m["stage"] = st
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
	if d.FailureReason != "" {
		m["failure_reason"] = d.FailureReason
	}
	return m
}

// printCloudSiteHelp writes `bp cloud site` usage.
func printCloudSiteHelp(out *writer) {
	const help = `bp cloud site — spawn a website that builds and serves next to your Barkpark.

USAGE
  bp cloud site create   --name <n> --dataset <ws/proj/ds> --instance <id|name> [--framework astro] [--kind static] [--doc-type <type>]
  bp cloud site deploy    <site> [--no-follow] [--force]      (alias: build)
  bp cloud site rollback  <site>
  bp cloud site status    <site>
  bp cloud site open       <site> [--print-only]

  --instance is REQUIRED: a site is spawned on a specific Barkpark instance (it
  builds and serves on that box). List yours with 'bp cloud status'.

  --doc-type binds the content type the build reads (default 'post'); pass it
  when your dataset serves another type (e.g. 'paper').
  --force re-runs a build even when content and config are unchanged — it folds a
  fresh nonce so a new release is minted instead of the cached deployment.

WHAT IT DOES
  Spawns a static site (Astro is the flagship; Next.js, TanStack Start, Hugo and
  others ride the same engine on the roadmap) that reads your Barkpark content
  over the internal link and serves from the co-located instance's own Caddy +
  blue/green + webhook machinery. Publish-to-live keeps it fresh as content
  changes.

  deploy streams the SIX visible stages — PLAN → BUILD → STAGE → HEALTH →
  SWITCH → RETIRE — health-gated so a broken build never reaches visitors.
  rollback is the sub-second symlink flip to the previous good build.

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
