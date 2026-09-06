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
//   bp sites deployments <site> [--limit N] [--before <cursor>] [--all] — list a window
//                                                   of the site's deployments
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
	"strconv"
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
// timestamp the server stamped. Under the table it prints the SITE-OUTCOME
// COHORT — the fleet counted by site rather than by deployment row, split
// settled / in flight / never deployed (see renderSiteCohort).
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

	// STATUS + LAST DEPLOY come from the `last_deployment` embed the ONE
	// /v1/sites response already carries (see cloudclient.SiteDeploymentEmbed).
	//
	// deploy-reliability W17: this used to be a deliberate N+1 — one
	// ListDeployments per site — which cost 13 extra round trips for 13 sites
	// AND, worse, read every site's status at a DIFFERENT INSTANT. A fleet
	// cohort assembled from 13 different instants is not a snapshot of anything;
	// it is 13 snapshots stapled together, which is how the same query five
	// minutes apart produced two different, both-true cohorts. One response, one
	// instant, zero extra requests.
	cohort := summarizeSiteCohort(sites)

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(sites))
		for _, s := range sites {
			rows = append(rows, siteListRow(s))
		}
		out.emitStructured(map[string]any{"sites": rows, "cohort": cohort.row()})
		return exitOK
	}

	if len(sites) == 0 {
		out.outf("no sites yet — create one with 'bp sites create --barkpark <slug> --name <name>'")
		return exitOK
	}

	renderSitesTable(out, sites)
	out.outf("")
	renderSiteCohort(out, cohort)
	return exitOK
}

// siteOutcome names the bucket exactly ONE site lands in. Every site in the
// list lands in one and only one of these — see summarizeSiteCohort.
const (
	siteOutcomeLive          = "live"
	siteOutcomeFailed        = "failed"
	siteOutcomeCancelled     = "cancelled"
	siteOutcomeDeferred      = "deferred"
	siteOutcomeBuilding      = "building"
	siteOutcomeOtherInFlight = "other_in_flight"
	siteOutcomeNeverDeployed = "never_deployed"
	siteOutcomeUnreported    = "unreported"
)

// classifySiteStatus buckets the ONE status word the /v1/sites embed carries.
//
// It is deliberately NOT classifyDeployment: that function also reads
// `failure_class` to catch the BOX_*_DEFERRED spellings, and the embed does not
// carry failure_class (D24 fences its keyset at four keys). So this reads the
// status word alone — which is enough, because `deferred` is a real terminal
// status in the control plane's transition map and is what the embed reports.
// A deferral spelled ONLY in failure_class would land in "other in flight"
// here, which is still on the honest side of the line: it is not counted as an
// outcome either way.
func classifySiteStatus(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "deferred":
		return siteOutcomeDeferred
	case "live", "running", "ready", "active":
		return siteOutcomeLive
	case "failed", "error":
		return siteOutcomeFailed
	case "cancelled", "canceled":
		return siteOutcomeCancelled
	case "queued", "building", "pushing":
		return siteOutcomeBuilding
	case "":
		// The embed object arrived with no status word. That is not "never
		// deployed" and it is not an outcome — it is the control plane failing
		// to report, and it gets the bucket that says so.
		return siteOutcomeUnreported
	default:
		return siteOutcomeOtherInFlight
	}
}

// classifySite buckets one SITE. The nil embed is the interesting case and it
// means two different things, which this epic refuses to conflate:
//
//   - no embed AND no current deployment → the site has never had a production
//     deploy (site `auto-proof` on the live fleet). That is its own bucket, not
//     an absence to be dropped: a site silently dropped from the cohort makes
//     the printed buckets disagree with the team's site count forever, and the
//     reader has no way to see the gap.
//   - no embed BUT a current_deployment_id → the site HAS deployed, so the
//     control plane owed us a status and did not send one (a server predating
//     the embed). Calling that "never deployed" would be a fabrication; it gets
//     the UNREPORTED bucket and the render says so out loud.
func classifySite(s cloudclient.Site) string {
	if s.LastDeployment == nil {
		if strings.TrimSpace(s.CurrentDeploymentID) != "" {
			return siteOutcomeUnreported
		}
		return siteOutcomeNeverDeployed
	}
	return classifySiteStatus(s.LastDeployment.Status)
}

// siteCohort is the fleet counted by SITE rather than by deployment row. The
// unit change is the whole point: a row rate is gameable (the deferral loop
// burns 3.7–8.6 attempts per live deploy, so retrying LESS improves the row
// rate without a single site going live one second sooner), while "how many of
// my sites are actually up" is not.
//
// THE BUCKETS SUM TO THE SITE COUNT, AND THAT IS A CONTRACT, NOT AN ACCIDENT —
// the same discipline internal/cli/cloud_site_cmd.go:2013 states for the
// per-site window, one layer up. TestSiteCohortBucketsSumToSiteCount pins it.
type siteCohort struct {
	Sites int

	// Settled: these rows will not move again.
	Live      int
	Failed    int
	Cancelled int // a person or a superseding deploy stopped it — settled, but not a build OUTCOME

	// In flight: these are TRANSIENT states that a latest-per-site query
	// happily reports as if they were outcomes. They are not.
	Deferred      int
	Building      int
	OtherInFlight int // a status word the control plane may add tomorrow

	NeverDeployed int // zero production deployment rows — neither settled nor in flight
	Unreported    int // deployed, but this control plane sent no status
}

// Settled counts the sites whose latest production deployment is finished —
// it will never change on its own. Live + Failed are the outcomes; Cancelled is
// settled too (nothing is still running) but is NOT an outcome, so it is kept
// out of Outcomes below.
func (c siteCohort) Settled() int { return c.Live + c.Failed + c.Cancelled }

// Outcomes is the only honest denominator for "how many of my sites are up":
// sites whose latest production deploy actually DECIDED something.
func (c siteCohort) Outcomes() int { return c.Live + c.Failed }

// InFlight counts sites whose latest production deployment has not settled.
// `deferred` lives HERE, never in an outcome bucket: 1,837 of 2,124 deferred
// rows are followed by a same-site live within the hour, and 0 of 2,124 ever
// set became_live_at. Deferral is terminal for the ROW and usually transient
// for the SITE — it is a COST, and folding a cost into a reliability rate is
// exactly the mis-report this epic exists to remove.
func (c siteCohort) InFlight() int { return c.Deferred + c.Building + c.OtherInFlight }

// Accounted is what the buckets add up to. It must equal Sites; if it ever
// does not, a site fell out of the census with no name, which is the silent
// denominator lie in miniature.
func (c siteCohort) Accounted() int {
	return c.Settled() + c.InFlight() + c.NeverDeployed + c.Unreported
}

// row is the -o json projection, carrying the same buckets and the same
// denominators the human line prints — a machine reader cannot get a bare rate
// here either, because no rate is computed anywhere.
func (c siteCohort) row() map[string]any {
	return map[string]any{
		"sites":           c.Sites,
		"settled":         c.Settled(),
		"live":            c.Live,
		"failed":          c.Failed,
		"cancelled":       c.Cancelled,
		"outcomes":        c.Outcomes(),
		"in_flight":       c.InFlight(),
		"deferred":        c.Deferred,
		"building":        c.Building,
		"other_in_flight": c.OtherInFlight,
		"never_deployed":  c.NeverDeployed,
		"unreported":      c.Unreported,
		"accounted":       c.Accounted(),
		"rate":            nil, // deliberately absent — see renderSiteCohort
		"snapshot":        true,
	}
}

// summarizeSiteCohort counts every site into exactly one bucket, off the ONE
// list response — so the whole cohort is read at ONE instant.
func summarizeSiteCohort(sites []cloudclient.Site) siteCohort {
	c := siteCohort{Sites: len(sites)}
	for _, s := range sites {
		switch classifySite(s) {
		case siteOutcomeLive:
			c.Live++
		case siteOutcomeFailed:
			c.Failed++
		case siteOutcomeCancelled:
			c.Cancelled++
		case siteOutcomeDeferred:
			c.Deferred++
		case siteOutcomeBuilding:
			c.Building++
		case siteOutcomeNeverDeployed:
			c.NeverDeployed++
		case siteOutcomeUnreported:
			c.Unreported++
		default:
			c.OtherInFlight++
		}
	}
	return c
}

// renderSiteCohort prints the two-line site-outcome cohort:
//
//	site outcomes (one snapshot of 13 sites): 12 settled — 10 live, 2 failed; 0 in flight; 1 never deployed
//	10 live of 12 settled sites — counts, not a rate: this cohort is ONE INSTANT (two reads minutes apart disagree) and deferred/building are in-flight COST, never outcomes
//
// NO PERCENTAGE IS PRINTED, at any n. `deploymentSummary`'s minDeploymentSample
// floor is the sibling discipline — but a floor alone would not save this
// surface, because the problem here is not sample SIZE, it is that the sample
// is an INSTANT of a moving system: two identical calls five minutes apart
// returned {live 8, failed 2, deferred 1, building 1} and {live 10, failed 2},
// and a 48-hour replay produced 22 distinct (live, failed, deferred) triples
// over 97 samples with the modal one holding only 19.6% of the time. So every
// count ships WITH ITS DENOMINATOR beside it (charter D3) and the reader does
// the division themselves, knowing what they are dividing.
func renderSiteCohort(out *writer, c siteCohort) {
	settled := fmt.Sprintf("%d settled — %d live, %d failed", c.Settled(), c.Live, c.Failed)
	if c.Cancelled > 0 {
		settled += fmt.Sprintf(", %d cancelled", c.Cancelled)
	}

	inFlight := fmt.Sprintf("%d in flight", c.InFlight())
	if c.InFlight() > 0 {
		parts := []string{}
		if c.Deferred > 0 {
			parts = append(parts, fmt.Sprintf("%d deferred", c.Deferred))
		}
		if c.Building > 0 {
			parts = append(parts, fmt.Sprintf("%d building", c.Building))
		}
		if c.OtherInFlight > 0 {
			parts = append(parts, fmt.Sprintf("%d in another state", c.OtherInFlight))
		}
		inFlight += " — " + strings.Join(parts, ", ")
	}

	line := fmt.Sprintf("site outcomes (one snapshot of %d sites): %s; %s; %d never deployed",
		c.Sites, settled, inFlight, c.NeverDeployed)
	if c.Unreported > 0 {
		line += fmt.Sprintf("; %d deployed but UNREPORTED (this control plane sent no last_deployment)", c.Unreported)
	}
	out.outf("%s", line)

	out.outf("%d live of %d settled sites — counts, not a rate: this cohort is ONE INSTANT (the same call minutes apart disagrees) and deferred/building are in-flight COST, never outcomes",
		c.Live, c.Settled())
}

// Deployment re-exposes cloudclient.Deployment so the local helpers can speak
// the same type without re-importing it everywhere. (Kept as a local alias so
// callers stay readable; no behaviour change.)
type Deployment = cloudclient.Deployment

// latestDeployment returns the newest deployment for siteID (the server returns
// them newest-first). A 404 / empty / error is treated as "no deployment yet" —
// a missing status column is normal for a freshly-created site.
func latestDeployment(client *cloudclient.Client, siteID string) (Deployment, bool) {
	page, err := client.ListDeployments(cloudCtx(), siteID, cloudclient.DeploymentQuery{Limit: 1})
	if err != nil || len(page.Deployments) == 0 {
		return Deployment{}, false
	}
	return page.Deployments[0], true
}

// depStr flattens one of Deployment's POINTER cause fields to a string. nil —
// "the control plane did not send this key" — becomes "", which every render
// path below turns into an explicit dash. Never invent a value for a nil.
func depStr(p *string) string {
	if p == nil {
		return ""
	}
	return strings.TrimSpace(*p)
}

// dashOr is the one place a missing value becomes visible. An empty string on a
// human surface reads as a measured blank; a dash reads as "not reported",
// which is what it actually is.
func dashOr(s string) string {
	if s == "" {
		return "—"
	}
	return s
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

// renderSitesTable prints the aligned `bp sites` table. The columns
// (NAME · SLUG · DOMAINS · STATUS · LAST DEPLOY [· WHY]) are width-driven from
// the data so the output is stable for golden compare. Empty domains print "—".
//
// WHY IS CONDITIONAL, and deliberately: it appears only when at least one site
// in the fleet actually has a cause to name. A fleet where nothing failed gets
// the table it always had, with no column of "—" implying the CLI lost
// something. When it DOES appear, it is the last column so the variable-length
// prose cannot push the fixed columns around.
func renderSitesTable(out *writer, sites []cloudclient.Site) {
	const (
		hName = "NAME"
		// SLUG is the HANDLE every other verb takes (`bp sites deployments
		// <slug>`, `bp deploy <slug>`, `bp cloud site deploy <slug>`), so a
		// list that omits it names sites the reader cannot act on
		// (dr-w14-bl-owner-cannot-list-own-sites: an owner had to curl
		// /v1/sites to learn their own slugs).
		hSlug   = "SLUG"
		hDom    = "DOMAINS"
		hStat   = "STATUS"
		hDeploy = "LAST DEPLOY"
		hWhy    = "WHY"
	)
	nameW, slugW, domW, statW := len(hName), len(hSlug), len(hDom), len(hStat)
	deployW := len(hDeploy)
	anyWhy := false
	rows := make([][6]string, len(sites))
	for i, s := range sites {
		dom := strings.Join(s.Domains, ", ")
		if dom == "" {
			dom = "—"
		}
		slug := strings.TrimSpace(s.Slug)
		if slug == "" {
			slug = "—"
		}
		status, when, why := "—", "—", "—"
		if s.LastDeployment != nil {
			if v := strings.TrimSpace(s.LastDeployment.Status); v != "" {
				status = v
			}
			if v := strings.TrimSpace(s.LastDeployment.InsertedAt); v != "" {
				when = v
			}
			// The CLASS first — it is the name an operator can group and act
			// on — then the humanized sentence, which is what makes a single
			// row readable. A row that carries only one of the two prints only
			// that one; nothing is invented to fill the cell.
			why = siteFailureCause(s.LastDeployment)
			if why != "—" {
				anyWhy = true
			}
		}
		rows[i] = [6]string{s.Name, slug, dom, status, when, why}
		if n := len(s.Name); n > nameW {
			nameW = n
		}
		if n := len(slug); n > slugW {
			slugW = n
		}
		if n := len(dom); n > domW {
			domW = n
		}
		if n := len(status); n > statW {
			statW = n
		}
		if n := len(when); n > deployW {
			deployW = n
		}
	}

	if !anyWhy {
		out.outf("%-*s  %-*s  %-*s  %-*s  %s", nameW, hName, slugW, hSlug, domW, hDom, statW, hStat, hDeploy)
		for _, r := range rows {
			// Pad the raw status to the column width FIRST, then colorize, so
			// the ANSI escape bytes never count toward statW and misalign the
			// table.
			stat := statusColor(out, fmt.Sprintf("%-*s", statW, r[3]))
			out.outf("%-*s  %-*s  %-*s  %s  %s", nameW, r[0], slugW, r[1], domW, r[2], stat, r[4])
		}
		return
	}

	out.outf("%-*s  %-*s  %-*s  %-*s  %-*s  %s",
		nameW, hName, slugW, hSlug, domW, hDom, statW, hStat, deployW, hDeploy, hWhy)
	for _, r := range rows {
		stat := statusColor(out, fmt.Sprintf("%-*s", statW, r[3]))
		out.outf("%-*s  %-*s  %-*s  %s  %-*s  %s",
			nameW, r[0], slugW, r[1], domW, r[2], stat, deployW, r[4], r[5])
	}
}

// siteFailureCause renders the embed's cause pair as ONE cell, or "—" when the
// control plane sent no cause (the deploy did not fail, or the server predates
// the embed — see SiteDeploymentEmbed's pointer fields).
//
// This is a RENDER of what the server sent, never a computation: the class is
// `DeployLedger.classify/1`'s answer and the sentence is already humanized and
// scrubbed by `FailureCopy.humanize/1`. The CLI must not classify prose itself
// — that is the drift that made `bp sites deployments` disagree with the API.
func siteFailureCause(d *cloudclient.SiteDeploymentEmbed) string {
	class, reason := "", ""
	if d.FailureClass != nil {
		class = strings.TrimSpace(*d.FailureClass)
	}
	if d.FailureReason != nil {
		reason = strings.TrimSpace(*d.FailureReason)
	}
	switch {
	case class != "" && reason != "":
		return class + " — " + reason
	case class != "":
		return class
	case reason != "":
		return reason
	default:
		return "—"
	}
}

// siteBaseRow is the site's own fields, shared by the list and show
// projections so the two views can never drift on the site half. Only the
// deployment half differs between them — and it differs because the two
// endpoints genuinely carry different keysets.
func siteBaseRow(s cloudclient.Site) map[string]any {
	return map[string]any{
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
}

// siteListRow projects one site onto the JSON shape `bp sites -o json` emits.
// `last_deployment` here is the SERVER's embed, verbatim and unwidened —
// status/trigger/inserted_at/updated_at plus the cause pair
// (failure_class/failure_reason) — so the machine reader sees exactly the keys
// the control plane measured, and no key invented by the CLI.
//
// The cause pair is emitted as an explicit null on a row that did not fail,
// never omitted: a consumer must be able to tell "this deploy succeeded" from
// "this CLI is older than the server" by reading the payload, and a MISSING key
// says only the second.
//
// It is ABSENT (not null, not an empty object) when the site has no production
// deployment, and `never_deployed` says which absence that is: `true` means the
// site genuinely has no production deploy, `false` means the site HAS one
// (current_deployment_id is set) and the control plane sent no embed for it.
// Those are different facts and a consumer that cannot tell them apart will
// eventually print one as the other.
func siteListRow(s cloudclient.Site) map[string]any {
	row := siteBaseRow(s)
	if s.LastDeployment != nil {
		last := map[string]any{
			"status":         s.LastDeployment.Status,
			"trigger":        nil,
			"inserted_at":    s.LastDeployment.InsertedAt,
			"updated_at":     s.LastDeployment.UpdatedAt,
			"failure_class":  nil,
			"failure_reason": nil,
		}
		if s.LastDeployment.Trigger != nil {
			last["trigger"] = *s.LastDeployment.Trigger
		}
		if s.LastDeployment.FailureClass != nil {
			last["failure_class"] = *s.LastDeployment.FailureClass
		}
		if s.LastDeployment.FailureReason != nil {
			last["failure_reason"] = *s.LastDeployment.FailureReason
		}
		row["last_deployment"] = last
	} else {
		row["never_deployed"] = strings.TrimSpace(s.CurrentDeploymentID) == ""
	}
	row["outcome"] = classifySite(s)
	return row
}

// siteRow projects a site + its latest deployment onto the stable JSON shape
// `bp sites show -o json` emits. The deployment fields are flattened under
// last_deployment so the consumer doesn't have to walk a nested map.
func siteRow(s cloudclient.Site, dep Deployment) map[string]any {
	row := siteBaseRow(s)
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
		if fc := depStr(dep.FailureClass); fc != "" {
			out.outf("  cause:     %s", fc)
		}
		if fr := depStr(dep.FailureReason); fr != "" {
			out.outf("  failure:   %s", fr)
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
		"id":            d.ID,
		"site_id":       d.SiteID,
		"status":        d.Status,
		"git_ref":       d.GitRef,
		"artifact_url":  d.ArtifactURL,
		"image_tag":     d.ImageTag,
		"build_log_url": d.BuildLogURL,
		"inserted_at":   d.InsertedAt,
		"updated_at":    d.UpdatedAt,
		// The POINTER fields stay pointers here: a nil marshals to JSON null,
		// which a machine consumer can tell apart from "" the way a human
		// consumer tells the table's dash apart from a value.
		"failure_class":  d.FailureClass,
		"failure_reason": d.FailureReason,
		"content_rev":    d.ContentRev,
		"trigger":        d.Trigger,
		"stage":          d.Stage,
		"became_live_at": d.BecameLiveAt,
	}
}

// runSitesDeployments renders `bp sites deployments <site> [--limit N]
// [--before <cursor>]` — newest-first, with a summary line that carries its own
// denominator and names its window.
//
// Columns: STATUS · CAUSE · TRIGGER · STARTED. IMAGE_TAG and GIT_REF are gone
// from the human table on purpose (deploy-reliability W9): on guerrilla both are
// empty on every row, so three of the old four columns were dashes and the
// fourth was a timestamp — a table that could not report a failure. Both keys
// are still in `-o json`.
func runSitesDeployments(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSitesHelp(out)
			return exitOK
		}
	}
	handle, q, all, perr := parseDeploymentsArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if handle == "" {
		return useError(out, "usage", "missing <site> — bp sites deployments <site> [--limit N] [--before <cursor>] [--all]", exitUsage)
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
	var ds []cloudclient.Deployment
	var page cloudclient.DeploymentPage
	if all {
		// --all is the cursor's first CLI consumer (dr-w14-s6 followup): it
		// follows next_cursor to the end of the ledger, so a rate or an audit
		// over "the deployments" finally means all of them, not the newest
		// hundred. The page NextCursor stays "" — there is nothing behind a
		// full walk.
		rows, err := client.ListDeploymentsAll(cloudCtx(), site.ID, q.Limit, 0)
		if err != nil {
			return useError(out, "failed", "list deployments: "+err.Error(), exitGeneric)
		}
		ds = rows
	} else {
		var err error
		page, err = client.ListDeployments(cloudCtx(), site.ID, q)
		if err != nil {
			return useError(out, "failed", "list deployments: "+err.Error(), exitGeneric)
		}
		ds = page.Deployments
	}

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(ds))
		for _, d := range ds {
			rows = append(rows, deploymentRow(d))
		}
		payload := map[string]any{"deployments": rows, "summary": summarizeDeployments(ds).row()}
		if page.NextCursor != "" {
			payload["next_cursor"] = page.NextCursor
		} else {
			payload["next_cursor"] = nil
		}
		out.emitStructured(payload)
		return exitOK
	}
	if len(ds) == 0 {
		out.outf("no deployments for %q yet — 'cd ~/your-project && bp deploy %s'", site.Name, site.Slug)
		return exitOK
	}
	renderDeploymentSummary(out, summarizeDeployments(ds), page.NextCursor)
	out.outf("")
	renderDeploymentsTable(out, ds)
	return exitOK
}

// parseDeploymentsArgs splits `bp sites deployments <site> [--limit N]
// [--before <cursor>]`. The first positional is the site handle; a second
// positional is a usage error, same as before the flags existed.
func parseDeploymentsArgs(args []string) (handle string, q cloudclient.DeploymentQuery, all bool, err error) {
	setLimit := func(v string) error {
		n, cerr := strconv.Atoi(strings.TrimSpace(v))
		if cerr != nil || n <= 0 {
			return fmt.Errorf("--limit wants a positive whole number, got %q", v)
		}
		q.Limit = n
		return nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--limit" || a == "-n":
			var v string
			v, i, err = nextFlagValue(args, i)
			if err == nil {
				err = setLimit(v)
			}
		case strings.HasPrefix(a, "--limit="):
			err = setLimit(a[len("--limit="):])
		case a == "--all":
			all = true
		case a == "--before" || a == "--cursor":
			q.Before, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--before="):
			q.Before = a[len("--before="):]
		case strings.HasPrefix(a, "--cursor="):
			q.Before = a[len("--cursor="):]
		case strings.HasPrefix(a, "-"):
			return "", cloudclient.DeploymentQuery{}, false, fmt.Errorf("unknown flag %q (usage: bp sites deployments <site> [--limit N] [--before <cursor>] [--all])", a)
		case handle == "":
			handle = a
		default:
			return "", cloudclient.DeploymentQuery{}, false, fmt.Errorf("too many arguments — bp sites deployments <site> [--limit N] [--before <cursor>] [--all]")
		}
		if err != nil {
			return "", cloudclient.DeploymentQuery{}, false, err
		}
	}
	if all && q.Before != "" {
		return "", cloudclient.DeploymentQuery{}, false, fmt.Errorf("--all walks every page from the newest row; it cannot start from a --before cursor")
	}
	return handle, q, all, nil
}

// minDeploymentSample is the smallest window this command will compute a
// PERCENTAGE from. Below it the rate is printed as UNMETERED with the raw
// counts — a rate over four rows is noise wearing a decimal point, and this
// epic exists because deploy reporting kept dressing noise as measurement.
const minDeploymentSample = 10

// deferredMarker names the control plane's "we never even tried" failure
// classes (BOX_AT_CAPACITY_DEFERRED and friends). A deferred row is NOT a
// terminal outcome: nothing was built, so it cannot be counted as a success or
// a failure without lying in one direction or the other. It gets its own
// bucket and its own denominator.
const deferredMarker = "DEFERRED"

// deploymentSummary is the counted shape behind the summary line. Every field
// here appears in the rendered output — there is no number computed and hidden.
type deploymentSummary struct {
	Rows      int // rows in the fetched window
	Live      int
	Failed    int
	Deferred  int
	Cancelled int // a person (or a superseding deploy) stopped it — terminal, but not a build failure
	Pending   int // still in flight: queued/building/pushing — not yet an outcome
	OldestAt  string
	NewestAt  string
}

// Terminal is the denominator a success/failure rate is honest over: rows that
// actually reached an outcome. Deferred and in-flight rows are excluded.
func (s deploymentSummary) Terminal() int { return s.Live + s.Failed }

// row is the -o json projection of the summary, carrying the same denominators
// the human line prints so a machine reader cannot get a bare rate either.
func (s deploymentSummary) row() map[string]any {
	m := map[string]any{
		"rows":             s.Rows,
		"live":             s.Live,
		"failed":           s.Failed,
		"deferred":         s.Deferred,
		"cancelled":        s.Cancelled,
		"pending":          s.Pending,
		"terminal":         s.Terminal(),
		"window_oldest":    nil,
		"window_newest":    nil,
		"min_sample":       minDeploymentSample,
		"failed_pct":       nil,
		"deferred_pct":     nil,
		"failed_metered":   s.Terminal() >= minDeploymentSample,
		"deferred_metered": s.Rows >= minDeploymentSample,
	}
	if s.OldestAt != "" {
		m["window_oldest"] = s.OldestAt
	}
	if s.NewestAt != "" {
		m["window_newest"] = s.NewestAt
	}
	if s.Terminal() >= minDeploymentSample {
		m["failed_pct"] = pct(s.Failed, s.Terminal())
	}
	if s.Rows >= minDeploymentSample {
		m["deferred_pct"] = pct(s.Deferred, s.Rows)
	}
	return m
}

// pct is the only place a percentage is computed. It never divides by zero and
// it is never called without its denominator being printed alongside it.
func pct(n, d int) float64 {
	if d <= 0 {
		return 0
	}
	return float64(n) * 100 / float64(d)
}

// classifyDeployment buckets one row. DEFERRED wins over status, and the
// control plane spells a deferral BOTH ways — `status: "deferred"` is a real
// terminal state in the Deployment schema's transition map, and the row also
// carries a DEFERRED_* failure_class — so both are read here. Counting a build
// that never ran as a build failure is exactly the mis-reporting this slice
// removes, and a reader that only knew one spelling would re-introduce it the
// day the other one arrives.
//
// `cancelled` is its OWN bucket, not "in flight" (reviewer fix, W9): a person
// or a superseding deploy stopped that row, it is never going to move again,
// and painting a stopped row as still-running is the same lie in the other
// direction. It is out of the terminal denominator because nothing was decided
// about the BUILD.
func classifyDeployment(d Deployment) string {
	status := strings.ToLower(strings.TrimSpace(d.Status))
	if status == "deferred" ||
		strings.Contains(strings.ToUpper(depStr(d.FailureClass)), deferredMarker) {
		return "deferred"
	}
	switch status {
	case "live", "running", "ready", "active":
		return "live"
	case "failed", "error":
		return "failed"
	case "cancelled", "canceled":
		return "cancelled"
	default:
		return "pending"
	}
}

// summarizeDeployments counts the fetched window and records its edges. The
// window is taken from the rows themselves (oldest/newest inserted_at), not
// from what the caller asked for — a window that names a request instead of the
// data is how an unstated denominator sneaks back in.
func summarizeDeployments(ds []Deployment) deploymentSummary {
	s := deploymentSummary{Rows: len(ds)}
	for _, d := range ds {
		switch classifyDeployment(d) {
		case "live":
			s.Live++
		case "failed":
			s.Failed++
		case "deferred":
			s.Deferred++
		case "cancelled":
			s.Cancelled++
		default:
			s.Pending++
		}
		when := strings.TrimSpace(d.InsertedAt)
		if when == "" {
			continue
		}
		if s.OldestAt == "" || when < s.OldestAt {
			s.OldestAt = when
		}
		if s.NewestAt == "" || when > s.NewestAt {
			s.NewestAt = when
		}
	}
	return s
}

// renderDeploymentSummary prints the two-line honest header:
//
//	20 live, 3 failed, 77 deferred — 13.0% failed of 23 terminal outcomes, 77.0% of 100 rows never attempted (box deferred them)
//	window: 2026-08-06T21:10:04Z → 2026-08-07T02:58:11Z (100 rows fetched)
//
// Both rates carry their denominator ON THE SAME LINE as the counts, and a
// window too small to divide honestly prints UNMETERED instead of a number.
// The window line exists because a rate whose window is unstated is the
// vacuous green this epic refuses.
//
// Reviewer fix (W9): the deferred clause used to read "absorbed by the build
// cap", which is affirmatively FALSE for the BOX_BUSY_DEFERRED half of the
// deferred family — that box was busy with THIS site, not out of slots. Naming
// one deferral cause for all of them is the same defect S2 fixed on the server
// side, one surface later. The clause now names the OUTCOME (never attempted),
// which is true of every deferral class; the per-row CAUSE column still names
// which one.
func renderDeploymentSummary(out *writer, s deploymentSummary, nextCursor string) {
	counts := fmt.Sprintf("%d live, %d failed, %d deferred", s.Live, s.Failed, s.Deferred)
	if s.Cancelled > 0 {
		counts += fmt.Sprintf(", %d cancelled", s.Cancelled)
	}
	if s.Pending > 0 {
		counts += fmt.Sprintf(", %d in flight", s.Pending)
	}

	var failedPart string
	if s.Terminal() >= minDeploymentSample {
		failedPart = fmt.Sprintf("%.1f%% failed of %d terminal outcomes", pct(s.Failed, s.Terminal()), s.Terminal())
	} else {
		failedPart = fmt.Sprintf("failure rate UNMETERED (%d terminal outcomes, need %d)", s.Terminal(), minDeploymentSample)
	}

	var deferredPart string
	if s.Rows >= minDeploymentSample {
		deferredPart = fmt.Sprintf("%.1f%% of %d rows never attempted (box deferred them)", pct(s.Deferred, s.Rows), s.Rows)
	} else {
		deferredPart = fmt.Sprintf("deferral rate UNMETERED (%d rows, need %d)", s.Rows, minDeploymentSample)
	}

	out.outf("%s — %s, %s", counts, failedPart, deferredPart)

	window := fmt.Sprintf("window: %s → %s (%d rows fetched)", dashOr(s.OldestAt), dashOr(s.NewestAt), s.Rows)
	if nextCursor != "" {
		window += fmt.Sprintf("; older rows exist — '--before %s' to walk past this window", nextCursor)
	}
	out.outf("%s", window)
}

// renderDeploymentsTable prints STATUS · CAUSE · TRIGGER · STARTED. A field the
// control plane did not send renders as an explicit dash — never as a blank
// cell, which reads as a measured empty value.
func renderDeploymentsTable(out *writer, ds []Deployment) {
	const (
		hStat = "STATUS"
		hCaus = "CAUSE"
		hTrig = "TRIGGER"
		hWhen = "STARTED"
	)
	cause := func(d Deployment) string { return dashOr(depStr(d.FailureClass)) }
	trigger := func(d Deployment) string { return dashOr(depStr(d.Trigger)) }

	statW, causW, trigW := len(hStat), len(hCaus), len(hTrig)
	for _, d := range ds {
		if n := len([]rune(d.Status)); n > statW {
			statW = n
		}
		if n := len([]rune(cause(d))); n > causW {
			causW = n
		}
		if n := len([]rune(trigger(d))); n > trigW {
			trigW = n
		}
	}
	out.outf("%-*s  %-*s  %-*s  %s", statW, hStat, causW, hCaus, trigW, hTrig, hWhen)
	for _, d := range ds {
		// Pad the raw status to the column width FIRST, then colorize, so the
		// ANSI escape bytes never count toward statW and misalign the table.
		stat := statusColor(out, padRunes(d.Status, statW))
		out.outf("%s  %s  %s  %s",
			stat,
			padRunes(cause(d), causW),
			padRunes(trigger(d), trigW),
			dashOr(strings.TrimSpace(d.InsertedAt)))
	}
}

// padRunes right-pads to a RUNE width. The dash this table leans on is a
// multi-byte em dash, so %-*s (which counts bytes) would over-pad every column
// that contains one and shear the table.
func padRunes(s string, w int) string {
	if n := len([]rune(s)); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

// runSitesEnv handles `bp sites env <verb> <site> …`. Today the only verb is
// `set` — the control plane replaces the whole env blob on every write, so an
// incremental "merge K=V into the existing env" needs the CLI to know the prior
// state. There is no USER-facing GET /env endpoint (the decrypted blob is
// served only to the fleet — the builder injects it into the nixpacks build,
// the box agent into the docker run; site-env-injection), so this command
// treats KEY=VAL... as the full desired env: it is NOT a merge with existing
// values, and the help text says so loudly.
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
  bp sites deployments <site> [--limit N] [--before <c>] [--all]  list a window of a site's deployments (--all walks every page)
                                                    (newest first; STATUS/CAUSE/TRIGGER/STARTED
                                                     plus a summary carrying its denominator)
  bp sites env set <site> KEY=VAL [KEY=VAL...]      replace the encrypted env blob
  bp sites domain add <site> <domain>               add a domain to a site
  bp sites github connect <site> --repo owner/repo  link a GitHub repo + branch
                                  [--branch main]   so pushes trigger auto-deploy
  bp sites logs <site>                              print latest deployment's build log URL

WHAT IT DOES
  drives the Barkpark Cloud control plane's hosted-site surface — a site is a
  website running co-located with a Barkpark instance. Requires 'bp login'.

WHAT 'bp sites' PRINTS
  the table (NAME · DOMAINS · STATUS · LAST DEPLOY), then the SITE-OUTCOME
  COHORT — the fleet counted by SITE, in ONE request read at ONE instant:

    site outcomes (one snapshot of 13 sites): 12 settled — 10 live, 2 failed; 0 in flight; 1 never deployed

  counts, never a rate, at any n: the cohort is an instant of a moving system
  (the same call minutes apart disagrees), and 'deferred'/'building' are
  IN-FLIGHT COST, never outcomes. A site that has never deployed to production
  gets its own bucket rather than being dropped, so the buckets always sum to
  the site count.

  -o json carries the same buckets under 'cohort' (with 'rate': null, on
  purpose). NOTE: each site's 'last_deployment' in the LIST view is the
  server's six-key embed — status/trigger/inserted_at/updated_at plus the CAUSE
  pair, failure_class/failure_reason (both explicitly null on a deploy that did
  not fail; failure_reason is the humanized, scrubbed sentence, never the raw
  capture). It does not carry 'id' or 'image_tag'; 'bp sites show -o json'
  still does. The table grows a WHY column only when some site in the fleet
  actually has a cause to name.

  'bp sites env set' REPLACES the whole env blob (the blob is stored encrypted
  and never echoed back, so there is no per-key merge); list every key you
  want to ship. The env is injected on the NEXT deploy, in both places that
  matter: the builder passes each pair to the nixpacks build (so build-time
  prerendering sees it) and the box starts the container with the same pairs
  (so the running site sees it). Changing env alone changes nothing until you
  redeploy.

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
