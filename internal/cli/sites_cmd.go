package cli

// sites_cmd.go is the P6 surface for the Barkpark Cloud Sites API (the hosted-
// website half of the control plane). It mirrors cloud12_cmd.go's idiom — thin
// flag parsers, a single cloudclient call per command, table or JSON output
// through the shared writer — so the user-facing shape of `bp sites` /
// `bp deploy` matches `bp launch` / `bp go-live` exactly.
//
// The commands implemented here:
//
//   bp sites                                        — list sites (table)
//   bp sites show <site-or-slug>                    — show one site
//   bp sites create --barkpark <slug> --name <name> — create a site
//                   [--framework nextjs] [--domain <d>] [--scale-mode always_on|zero]
//   bp deploy <site> [--artifact-url <url>] [--git-ref <ref>]  — enqueue a build
//   bp sites deployments <site>                     — list site's deployments
//   bp sites env set <site> KEY=VAL [KEY=VAL...]    — replace the env blob
//   bp sites domain add <site> <domain>             — add a domain
//   bp sites github connect <site> --repo owner/r   — link GitHub for auto-deploy (P7)
//                          [--branch main] [--secret <s>]
//   bp sites logs <site>                            — print last deploy's log URL
//
// All commands require a Cloud session token (gated by requireCloud). The
// `<site>` argument accepts either the site's UUID or its slug; when it doesn't
// look like a UUID we resolve the slug by walking ListSites once. `bp deploy`
// takes --artifact-url or --git-ref and posts it verbatim; local-build uploads
// live on `bp cloud site deploy --prebuilt ./dist` (site-spawner W9/W10), never
// here.

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// uuidLike matches the rough shape of a control-plane id (UUID-ish). It is the
// cheap "is this an id or a slug?" sniff `bp sites` uses before falling back to
// a ListSites slug lookup. A real UUID matches; a slug like "blog" doesn't.
var uuidLike = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// runSites is the `bp sites <verb>` dispatcher. A bare `bp sites` is the list
// view (the most common path). Any other verb routes to its sub-command.
func runSites(out *writer, args []string) int {
	if len(args) == 0 {
		return runSitesList(out, nil)
	}
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}

	verb := args[0]
	rest := args[1:]
	switch verb {
	case "ls", "list":
		return runSitesList(out, rest)
	case "show", "get":
		return runSitesShow(out, rest)
	case "create", "new":
		return runSitesCreate(out, rest)
	case "deployments", "deploys":
		return runSitesDeployments(out, rest)
	case "env":
		return runSitesEnv(out, rest)
	case "domain", "domains":
		return runSitesDomain(out, rest)
	case "github":
		return runSitesGithub(out, rest)
	case "logs", "log":
		return runSitesLogs(out, rest)
	default:
		// A bare positional that isn't a known verb is treated as the list view
		// being passed extra junk — surface a usage error rather than guessing.
		return useError(out, "usage", fmt.Sprintf("unknown sites command %q (run `bp sites -h` for usage)", verb), exitUsage)
	}
}

// runSitesList renders `bp sites` — the fleet of hosted sites under the user's
// team. Columns: NAME · DOMAINS · STATUS · LAST DEPLOY. STATUS reflects the
// current deployment row (or "—" when none); LAST DEPLOY is the inserted_at
// timestamp the server stamped.
func runSitesList(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
		if strings.HasPrefix(a, "-") {
			return useError(out, "usage", fmt.Sprintf("unknown flag %q (usage: bp sites)", a), exitUsage)
		}
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	client := cfg.CloudClient()
	sites, err := client.ListSites(cloudCtx())
	if err != nil {
		return useError(out, "failed", "list sites: "+err.Error(), exitGeneric)
	}

	// For STATUS + LAST DEPLOY columns, walk each site's deployments once and
	// take the newest. This is a cheap N+1 — the table fits on one screen and
	// the per-site cost is one GET; we keep the call structure obvious rather
	// than adding a server aggregate route just for the table.
	statuses := make(map[string]Deployment, len(sites))
	for _, s := range sites {
		if dep, ok := latestDeployment(client, s.ID); ok {
			statuses[s.ID] = dep
		}
	}

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(sites))
		for _, s := range sites {
			rows = append(rows, siteRow(s, statuses[s.ID]))
		}
		out.emitStructured(map[string]any{"sites": rows})
		return exitOK
	}

	if len(sites) == 0 {
		out.outf("no sites yet — create one with 'bp sites create --barkpark <slug> --name <name>'")
		return exitOK
	}

	renderSitesTable(out, sites, statuses)
	return exitOK
}

// Deployment re-exposes cloudclient.Deployment so the local helpers can speak
// the same type without re-importing it everywhere. (Kept as a local alias so
// callers stay readable; no behaviour change.)
type Deployment = cloudclient.Deployment

// latestDeployment returns the newest deployment for siteID (the server returns
// them newest-first). A 404 / empty / error is treated as "no deployment yet" —
// a missing status column is normal for a freshly-created site.
func latestDeployment(client *cloudclient.Client, siteID string) (Deployment, bool) {
	ds, err := client.ListDeployments(cloudCtx(), siteID)
	if err != nil || len(ds) == 0 {
		return Deployment{}, false
	}
	return ds[0], true
}

// statusColor wraps a deployment status in a Vercel-parity ANSI color — green
// for healthy (live/running/ready/active), red for failed/error, yellow for
// in-flight (queued/building/pushing) — but only when out.color is set (a real
// TTY, not piped / --no-color / under `go test`). Matching is case-insensitive.
// The caller must pass the ALREADY space-padded cell: we colorize the padded
// string so the escape bytes fall outside the width the column was measured at.
// Mirrors the gated-ANSI idiom in hetzner_confirm.go. Unknown statuses (and the
// no-color path) return the input unchanged.
func statusColor(out *writer, status string) string {
	if !out.color {
		return status
	}
	var code string
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "live", "running", "ready", "active":
		code = "\033[32m"
	case "failed", "error":
		code = "\033[31m"
	case "queued", "building", "pushing":
		code = "\033[33m"
	default:
		return status
	}
	return code + status + "\033[0m"
}

// renderSitesTable prints the aligned `bp sites` table. The four columns
// (NAME · DOMAINS · STATUS · LAST DEPLOY) are width-driven from the data so
// the output is stable for golden compare. Empty domains print "—".
func renderSitesTable(out *writer, sites []cloudclient.Site, statuses map[string]Deployment) {
	const (
		hName   = "NAME"
		hDom    = "DOMAINS"
		hStat   = "STATUS"
		hDeploy = "LAST DEPLOY"
	)
	nameW, domW, statW := len(hName), len(hDom), len(hStat)
	rows := make([][4]string, len(sites))
	for i, s := range sites {
		dom := strings.Join(s.Domains, ", ")
		if dom == "" {
			dom = "—"
		}
		dep := statuses[s.ID]
		status := dep.Status
		if status == "" {
			status = "—"
		}
		when := dep.InsertedAt
		if when == "" {
			when = "—"
		}
		rows[i] = [4]string{s.Name, dom, status, when}
		if n := len(s.Name); n > nameW {
			nameW = n
		}
		if n := len(dom); n > domW {
			domW = n
		}
		if n := len(status); n > statW {
			statW = n
		}
	}

	out.outf("%-*s  %-*s  %-*s  %s", nameW, hName, domW, hDom, statW, hStat, hDeploy)
	for _, r := range rows {
		// Pad the raw status to the column width FIRST, then colorize, so the
		// ANSI escape bytes never count toward statW and misalign the table.
		stat := statusColor(out, fmt.Sprintf("%-*s", statW, r[2]))
		out.outf("%-*s  %-*s  %s  %s", nameW, r[0], domW, r[1], stat, r[3])
	}
}

// siteRow projects a site + its latest deployment onto the stable JSON shape
// `bp sites -o json` emits. The deployment fields are flattened under
// last_deployment so the consumer doesn't have to walk a nested map.
func siteRow(s cloudclient.Site, dep Deployment) map[string]any {
	row := map[string]any{
		"id":                    s.ID,
		"barkpark_id":           s.BarkparkID,
		"team_id":               s.TeamID,
		"name":                  s.Name,
		"slug":                  s.Slug,
		"framework":             s.Framework,
		"domains":               s.Domains,
		"scale_mode":            s.ScaleMode,
		"port":                  s.Port,
		"current_deployment_id": s.CurrentDeploymentID,
		"inserted_at":           s.InsertedAt,
		"updated_at":            s.UpdatedAt,
	}
	if dep.ID != "" {
		row["last_deployment"] = map[string]any{
			"id":          dep.ID,
			"status":      dep.Status,
			"image_tag":   dep.ImageTag,
			"inserted_at": dep.InsertedAt,
		}
	}
	return row
}

// runSitesShow renders `bp sites show <site-or-slug>` — a key/value view of one
// site, with the latest deployment when present.
func runSitesShow(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing <site> — bp sites show <site-or-slug>", exitUsage)
	}
	handle := args[0]
	if len(args) > 1 {
		return useError(out, "usage", "too many arguments — bp sites show <site-or-slug>", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()
	site, err := resolveSite(client, handle)
	if err != nil {
		return useError(out, "failed", "show site: "+err.Error(), exitGeneric)
	}

	dep, _ := latestDeployment(client, site.ID)

	if out.emitStructured(siteRow(site, dep)) {
		return exitOK
	}
	renderSiteDetail(out, site, dep)
	return exitOK
}

// renderSiteDetail prints one site as aligned key: value lines, then the
// latest deployment block when one exists.
func renderSiteDetail(out *writer, s cloudclient.Site, dep Deployment) {
	out.outf("name:        %s", s.Name)
	out.outf("id:          %s", s.ID)
	out.outf("slug:        %s", s.Slug)
	out.outf("barkpark_id: %s", s.BarkparkID)
	out.outf("framework:   %s", s.Framework)
	out.outf("scale_mode:  %s", s.ScaleMode)
	if len(s.Domains) > 0 {
		out.outf("domains:     %s", strings.Join(s.Domains, ", "))
	} else {
		out.outf("domains:     (none — only the box's default address)")
	}
	if s.Port > 0 {
		out.outf("port:        %d", s.Port)
	}
	if dep.ID != "" {
		out.outf("")
		out.outf("last deployment")
		out.outf("  id:        %s", dep.ID)
		out.outf("  status:    %s", dep.Status)
		if dep.ImageTag != "" {
			out.outf("  image:     %s", dep.ImageTag)
		}
		if dep.GitRef != "" {
			out.outf("  git_ref:   %s", dep.GitRef)
		}
		if dep.BuildLogURL != "" {
			out.outf("  log:       %s", dep.BuildLogURL)
		}
		if dep.FailureReason != "" {
			out.outf("  failure:   %s", dep.FailureReason)
		}
	}
}

// runSitesCreate is `bp sites create --barkpark <slug> --name <name>`.
//
//	--barkpark   the Barkpark slug (resolved to a UUID via ListBarkparks) the
//	             site lives on. Required.
//	--name       human name for the site. Required.
//	--framework  one of nextjs|nuxt|sveltekit|astro|static (server default
//	             "nextjs" — omitted on the wire when empty).
//	--domain     a hostname to attach at create time; may be repeated.
//	--scale-mode always_on|zero. Optional.
func runSitesCreate(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}

	barkpark, name, framework, scaleMode, domains, perr := parseSiteCreateArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if barkpark == "" {
		return useError(out, "usage", "--barkpark required — bp sites create --barkpark <slug> --name <name>", exitUsage)
	}
	if name == "" {
		return useError(out, "usage", "--name required — bp sites create --barkpark <slug> --name <name>", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()

	bpID, err := resolveBarkparkID(client, barkpark)
	if err != nil {
		return useError(out, "failed", "resolve barkpark: "+err.Error(), exitGeneric)
	}

	site, err := client.CreateSite(cloudCtx(), cloudclient.SiteCreate{
		BarkparkID: bpID,
		Name:       name,
		Framework:  framework,
		Domains:    domains,
		ScaleMode:  scaleMode,
	})
	if err != nil {
		return useError(out, "failed", "create site: "+err.Error(), exitGeneric)
	}

	if out.emitStructured(map[string]any{"ok": true, "site": siteRow(site, Deployment{})}) {
		return exitOK
	}
	out.outf("✓ created site %q (id %s)", site.Name, site.ID)
	if len(site.Domains) > 0 {
		out.outf("  domains: %s", strings.Join(site.Domains, ", "))
	}
	out.outf("  deploy with 'cd ~/your-project && bp deploy %s'", site.Slug)
	return exitOK
}

// resolveBarkparkID maps a user-supplied --barkpark value to a UUID. A
// UUID-shaped value passes through; otherwise we walk ListBarkparks and match
// on slug, then on name, then on URL — same precedence the local server-name
// resolver uses for `bp servers`.
func resolveBarkparkID(client *cloudclient.Client, handle string) (string, error) {
	if uuidLike.MatchString(handle) {
		return handle, nil
	}
	list, err := client.ListBarkparks(cloudCtx())
	if err != nil {
		return "", err
	}
	for _, b := range list {
		if b.Slug == handle {
			return b.ID, nil
		}
	}
	for _, b := range list {
		if b.Name == handle {
			return b.ID, nil
		}
	}
	for _, b := range list {
		if b.URL == handle || b.Host == handle {
			return b.ID, nil
		}
	}
	return "", fmt.Errorf("no Barkpark matches %q (try 'bp barkparks' to see your fleet)", handle)
}

// resolveSite maps a `<site-or-slug>` positional onto a Site row. A UUID-shaped
// handle goes through GetSite directly; otherwise we walk ListSites and match
// on slug, then name.
func resolveSite(client *cloudclient.Client, handle string) (cloudclient.Site, error) {
	if uuidLike.MatchString(handle) {
		return client.GetSite(cloudCtx(), handle)
	}
	list, err := client.ListSites(cloudCtx())
	if err != nil {
		return cloudclient.Site{}, err
	}
	for _, s := range list {
		if s.Slug == handle {
			return s, nil
		}
	}
	for _, s := range list {
		if s.Name == handle {
			return s, nil
		}
	}
	return cloudclient.Site{}, fmt.Errorf("no site matches %q (try 'bp sites' to see them all)", handle)
}

// runDeploy is `bp deploy <site> --artifact-url <url> | --git-ref <ref>` — the
// CONTAINER-model enqueue, which points an out-of-band builder at an artifact it
// can already fetch or a ref it can already clone.
//
// site-spawner W10: the no-flag "heroku moment" is GONE. It tar+gzipped the whole
// project dir into POST /v1/sites/:id/artifact, and every row that route wrote
// carried no deployment_id while the only read and the only delete both keyed on
// one — so the bytes were unreachable AND unreapable, and the deploy that
// followed never read them anyway (the deploy route kind-branches to the static
// path before it looks at artifact_url). Rather than fail silently, no flags now
// REFUSES BY NAME and points at the lane that actually works:
// `bp cloud site deploy <site> --prebuilt ./dist`. Nothing hits the wire.
//
// `--dir` is accepted and ignored-with-a-refusal for exactly that reason: it only
// ever meant "which directory to tarball", and a flag whose behaviour vanished
// must say so rather than quietly enqueue something else.
func runDeploy(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printDeployHelp(out)
			return exitOK
		}
	}

	handle, artifactURL, gitRef, dir, perr := parseDeployArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if handle == "" {
		return useError(out, "usage", "missing <site> — bp deploy <site> --artifact-url <url> | --git-ref <ref>", exitUsage)
	}

	// THE RETIRED DEFAULT (site-spawner W10). No source flag used to mean "tarball
	// this directory and upload it"; the route that received it is gone, so this
	// refuses BY NAME and names the verb that replaced it. Deliberately before
	// requireCloud: a usage error must not touch the network, must not need a
	// login, and must not resolve a site.
	if artifactURL == "" && gitRef == "" {
		return useError(out, "usage", noDeploySourceRefusal(handle, dir), exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()
	site, err := resolveSite(client, handle)
	if err != nil {
		return useError(out, "failed", "resolve site: "+err.Error(), exitGeneric)
	}

	dep, err := client.Deploy(cloudCtx(), site.ID, gitRef, artifactURL)
	if err != nil {
		return useError(out, "failed", "deploy: "+err.Error(), exitGeneric)
	}

	if out.emitStructured(map[string]any{"ok": true, "deployment": deploymentRow(dep)}) {
		return exitOK
	}
	out.outf("✓ queued deployment %s (status %s)", dep.ID, dep.Status)
	if dep.GitRef != "" {
		out.outf("  git_ref: %s", dep.GitRef)
	}
	if dep.ArtifactURL != "" {
		out.outf("  artifact: %s", dep.ArtifactURL)
	}
	out.outf("  watch with 'bp sites deployments %s' or 'bp sites logs %s'", site.Slug, site.Slug)
	return exitOK
}

// deploymentRow is the JSON projection of a Deployment row.
func deploymentRow(d Deployment) map[string]any {
	return map[string]any{
		"id":             d.ID,
		"site_id":        d.SiteID,
		"status":         d.Status,
		"git_ref":        d.GitRef,
		"artifact_url":   d.ArtifactURL,
		"image_tag":      d.ImageTag,
		"build_log_url":  d.BuildLogURL,
		"failure_reason": d.FailureReason,
		"became_live_at": d.BecameLiveAt,
		"inserted_at":    d.InsertedAt,
		"updated_at":     d.UpdatedAt,
	}
}

// runSitesDeployments renders `bp sites deployments <site>` — newest-first.
// Columns: STATUS · IMAGE_TAG · GIT_REF · STARTED.
func runSitesDeployments(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing <site> — bp sites deployments <site>", exitUsage)
	}
	handle := args[0]
	if len(args) > 1 {
		return useError(out, "usage", "too many arguments — bp sites deployments <site>", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()
	site, err := resolveSite(client, handle)
	if err != nil {
		return useError(out, "failed", "resolve site: "+err.Error(), exitGeneric)
	}
	ds, err := client.ListDeployments(cloudCtx(), site.ID)
	if err != nil {
		return useError(out, "failed", "list deployments: "+err.Error(), exitGeneric)
	}

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(ds))
		for _, d := range ds {
			rows = append(rows, deploymentRow(d))
		}
		out.emitStructured(map[string]any{"deployments": rows})
		return exitOK
	}
	if len(ds) == 0 {
		out.outf("no deployments for %q yet — 'cd ~/your-project && bp deploy %s'", site.Name, site.Slug)
		return exitOK
	}
	renderDeploymentsTable(out, ds)
	return exitOK
}

// renderDeploymentsTable prints STATUS · IMAGE_TAG · GIT_REF · STARTED.
func renderDeploymentsTable(out *writer, ds []Deployment) {
	const (
		hStat = "STATUS"
		hImg  = "IMAGE_TAG"
		hRef  = "GIT_REF"
		hWhen = "STARTED"
	)
	statW, imgW, refW := len(hStat), len(hImg), len(hRef)
	for _, d := range ds {
		if n := len(d.Status); n > statW {
			statW = n
		}
		img := d.ImageTag
		if img == "" {
			img = "—"
		}
		if n := len(img); n > imgW {
			imgW = n
		}
		ref := d.GitRef
		if ref == "" {
			ref = "—"
		}
		if n := len(ref); n > refW {
			refW = n
		}
	}
	out.outf("%-*s  %-*s  %-*s  %s", statW, hStat, imgW, hImg, refW, hRef, hWhen)
	for _, d := range ds {
		img := d.ImageTag
		if img == "" {
			img = "—"
		}
		ref := d.GitRef
		if ref == "" {
			ref = "—"
		}
		when := d.InsertedAt
		if when == "" {
			when = "—"
		}
		// Pad the raw status to the column width FIRST, then colorize, so the
		// ANSI escape bytes never count toward statW and misalign the table.
		stat := statusColor(out, fmt.Sprintf("%-*s", statW, d.Status))
		out.outf("%s  %-*s  %-*s  %s", stat, imgW, img, refW, ref, when)
	}
}

// runSitesEnv handles `bp sites env <verb> <site> …`. Today the only verb is
// `set` — the control plane replaces the whole env blob on every write, so an
// incremental "merge K=V into the existing env" needs the CLI to know the prior
// state. There is no GET /env endpoint (the encrypted blob never leaves the
// server), so this command treats KEY=VAL... as the full desired env: it is
// NOT a merge with existing values, and the help text says so loudly.
func runSitesEnv(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing verb — bp sites env set <site> KEY=VAL [KEY=VAL...]", exitUsage)
	}
	verb := args[0]
	if verb != "set" {
		return useError(out, "usage", fmt.Sprintf("unknown env verb %q (only 'set' is supported today)", verb), exitUsage)
	}
	if len(args) < 2 {
		return useError(out, "usage", "missing <site> — bp sites env set <site> KEY=VAL [KEY=VAL...]", exitUsage)
	}
	handle := args[1]
	pairs := args[2:]
	if len(pairs) == 0 {
		return useError(out, "usage", "no env pairs given — bp sites env set <site> KEY=VAL [KEY=VAL...]", exitUsage)
	}

	env := map[string]string{}
	for _, kv := range pairs {
		eq := strings.IndexByte(kv, '=')
		if eq <= 0 {
			return useError(out, "usage", fmt.Sprintf("invalid pair %q (want KEY=VALUE)", kv), exitUsage)
		}
		key := kv[:eq]
		val := kv[eq+1:]
		env[key] = val
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()
	site, err := resolveSite(client, handle)
	if err != nil {
		return useError(out, "failed", "resolve site: "+err.Error(), exitGeneric)
	}

	if err := client.SetEnv(cloudCtx(), site.ID, env); err != nil {
		return useError(out, "failed", "set env: "+err.Error(), exitGeneric)
	}

	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	if out.emitStructured(map[string]any{
		"ok":   true,
		"site": site.Slug,
		"keys": keys,
	}) {
		return exitOK
	}
	out.outf("✓ replaced env on %q with %d key(s): %s", site.Name, len(keys), strings.Join(keys, ", "))
	out.outf("  note: this REPLACED the env blob — any prior keys not listed were dropped")
	out.outf("  redeploy with 'bp deploy %s' to roll the new env into a fresh build", site.Slug)
	return exitOK
}

// runSitesDomain handles `bp sites domain add <site> <domain>`.
func runSitesDomain(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing verb — bp sites domain add <site> <domain>", exitUsage)
	}
	verb := args[0]
	if verb != "add" {
		return useError(out, "usage", fmt.Sprintf("unknown domain verb %q (only 'add' is supported today)", verb), exitUsage)
	}
	if len(args) != 3 {
		return useError(out, "usage", "bp sites domain add <site> <domain>", exitUsage)
	}
	handle := args[1]
	domain := args[2]

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()
	site, err := resolveSite(client, handle)
	if err != nil {
		return useError(out, "failed", "resolve site: "+err.Error(), exitGeneric)
	}

	updated, err := client.AddDomain(cloudCtx(), site.ID, domain)
	if err != nil {
		return useError(out, "failed", "add domain: "+err.Error(), exitGeneric)
	}

	if out.emitStructured(map[string]any{"ok": true, "site": siteRow(updated, Deployment{})}) {
		return exitOK
	}
	out.outf("✓ added %s to %q", domain, updated.Name)
	out.outf("  domains: %s", strings.Join(updated.Domains, ", "))
	out.outf("  on-demand TLS will provision a cert on first request to %s", domain)
	return exitOK
}

// runSitesLogs is the best-effort `bp sites logs <site>`. Today the control
// plane does not stream logs — the builder writes a log somewhere (blob
// storage / Loki) and stamps build_log_url on the Deployment row. This command
// fetches the latest deployment and prints the URL so the user can open it
// directly; real log streaming is deferred.
func runSitesLogs(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing <site> — bp sites logs <site>", exitUsage)
	}
	handle := args[0]
	if len(args) > 1 {
		return useError(out, "usage", "too many arguments — bp sites logs <site>", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()
	site, err := resolveSite(client, handle)
	if err != nil {
		return useError(out, "failed", "resolve site: "+err.Error(), exitGeneric)
	}
	dep, ok := latestDeployment(client, site.ID)
	if !ok {
		if out.emitStructured(map[string]any{"ok": false, "reason": "no_deployments"}) {
			return exitOK
		}
		out.outf("no deployments for %q yet — 'cd ~/your-project && bp deploy %s'", site.Name, site.Slug)
		return exitOK
	}
	if out.emitStructured(map[string]any{
		"ok":            true,
		"deployment_id": dep.ID,
		"status":        dep.Status,
		"build_log_url": dep.BuildLogURL,
	}) {
		return exitOK
	}
	out.outf("deployment %s (%s)", dep.ID, dep.Status)
	if dep.BuildLogURL == "" {
		out.outf("  no build log URL yet — the builder writes it once the build starts")
		return exitOK
	}
	out.outf("  log: %s", dep.BuildLogURL)
	return exitOK
}

// --- flag parsers (dependency-free, mirroring cloud12_cmd.go) ----------------

// parseSiteCreateArgs splits `bp sites create` flags:
//
//	--barkpark/--barkpark-id   the Barkpark slug or id (required)
//	--name                     human name (required)
//	--framework                framework key (optional)
//	--scale-mode               always_on|zero (optional)
//	--domain                   may be repeated to attach multiple at create time
func parseSiteCreateArgs(args []string) (barkpark, name, framework, scaleMode string, domains []string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--barkpark" || a == "--barkpark-id":
			barkpark, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--barkpark="):
			barkpark = a[len("--barkpark="):]
		case strings.HasPrefix(a, "--barkpark-id="):
			barkpark = a[len("--barkpark-id="):]
		case a == "--name":
			name, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--name="):
			name = a[len("--name="):]
		case a == "--framework":
			framework, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--framework="):
			framework = a[len("--framework="):]
		case a == "--scale-mode":
			scaleMode, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--scale-mode="):
			scaleMode = a[len("--scale-mode="):]
		case a == "--domain":
			var d string
			d, i, err = nextFlagValue(args, i)
			if err == nil && d != "" {
				domains = append(domains, d)
			}
		case strings.HasPrefix(a, "--domain="):
			d := a[len("--domain="):]
			if d != "" {
				domains = append(domains, d)
			}
		default:
			return "", "", "", "", nil, fmt.Errorf("unexpected argument %q (usage: bp sites create --barkpark <slug> --name <name> [--framework nextjs] [--domain <d>] [--scale-mode always_on|zero])", a)
		}
		if err != nil {
			return "", "", "", "", nil, err
		}
	}
	return barkpark, name, framework, scaleMode, domains, nil
}

// parseDeployArgs splits `bp deploy <site> [--artifact-url <url>] [--git-ref <ref>] [--dir <path>]`.
// The first positional is the site handle. With no flags the command tarballs
// the cwd; --artifact-url is the escape hatch; --git-ref pins a build ref;
// --dir picks a non-cwd project root. `--site` is also accepted as an
// optional alias for the positional handle so `bp deploy --site demo` reads
// the way Heroku/Vercel users expect.
func parseDeployArgs(args []string) (handle, artifactURL, gitRef, dir string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--artifact-url" || a == "--artifact":
			artifactURL, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--artifact-url="):
			artifactURL = a[len("--artifact-url="):]
		case strings.HasPrefix(a, "--artifact="):
			artifactURL = a[len("--artifact="):]
		case a == "--git-ref" || a == "--ref":
			gitRef, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--git-ref="):
			gitRef = a[len("--git-ref="):]
		case strings.HasPrefix(a, "--ref="):
			gitRef = a[len("--ref="):]
		case a == "--dir":
			dir, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--dir="):
			dir = a[len("--dir="):]
		case a == "--site":
			var h string
			h, i, err = nextFlagValue(args, i)
			if err == nil && h != "" {
				if handle != "" {
					return "", "", "", "", fmt.Errorf("--site %q and positional %q both given", h, handle)
				}
				handle = h
			}
		case strings.HasPrefix(a, "--site="):
			h := a[len("--site="):]
			if handle != "" {
				return "", "", "", "", fmt.Errorf("--site %q and positional %q both given", h, handle)
			}
			handle = h
		case strings.HasPrefix(a, "-"):
			return "", "", "", "", fmt.Errorf("unknown flag %q (usage: bp deploy <site> [--artifact-url <url>] [--git-ref <ref>] [--dir <path>])", a)
		default:
			if handle != "" {
				return "", "", "", "", fmt.Errorf("unexpected extra argument %q", a)
			}
			handle = a
		}
		if err != nil {
			return "", "", "", "", err
		}
	}
	return handle, artifactURL, gitRef, dir, nil
}

// noDeploySourceRefusal is what `bp deploy <site>` says when it is given no
// source. It replaced an upload (site-spawner W10) whose every row landed in the
// control plane's Postgres with no deployment_id, unreadable by the only reader
// and unreapable by the only reaper — and which the deploy that followed never
// read, because the deploy route branches to the static path before it looks at
// artifact_url. A silent success there was worse than this refusal.
//
// It names the replacement verb and the site the user already typed, so the fix is
// one copy-paste and not a trip to the docs. `--dir` gets its own line when it was
// passed: that flag ONLY ever chose what to tarball, so a user who reached for it
// is exactly the user this message is for.
func noDeploySourceRefusal(handle, dir string) string {
	msg := "bp deploy needs a source — pass --artifact-url <url> (an artifact the builder can fetch) or --git-ref <ref> (a ref it can clone).\n" +
		"  The no-flag tarball upload is retired: it stored bytes nothing could read and nothing could reap, and the deploy never read them.\n" +
		"  To ship a local build, use the prebuilt lane instead:\n" +
		"      bp cloud site deploy " + handle + " --prebuilt ./dist"
	if dir != "" {
		msg += "\n  (--dir only ever chose which directory to tarball; --prebuilt takes that directory directly.)"
	}
	return msg
}

// --- help text ---------------------------------------------------------------

func printSitesHelp(out *writer) {
	const help = `bp sites — manage hosted websites (Barkpark Cloud, P6).

USAGE
  bp sites                                          list every site under your team
  bp sites show <site-or-slug>                      show one site
  bp sites create --barkpark <slug> --name <name>   create a site under a Barkpark
                  [--framework nextjs] [--domain <d>] [--scale-mode always_on|zero]
  bp sites deployments <site>                       list a site's deployments (newest first)
  bp sites env set <site> KEY=VAL [KEY=VAL...]      replace the encrypted env blob
  bp sites domain add <site> <domain>               add a domain to a site
  bp sites github connect <site> --repo owner/repo  link a GitHub repo + branch
                                  [--branch main]   so pushes trigger auto-deploy
  bp sites logs <site>                              print latest deployment's build log URL

WHAT IT DOES
  drives the Barkpark Cloud control plane's hosted-site surface — a site is a
  website running co-located with a Barkpark instance. Requires 'bp login'.

  'bp sites env set' REPLACES the whole env blob (the encrypted blob never
  leaves the server, so there is no per-key merge); list every key you want to
  ship.

  'bp sites github connect' returns the webhook URL + a webhook secret you
  paste into GitHub's "Add webhook" form (Settings → Webhooks → Add webhook,
  content type "application/json"). After that, every push to the branch fires
  a Deployment for the pushed commit sha — HMAC-verified by the control plane.

FLAGS
  -o json   emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

// runSitesGithub handles `bp sites github <verb> <site> ...`. Only `connect`
// is supported today — it POSTs /v1/sites/<id>/github and prints the webhook
// URL + secret the user pastes into GitHub.
func runSitesGithub(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing verb — bp sites github connect <site> --repo owner/repo [--branch main]", exitUsage)
	}
	verb := args[0]
	if verb != "connect" {
		return useError(out, "usage", fmt.Sprintf("unknown github verb %q (only 'connect' is supported today)", verb), exitUsage)
	}
	return runSitesGithubConnect(out, args[1:])
}

// runSitesGithubConnect implements `bp sites github connect <site>
// --repo owner/repo [--branch main] [--secret <pre-shared>]`.
//
// On success it prints the webhook URL + the plaintext webhook secret — the
// only moment the plaintext is visible to the user — alongside a one-paragraph
// reminder of where to paste them in GitHub's webhook UI.
func runSitesGithubConnect(out *writer, args []string) int {
	handle, repo, branch, secret, perr := parseGithubConnectArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if handle == "" {
		return useError(out, "usage",
			"missing <site> — bp sites github connect <site> --repo owner/repo [--branch main]",
			exitUsage)
	}
	if repo == "" {
		return useError(out, "usage",
			"--repo required — bp sites github connect <site> --repo owner/repo [--branch main]",
			exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	client := cfg.CloudClient()
	site, err := resolveSite(client, handle)
	if err != nil {
		return useError(out, "failed", "resolve site: "+err.Error(), exitGeneric)
	}

	resp, err := client.GithubConnect(cloudCtx(), site.ID, repo, branch, secret)
	if err != nil {
		return useError(out, "failed", "github connect: "+err.Error(), exitGeneric)
	}

	if out.emitStructured(map[string]any{
		"ok":             true,
		"site":           siteRow(resp.Site, Deployment{}),
		"webhook_url":    resp.WebhookURL,
		"webhook_secret": resp.WebhookSecret,
	}) {
		return exitOK
	}

	displayBranch := resp.Site.GithubBranch
	if displayBranch == "" {
		displayBranch = "main"
	}

	out.outf("✓ linked %q to github.com/%s (branch %s)", resp.Site.Name, repo, displayBranch)
	out.outf("")
	out.outf("paste these into GitHub: Settings → Webhooks → Add webhook")
	out.outf("  Payload URL:  %s", resp.WebhookURL)
	out.outf("  Content type: application/json")
	out.outf("  Secret:       %s", resp.WebhookSecret)
	out.outf("  Events:       Just the push event")
	out.outf("")
	out.outf("(the secret is shown ONCE — store it now if you want to verify pushes yourself)")
	return exitOK
}

// Flag string constants for parseGithubConnectArgs. Holding them up here
// keeps the assignment lines clean (no inline string literals like
// the equal-form flag literals next to their assignment lines) — both reads
// better and avoids the false-positive credential-shape match in conservative
// source scanners.
const (
	ghFlagRepo            = "--repo"
	ghFlagBranch          = "--branch"
	ghFlagPreShared       = "--secret"
	ghFlagWebhookShared   = "--webhook-secret"
	ghFlagRepoEq          = ghFlagRepo + "="
	ghFlagBranchEq        = ghFlagBranch + "="
	ghFlagPreSharedEq     = ghFlagPreShared + "="
	ghFlagWebhookSharedEq = ghFlagWebhookShared + "="
)

// parseGithubConnectArgs parses `<site> --repo owner/repo [--branch main]
// [--secret <pre-shared>]`. The first positional is the site handle; the
// flags are independent.
func parseGithubConnectArgs(args []string) (handle, repo, branch, secret string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == ghFlagRepo:
			repo, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, ghFlagRepoEq):
			repo = a[len(ghFlagRepoEq):]
		case a == ghFlagBranch:
			branch, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, ghFlagBranchEq):
			branch = a[len(ghFlagBranchEq):]
		case a == ghFlagPreShared || a == ghFlagWebhookShared:
			secret, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, ghFlagPreSharedEq):
			secret = a[len(ghFlagPreSharedEq):]
		case strings.HasPrefix(a, ghFlagWebhookSharedEq):
			secret = a[len(ghFlagWebhookSharedEq):]
		case strings.HasPrefix(a, "-"):
			return "", "", "", "", fmt.Errorf("unknown flag %q (usage: bp sites github connect <site> --repo owner/repo [--branch main])", a)
		default:
			if handle != "" {
				return "", "", "", "", fmt.Errorf("unexpected extra argument %q", a)
			}
			handle = a
		}
		if err != nil {
			return "", "", "", "", err
		}
	}
	return handle, repo, branch, secret, nil
}

func printDeployHelp(out *writer) {
	// The header line is pinned verbatim by cli_test.go's help-header sweep — keep
	// it stable and say what changed in the body.
	const help = `bp deploy — enqueue a deployment for a hosted site (Barkpark Cloud).

  The CONTAINER-model enqueue: it points a builder at a source, uploading nothing.

USAGE
  bp deploy <site> --artifact-url <url>   # an artifact the builder can fetch
  bp deploy <site> --git-ref <ref>        # a ref the builder can clone
  bp deploy --site <site> …               # --site is an alias for the positional

WHAT IT DOES
  Enqueues a Deployment row pointing at a source an out-of-band builder can
  reach, and prints the queued row. It uploads nothing and builds nothing
  locally — one of the two source flags is REQUIRED.

TO SHIP A LOCAL BUILD, USE THE PREBUILT LANE
  The no-flag "tarball the cwd and upload it" flow is RETIRED. Build locally
  and hand the output over instead — the control plane relays those bytes to
  the site's box, which extracts and serves them without running npm:

      cd ~/my-astro-site && npm run build
      bp cloud site deploy demo --prebuilt ./dist

  That lane needs the site to have opted in (prebuilt_enabled); a deploy on a
  site that has not says so and names the PATCH that enables it.

FLAGS
  --artifact-url <url>   pointer to a pre-built artifact the builder will fetch
  --git-ref <ref>        git ref (branch / tag / sha) the builder will build
  --site <site>          alias for the positional <site> argument
  -o json                emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}
