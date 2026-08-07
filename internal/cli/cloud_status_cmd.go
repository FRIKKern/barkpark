package cli

// cloud_status_cmd.go is `bp cloud status` — the terminal triage twin of the
// dashboard's attention queue (epic charter, decision 15). It fetches the whole
// fleet from the control plane (GET /v1/barkparks via internal/cloudclient) and
// renders it RANK-ORDERED, most-urgent-first, bucketed into attention /
// in-flight / healthy, each status cell painted via the shared statusRole colors
// so a red row in the terminal and a red dot in the dashboard mean the same
// thing. `-o json` emits the same ranked structure for scripts.
//
// The vocabulary here is the charter-pinned decision-15/decision-32 spec — the
// SAME states, ranks, buckets and tones the SPA's statusOf/attentionRank
// implements. The cross-surface contract is the committed decision-32 fixture
// cloud/priv/static/__fixtures__/attention_order.json (asserted from Go by
// TestAttentionVocabularyMatchesFixture and, from wave 3, the node harness);
// testdata/attention_order_cases.json adds concrete input→order cases for the
// ranking itself.

import (
	"fmt"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/mattn/go-runewidth"
)

// deployFailingFencePct is the fence above which a box's own deploy failure rate
// IS the box's headline problem (charter D150). 20.0 is not a round number
// chosen for looks: it sits above the site-caused floor (9.5% on the fleet with
// the three noisy search* sites retired) and below the raw rate with those same
// sites removed (25.58%), so the verdict survives the composition crack in BOTH
// directions — it cannot be switched on by adding a noisy site, and it cannot be
// switched OFF by decommissioning three of them.
const deployFailingFencePct = 20.0

// deployVerdict is the TRI-STATE the deploy vital resolves to, plus the "the
// control plane never told us" case that precedes all three. It exists so
// attentionStatus can match explicitly instead of reaching `ok` by falling off
// the end of a switch — the exact bug this rung was built to remove.
type deployVerdict int

const (
	// deployAbsent — the control plane sent no deploy vital at all (an older CP).
	// We could not ASK, so we say nothing: the verdict is unchanged and the row
	// wears no marker. Distinct from every state below, which are answers.
	deployAbsent deployVerdict = iota
	// deployNoSurface — the box owns zero sites. It has nothing to deploy, so it
	// has not failed to report: the verdict is unchanged and it wears a marker
	// (the D74/D88 marker doctrine). Folding this into "unmetered" would put 6 of
	// 8 boxes in a permanent alarm nobody reads (charter D149).
	deployNoSurface
	// deployUnmetered — the box HAS sites, and the rate refused (sample below
	// min_sample, or no terminal deploys in the window). A silence, and it says so.
	deployUnmetered
	// deployMeasured — a real percentage, with its denominator.
	deployMeasured
)

// deployRateOf resolves a fleet row's deploy vital into its verdict and, when
// measured, the percentage. It NEVER invents a number: an absent node, an absent
// pct and a refused rate are three different answers and none of them is 0.0.
func deployRateOf(b cloudclient.Barkpark) (deployVerdict, float64) {
	node := b.DeployRate
	if node == nil {
		return deployAbsent, 0
	}
	if node.Sites <= 0 {
		return deployNoSurface, 0
	}
	if node.Rate.Pct == nil {
		return deployUnmetered, 0
	}
	return deployMeasured, *node.Rate.Pct
}

// attentionStatus classifies one Barkpark into its charter-decision-15 status
// label. The TEN labels, MOST URGENT FIRST, are:
//
//  1. removal_failed  — deprovision_status = "failed"
//  2. failed          — no host && provision_status = "failed"
//  3. suspended       — suspended = true (and not removing)
//  4. degraded        — live && (health_status != "up" || agent_status != "online")
//  5. deploys_failing — live && a MEASURED deploy failure rate at or above the fence
//  6. behind          — live && update_state = "behind"
//  7. removing        — deprovision_status ∈ {pending, claimed}
//  8. provisioning    — no host, nothing failed
//  9. unmetered       — the box has sites and its deploy rate could not be scored
//  10. ok             — live, healthy, current, and nothing to say about deploys
//
// where "live" = a host is set with nothing in-flight/failed/suspended. The
// cases are evaluated in rank order and the first match wins, so the precedence
// (a removing box that is also suspended is "removing"; a live box that is both
// degraded and behind is "degraded") falls out of the ordering itself.
//
// THE DEPLOY TAIL IS AN EXPLICIT THREE-WAY MATCH (charter D149), and that is the
// point of the slice: `ok` used to be returned by a bare `default:` that read no
// vital at all, so a box failing 46.28% of its 1,290 terminal deploys in 24 h
// printed `ok`. Every arm below now returns a status a matched clause chose, and
// the one unmatched arm fails CLOSED to `unmetered` — never to `ok`.
//
// Charter edge left as specified: a box with a host SET and provision_status =
// "failed" matches no decision-15 rule (rank 2 requires no host; degraded/
// behind require live, which a failed provision is not) and reaches the deploy
// tail. Both surfaces implement the charter verbatim, so changing it here alone
// would create exactly the drift D32 exists to prevent — if this state is
// reachable, amend decision 15 first, then both implementations together.
func attentionStatus(b cloudclient.Barkpark) string {
	host := strings.TrimSpace(b.Host)
	removing := b.DeprovisionStatus == "pending" || b.DeprovisionStatus == "claimed"
	// live: a real host, no in-flight removal, not suspended, not a failed provision.
	live := host != "" && !removing && !b.Suspended && b.ProvisionStatus != "failed"
	verdict, pct := deployRateOf(b)

	switch {
	case b.DeprovisionStatus == "failed":
		return "removal_failed"
	case host == "" && b.ProvisionStatus == "failed":
		return "failed"
	case b.Suspended && !removing:
		return "suspended"
	case live && (b.HealthStatus != "up" || b.AgentStatus != "online"):
		return "degraded"
	case live && verdict == deployMeasured && pct >= deployFailingFencePct:
		return "deploys_failing"
	case live && b.UpdateState == "behind":
		return "behind"
	case removing:
		return "removing"
	case host == "":
		return "provisioning"
	}

	// THE DEPLOY TAIL. Nothing below reaches `ok` by falling through: each arm
	// names why the box is calm, and an unrecognised verdict is a silence, which
	// is `unmetered` — the safe direction is always "we did not measure".
	switch verdict {
	case deployAbsent:
		return "ok" // the control plane sent no deploy vital — we could not ask
	case deployNoSurface:
		return "ok" // zero sites: nothing to deploy, so nothing to fail
	case deployMeasured:
		return "ok" // measured, and under the fence
	default:
		return "unmetered" // deployUnmetered, and any verdict added after it
	}
}

// attentionRankOrder is the decision-15 ordering, most urgent first. Index+1 is
// the charter rank (1–10), exactly as the decision-32 fixture pins it.
//
// The two dr-w10 rungs RENUMBER this ladder rather than appending to it, and the
// difference was mutation-probed: appended, `deploys_failing` ranks 9 — BELOW
// `ok` — so the one box the epic exists to call sick would render last, under
// every healthy box. Any semantically-correct placement renumbers by definition
// (charter D150).
var attentionRankOrder = []string{
	"removal_failed",  // 1
	"failed",          // 2
	"suspended",       // 3
	"degraded",        // 4
	"deploys_failing", // 5
	"behind",          // 6
	"removing",        // 7
	"provisioning",    // 8
	"unmetered",       // 9
	"ok",              // 10
}

// attentionRank is the sort key for a status label — its charter rank, 1 (most
// urgent) through 10 (ok), matching the decision-32 fixture byte-for-byte. An
// unknown label ranks past the end (never panics) and so sorts last.
func attentionRank(status string) int {
	for i, s := range attentionRankOrder {
		if s == status {
			return i + 1
		}
	}
	return len(attentionRankOrder) + 1
}

// attentionBucket groups a status into the three charter buckets: attention
// (removal_failed…behind, plus unmetered), in-flight (removing/provisioning),
// healthy (ok). The bucket strings are the decision-32 fixture's, verbatim —
// note "in-flight" is hyphenated there, so it is hyphenated here and in -o json.
//
// `unmetered` is the one rung whose bucket does not follow its rank: it ranks 9
// (below every real problem, above ok) because it is not an outage, but it
// buckets with ATTENTION because a box that has sites and cannot be scored is a
// SILENCE — and treating a silence as healthy is the disease this epic exists to
// cure. Ranked low, it renders last inside the attention section: visible,
// never shouting.
func attentionBucket(status string) string {
	switch status {
	case "removing", "provisioning":
		return "in-flight"
	case "ok":
		return "healthy"
	default:
		// removal_failed, failed, suspended, degraded, deploys_failing, behind,
		// unmetered — and any unknown label defensively surfaces in the attention
		// bucket rather than hiding.
		return "attention"
	}
}

// attentionDetail is the one-line WHY behind an attention status — the reason
// the control plane already told us, surfaced instead of hoarded: the
// deprovision error for removal_failed, the provision error for failed, the
// suspension reason for suspended. States whose row already explains itself
// (degraded shows health/agent, behind IS the message) yield "".
func attentionDetail(b cloudclient.Barkpark, status string) string {
	switch status {
	case "removal_failed":
		return strings.TrimSpace(b.DeprovisionError)
	case "failed":
		return strings.TrimSpace(b.ProvisionError)
	case "suspended":
		return strings.TrimSpace(b.SuspendedReason)
	case "deploys_failing", "unmetered", "ok":
		// THE DEPLOY MARKER (charter D149, the D74/D88 marker doctrine). An `ok`
		// row that reached `ok` by a DEPLOY answer says which answer it was, so a
		// calm row is readable as a measurement and not as an absence of one. A
		// control plane that sent nothing yields "" — the older-CP honesty rule,
		// and the reason a healthy bucket does not grow a DETAIL column for a CP
		// that never reported.
		return deployMarker(b)
	default:
		return ""
	}
}

// deployMarker is the one-line WHY behind a deploy verdict: the rate with its
// denominator (never a bare percentage), the box-caused companion when it is
// itself measurable, and — for a silence — the control plane's own refusal
// reason. Never fabricates a number the vital did not carry.
func deployMarker(b cloudclient.Barkpark) string {
	verdict, pct := deployRateOf(b)
	node := b.DeployRate
	switch verdict {
	case deployAbsent:
		return ""
	case deployNoSurface:
		return "no sites — nothing to deploy"
	case deployUnmetered:
		if reason := strings.TrimSpace(node.Rate.Reason); reason != "" {
			return "deploy rate unmetered: " + reason
		}
		return "deploy rate unmetered"
	default:
		marker := fmt.Sprintf("%.1f%% of %d terminal deploys failed", pct, node.Rate.Sample)
		if node.BoxCaused.Pct != nil {
			marker += fmt.Sprintf(" · box-caused %.1f%%", *node.BoxCaused.Pct)
		}
		if node.Absorption.Pct != nil {
			marker += fmt.Sprintf(" · absorbed %.1f%%", *node.Absorption.Pct)
		}
		return marker
	}
}

// rankedBarkpark is one fleet row with its computed decision-15 triage fields.
type rankedBarkpark struct {
	BP     cloudclient.Barkpark
	Status string
	Bucket string
	Rank   int
	Detail string
}

// rankBarkparks classifies every Barkpark and returns them in decision-15 rank
// order: by rank ascending (most urgent first), tiebroken by name ascending
// case-insensitively. This is the pure ordering the attention_order.json fixture
// pins and the SPA mirrors.
func rankBarkparks(list []cloudclient.Barkpark) []rankedBarkpark {
	out := make([]rankedBarkpark, 0, len(list))
	for _, b := range list {
		st := attentionStatus(b)
		out = append(out, rankedBarkpark{
			BP:     b,
			Status: st,
			Bucket: attentionBucket(st),
			Rank:   attentionRank(st),
			Detail: attentionDetail(b, st),
		})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Rank != out[j].Rank {
			return out[i].Rank < out[j].Rank
		}
		// Tiebreak: name ascending, case-insensitive (charter decision 15).
		ni, nj := strings.ToLower(out[i].BP.Name), strings.ToLower(out[j].BP.Name)
		if ni != nj {
			return ni < nj
		}
		// Total order even for same-name rows: fall back to id so the sort is
		// deterministic (SliceStable would otherwise keep input order).
		return out[i].BP.ID < out[j].BP.ID
	})
	return out
}

// rankedBarkparkRow is the flat JSON/YAML shape of one ranked row — self-
// describing so `-o json` output is stable and scriptable. The self-update TRUTH
// fields (isu-w5) ride here too: the running/latest release, when the verdict was
// checked, the full autoupdate policy, and the channel. autoupdate_enabled is a
// tri-state — true/false when the control plane reported it, absent entirely when
// it didn't (an older CP) so a script never mistakes "unknown" for "off".
func rankedBarkparkRow(r rankedBarkpark) map[string]any {
	row := map[string]any{
		"name":                   r.BP.Name,
		"slug":                   r.BP.Slug,
		"id":                     r.BP.ID,
		"host":                   r.BP.Host,
		"url":                    r.BP.URL,
		"status":                 r.Status,
		"bucket":                 r.Bucket,
		"rank":                   r.Rank,
		"detail":                 r.Detail,
		"health_status":          r.BP.HealthStatus,
		"agent_status":           r.BP.AgentStatus,
		"update_state":           r.BP.UpdateState,
		"suspended":              r.BP.Suspended,
		"update_running_release": r.BP.UpdateRunningRelease,
		"update_latest_release":  r.BP.UpdateLatestRelease,
		"update_checked_at":      r.BP.UpdateCheckedAt,
		"autoupdate_paused":      r.BP.AutoupdatePaused,
		"pinned_release":         r.BP.PinnedRelease,
		"channel":                r.BP.Channel,
	}
	// Tri-state: only emit autoupdate_enabled when the CP actually reported it, so
	// -o json is as honest as the table (nil = policy unknown, never a fake false).
	if r.BP.AutoupdateEnabled != nil {
		row["autoupdate_enabled"] = *r.BP.AutoupdateEnabled
	}
	// The deploy vital, same honesty rule as above: the keys exist only when the
	// control plane sent the node, and `deploy_failure_pct` is emitted only when
	// the rate was actually measured — a refused rate leaves the key ABSENT
	// rather than scripting a comforting 0.0. `deploy_sites` is the surface count,
	// so a script can tell "nothing to deploy" from "could not measure".
	if node := r.BP.DeployRate; node != nil {
		row["deploy_sites"] = node.Sites
		row["deploy_sites_deploying"] = node.SitesDeploying
		row["deploy_sample"] = node.Rate.Sample
		row["deploy_refused"] = node.Rate.Refused
		if node.Rate.Pct != nil {
			row["deploy_failure_pct"] = *node.Rate.Pct
		}
		if node.BoxCaused.Pct != nil {
			row["deploy_box_caused_pct"] = *node.BoxCaused.Pct
		}
		if node.Absorption.Pct != nil {
			row["deploy_absorption_pct"] = *node.Absorption.Pct
		}
	}
	return row
}

// updateCell renders the "running → latest" version pair for the UPDATE column.
// When the box is behind (the releases differ, or the coarse verdict says so),
// the arrow form IS the behind marker; a current box shows just its running
// release; a box the control plane hasn't versioned yet (older CP) yields "" so
// the column collapses out entirely. Never fabricates a version it wasn't told.
func updateCell(b cloudclient.Barkpark) string {
	running := strings.TrimSpace(b.UpdateRunningRelease)
	latest := strings.TrimSpace(b.UpdateLatestRelease)
	if running == "" && latest == "" {
		return ""
	}
	behind := (running != "" && latest != "" && running != latest) || b.UpdateState == "behind"
	if behind && latest != "" {
		from := running
		if from == "" {
			from = "?"
		}
		return sanitizeCell(from) + " → " + sanitizeCell(latest)
	}
	if running != "" {
		return sanitizeCell(running)
	}
	return sanitizeCell(latest)
}

// policyCell collapses the autoupdate policy into ONE compact flag for the POLICY
// column, most-specific first: a pin wins ("pin@<tag>", the freeze), then a hold
// ("paused"), then an explicit opt-out ("off"), then the auto-ride default
// ("auto"). A control plane that reported no policy at all (autoupdate_enabled
// nil, not paused, unpinned) yields "" so the row shows a dash rather than
// claiming a state the CP never sent — the older-CP honesty rule.
func policyCell(b cloudclient.Barkpark) string {
	if pin := strings.TrimSpace(b.PinnedRelease); pin != "" {
		return "pin@" + sanitizeCell(pin)
	}
	if b.AutoupdatePaused {
		return "paused"
	}
	if b.AutoupdateEnabled != nil {
		if *b.AutoupdateEnabled {
			return "auto"
		}
		return "off"
	}
	return ""
}

// bucketCounts tallies a ranked fleet into the three buckets.
func bucketCounts(ranked []rankedBarkpark) (attention, inFlight, healthy int) {
	for _, r := range ranked {
		switch r.Bucket {
		case "attention":
			attention++
		case "in-flight":
			inFlight++
		case "healthy":
			healthy++
		}
	}
	return
}

// runCloudStatus is `bp cloud status`: fetch the fleet from the control plane
// and render the decision-15 triage view. Requires a Cloud token (`bp login`).
func runCloudStatus(out *writer, g globals, args []string) int {
	if g.help {
		printCloudStatusHelp(out)
		return exitOK
	}
	if len(args) > 0 {
		return useError(out, "usage", "bp cloud status takes no arguments (run `bp cloud status -h` for usage)", exitUsage)
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to see your fleet's status", exitAuth)
	}

	list, lerr := cfg.CloudClient().ListBarkparks(cloudCtx())
	if lerr != nil {
		return cloudFail(out, "fleet status", lerr)
	}
	ranked := rankBarkparks(list)
	attention, inFlight, healthy := bucketCounts(ranked)

	if out.output == "json" || out.output == "yaml" {
		rows := make([]any, 0, len(ranked))
		for _, r := range ranked {
			rows = append(rows, rankedBarkparkRow(r))
		}
		out.emitStructured(map[string]any{
			"ok":    true,
			"count": len(ranked),
			// Bucket keys are the decision-32 fixture strings, hyphen included.
			"buckets": map[string]any{
				"attention": attention,
				"in-flight": inFlight,
				"healthy":   healthy,
			},
			"barkparks": rows,
		})
		return exitOK
	}

	if len(ranked) == 0 {
		out.outf("no Barkparks yet — launch one with 'bp go-live --name <name>' or 'bp launch hetzner --name <name>'")
		return exitOK
	}

	out.outf("%d barkpark(s) · %d need attention · %d in-flight · %d healthy",
		len(ranked), attention, inFlight, healthy)
	renderStatusBucket(out, "ATTENTION", "attention", ranked)
	renderStatusBucket(out, "IN-FLIGHT", "in-flight", ranked)
	renderStatusBucket(out, "HEALTHY", "healthy", ranked)
	return exitOK
}

// renderStatusBucket prints one bucket section (header + painted table) when it
// has rows, in the already-sorted order. Silent for an empty bucket so the view
// stays lean.
func renderStatusBucket(out *writer, title, bucket string, ranked []rankedBarkpark) {
	rows := make([]rankedBarkpark, 0)
	for _, r := range ranked {
		if r.Bucket == bucket {
			rows = append(rows, r)
		}
	}
	if len(rows) == 0 {
		return
	}
	out.outf("")
	out.outf("%s (%d)", title, len(rows))
	renderStatusRows(out, rows)
}

// statusDash renders an empty status field as an em dash so columns stay
// scannable (the hzCell idiom), leaving non-empty values untouched.
func statusDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return sanitizeCell(s)
}

// renderStatusRows prints the fleet rows as an aligned, status-painted table.
// Widths are measured on BARE strings; each cell is then painted via
// out.paintCell (a no-op when color is off), so alignment is exact and
// --no-color / piped output carries no ANSI. STATUS/HEALTH/AGENT paint by their
// role; NAME/URL/DETAIL and the self-update cells match no role and stay plain.
//
// Four columns are CONDITIONAL — each appears only when at least one row in the
// bucket has something to say in it, so a bucket never pays width for a column it
// doesn't use and an older control plane (which emits none of the isu-w5 truth)
// renders byte-identical to before:
//
//   - UPDATE  running → latest (the behind marker) — only when versions are known
//   - CHANNEL the release channel (prod/staging) — only when the CP emits it
//   - POLICY  compact autoupdate flag (pin@tag / paused / off / auto)
//   - DETAIL  the control plane's own reason for a failure/suspension
//
// Column order keeps the urgent identity left (STATUS · NAME · UPDATE · CHANNEL ·
// HEALTH · AGENT · POLICY) and the long URL + optional DETAIL last, so the common
// case stays readable at 80 columns.
func renderStatusRows(out *writer, rows []rankedBarkpark) {
	// Decide which conditional columns this bucket needs.
	withUpdate, withChannel, withPolicy, withDetail := false, false, false, false
	for _, r := range rows {
		if updateCell(r.BP) != "" {
			withUpdate = true
		}
		if strings.TrimSpace(r.BP.Channel) != "" {
			withChannel = true
		}
		if policyCell(r.BP) != "" {
			withPolicy = true
		}
		if r.Detail != "" {
			withDetail = true
		}
	}

	headers := []string{"STATUS", "NAME"}
	if withUpdate {
		headers = append(headers, "UPDATE")
	}
	if withChannel {
		headers = append(headers, "CHANNEL")
	}
	headers = append(headers, "HEALTH", "AGENT")
	if withPolicy {
		headers = append(headers, "POLICY")
	}
	headers = append(headers, "URL")
	if withDetail {
		headers = append(headers, "DETAIL")
	}

	cells := make([][]string, 0, len(rows))
	for _, r := range rows {
		url := r.BP.URL
		if strings.TrimSpace(url) == "" {
			url = r.BP.Host
		}
		row := []string{r.Status, statusDash(r.BP.Name)}
		if withUpdate {
			row = append(row, statusDash(updateCell(r.BP)))
		}
		if withChannel {
			row = append(row, statusDash(r.BP.Channel))
		}
		row = append(row, statusDash(r.BP.HealthStatus), statusDash(r.BP.AgentStatus))
		if withPolicy {
			row = append(row, statusDash(policyCell(r.BP)))
		}
		row = append(row, statusDash(url))
		if withDetail {
			row = append(row, statusDash(r.Detail))
		}
		cells = append(cells, row)
	}
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = runewidth.StringWidth(h)
	}
	for _, row := range cells {
		for i, c := range row {
			if n := runewidth.StringWidth(c); n > widths[i] {
				widths[i] = n
			}
		}
	}
	out.outf("%s", joinCols(headers, widths))
	for _, row := range cells {
		out.outf("%s", joinColsPainted(out, row, widths))
	}
}

// printCloudStatusHelp writes `bp cloud status` usage.
func printCloudStatusHelp(out *writer) {
	const help = `bp cloud status — your fleet, triaged (charter decision 15).

USAGE
  bp cloud status [-o table|json|yaml]

WHAT IT SHOWS
  every Barkpark in your team's fleet, ranked most-urgent first and bucketed:

    ATTENTION   removal_failed · failed · suspended · degraded ·
                deploys_failing · behind · unmetered
    IN-FLIGHT   removing · provisioning
    HEALTHY     ok

  Two of those rungs read the box's own DEPLOY rate, not its heartbeat:

    deploys_failing   the box failed 20% or more of its terminal deploys in the
                      control plane's window — the rate rides in DETAIL with the
                      denominator it came from, plus how much of it the box
                      itself caused and how much was absorbed by re-queues
    unmetered         the box HAS sites and the rate could not be scored (too
                      small a sample). A silence, said out loud — never 'ok'

  A box with no sites at all stays 'ok' and says so in DETAIL: it has nothing to
  deploy, so it has not failed to report.

  Attention rows carry a DETAIL column with the control plane's own reason
  (provision error, deprovision error, suspension reason) when it has one.
  Status cells are colored by role (red = danger, yellow = warn, cyan = info,
  green = ok) on a tty; piped or --no-color output is plain text. Requires
  'bp login'. The states, ranks and colors are the cloud dashboard's own
  (charter decision 32) — one triage vocabulary, two surfaces.

  When the control plane reports self-update truth, three more columns light up
  (each only when a row uses it, so the table stays lean):

    UPDATE    the running → latest release (the arrow is the "behind" marker)
    CHANNEL   the release channel the box rides (prod / staging)
    POLICY    the autoupdate policy, compact: pin@<tag> · paused · off · auto

  Manage the policy with 'bp cloud autoupdate' and the fleet rollout with
  'bp cloud rollout'.

OUTPUT
  -o table   ranked, bucketed, colored (default on a tty)
  -o json    the ranked structure: {ok, count, buckets, barkparks[]}
  -o yaml    the same, as YAML`
	out.outf("%s", help)
}
