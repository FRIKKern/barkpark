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
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/mattn/go-runewidth"
)

// --- the vitals fences (charter D67) -----------------------------------------
//
// strainedLoad15PerCore is the PRIMARY strained fence: sustained load per core
// over the 15-minute average. 1.75 is deliberately above 1.0 — a box at exactly
// one runnable task per core is busy, not in trouble — and the 15m window means
// a burst cannot trip it.
//
// strainedLoad1PerCore is the FALLBACK, used only when the beat carries no
// load15 (an agent that predates dr-w5-s2). It is deliberately HIGHER: over a
// 1-minute window the same box reads noisier, so a coarser predicate at 2.0 can
// only UNDER-report strain, never over-report it. This is not the fence D52
// refused — D52 refused a HARDCODED CORE COUNT (a fabricated denominator); both
// arms here divide by the box's own reported cpu_cores or do not fire at all.
const (
	strainedLoad15PerCore = 1.75
	strainedLoad1PerCore  = 2.0
)

// fillingDiskPercent is the `filling` fence — the SAME number the usage meter
// already ships as its disk over_limit ceiling, cloud/lib/barkpark_cloud/usage.ex:
//
//	meter(value, @src_disk, measured_at, 100, 70, 90)
//
// It is duplicated here only because Go cannot read an Elixir module attribute;
// TestFillingThresholdMatchesUsageMeter reads that line out of usage.ex and
// fails if the two ever drift, which is the entire point of the rung: the
// verdict surface must stop saying HEALTHY about a box the meter surface is
// already calling over_limit.
const fillingDiskPercent = 90.0

// attentionStatus classifies one Barkpark into its charter-decision-15 status
// label. The ELEVEN labels (charter D69), MOST URGENT FIRST, are:
//
//  1. removal_failed — deprovision_status = "failed"
//  2. failed         — no host && provision_status = "failed"
//  3. suspended      — suspended = true (and not removing)
//  4. degraded       — live && (health_status != "up" || agent_status != "online")
//  5. strained       — live && sustained load per core over the D67 fence
//  6. filling        — live && disk_used_percent >= 90
//  7. unreported     — live && the CP has never heard a byte from the box
//  8. behind         — live && update_state = "behind"
//  9. removing       — deprovision_status ∈ {pending, claimed}
//  10. provisioning  — no host, nothing failed
//  11. ok            — live, healthy, current
//
// where "live" = a host is set with nothing in-flight/failed/suspended.
//
// EVALUATION ORDER IS NOT RANK ORDER for one arm, and that is deliberate: like
// the shipped console (app.js classifyBp), `unreported` is tested BEFORE
// `degraded`, because health_status/agent_status are CACHED last-reported
// columns — with last_seen_at null they were never measured and so cannot rank
// the box. Its URGENCY (rank 7) is expressed in the ladder, not in the switch.
// Every other arm is evaluated in rank order and the first match wins, so the
// remaining precedence (a removing box that is also suspended is "removing"; a
// live box that is both strained and behind is "strained") falls out of the
// ordering itself.
//
// Charter edge left as specified: a box with a host SET and provision_status =
// "failed" matches no decision-15 rule (rank 2 requires no host; the live arms
// require live, which a failed provision is not) and falls through to "ok".
// Both surfaces implement the charter verbatim, so changing it here alone would
// create exactly the drift D32 exists to prevent — if this state is reachable,
// amend decision 15 first, then both implementations together.
func attentionStatus(b cloudclient.Barkpark) string {
	host := strings.TrimSpace(b.Host)
	removing := b.DeprovisionStatus == "pending" || b.DeprovisionStatus == "claimed"
	// live: a real host, no in-flight removal, not suspended, not a failed provision.
	live := host != "" && !removing && !b.Suspended && b.ProvisionStatus != "failed"

	switch {
	case b.DeprovisionStatus == "failed":
		return "removal_failed"
	case host == "" && b.ProvisionStatus == "failed":
		return "failed"
	case b.Suspended && !removing:
		return "suspended"
	// Console precedence (app.js classifyBp): never-reported outranks the cached
	// health columns as an EXPLANATION, even though it ranks below them.
	case live && strings.TrimSpace(b.LastSeenAt) == "":
		return "unreported"
	case live && (b.HealthStatus != "up" || b.AgentStatus != "online"):
		return "degraded"
	case live && strained(b):
		return "strained"
	case live && filling(b):
		return "filling"
	case live && b.UpdateState == "behind":
		return "behind"
	case removing:
		return "removing"
	case host == "":
		return "provisioning"
	default:
		return "ok"
	}
}

// loadPerCore returns the sustained load-per-core reading the strained fence
// judges, WITH the fence it must clear and a human name for the averaging
// window it came from. ok is false whenever the box did not give us enough to
// judge — that is D42's factual arm, verbatim: a nil vital never strains.
//
// Preference is load15 (the 15-minute average, the honest "sustained" signal);
// an agent that predates it falls back to load1 against a HIGHER fence.
func loadPerCore(b cloudclient.Barkpark) (perCore, fence float64, window string, ok bool) {
	p := b.Pressure
	if p == nil || p.CPUCores == nil || *p.CPUCores <= 0 {
		return 0, 0, "", false
	}
	switch {
	case p.Load15 != nil:
		return *p.Load15 / *p.CPUCores, strainedLoad15PerCore, "15m avg", true
	case p.Load1 != nil:
		return *p.Load1 / *p.CPUCores, strainedLoad1PerCore, "1m avg", true
	default:
		return 0, 0, "", false
	}
}

// strained reports whether the box's sustained load per core is over the D67
// fence. Swap NEVER triggers this — it only enriches the reason string — and an
// unmeasured box is NEVER strained.
func strained(b cloudclient.Barkpark) bool {
	perCore, fence, _, ok := loadPerCore(b)
	return ok && perCore >= fence
}

// filling reports whether the box's disk is at or past the usage meter's own
// over_limit ceiling. A nil reading is never filling.
func filling(b cloudclient.Barkpark) bool {
	p := b.Pressure
	return p != nil && p.DiskUsedPercent != nil && *p.DiskUsedPercent >= fillingDiskPercent
}

// strainedReason renders the WHY for a strained row. It says LOAD and never
// CPU: load1/load15 count uninterruptible sleep, so a box stalled on I/O is
// honestly under load while its CPU sits idle — naming it "CPU" would send an
// operator to the wrong instrument. It also names WHICH average it used, so a
// reading taken through the less-sensitive fallback is legible as such.
//
// Swap, when the box reported it, is APPENDED as evidence — a box paging itself
// to death is the story behind the load — but it can never produce this string
// on its own.
func strainedReason(b cloudclient.Barkpark) string {
	perCore, _, window, ok := loadPerCore(b)
	if !ok {
		return ""
	}
	// Which raw load produced perCore — the SAME preference loadPerCore made, so
	// the number and the window it is labelled with can never disagree.
	p := b.Pressure
	var load float64
	if p.Load15 != nil {
		load = *p.Load15
	} else {
		load = *p.Load1
	}
	reason := fmt.Sprintf("load %s on %s cores (%.1fx, %s)",
		trimFloat(round1(load)), trimFloat(*p.CPUCores), perCore, window)
	if swap := swapInUse(p); swap != "" {
		reason += " · " + swap + " in swap"
	}
	return reason
}

// swapInUse renders how many bytes the box is actually paging, or "" when it
// did not report enough to say. swap_used_percent travels WITH swap_total_bytes
// on purpose (router.ex): a bare percent cannot separate a swapless box from an
// idle one, so both are required before we claim anything.
func swapInUse(p *cloudclient.Pressure) string {
	if p == nil || p.SwapUsedPercent == nil || p.SwapTotalBytes == nil {
		return ""
	}
	used := *p.SwapTotalBytes * *p.SwapUsedPercent / 100
	if used <= 0 {
		return ""
	}
	return humanBytes(used)
}

// fillingReason renders the WHY for a filling row, naming the fence it crossed
// so the number is not just an assertion.
func fillingReason(b cloudclient.Barkpark) string {
	if b.Pressure == nil || b.Pressure.DiskUsedPercent == nil {
		return ""
	}
	return fmt.Sprintf("disk %s%% used (fills at %s%%)",
		trimFloat(round1(*b.Pressure.DiskUsedPercent)), trimFloat(fillingDiskPercent))
}

// unmeteredMarker is the DETAIL LINE (charter D69 — deliberately NOT a rung; a
// rung for it would be vocabulary for a state that is really a rollout gap).
// A box whose pressure block carries a reported_at — it IS beating — but a null
// cpu_cores is definitionally running an agent that predates the vitals beat:
// we can see it alive and cannot read a single vital off it. An operator should
// SEE that, rather than infer it from an absence and read the row as ordinary.
//
// It is keyed on the PRESENCE of reported_at, not on its age: no measurement in
// this wave justifies a staleness window, and inventing one would be exactly the
// fabricated number the honesty law exists to refuse.
func unmeteredMarker(b cloudclient.Barkpark) string {
	p := b.Pressure
	if p == nil || p.ReportedAt == nil || strings.TrimSpace(*p.ReportedAt) == "" {
		return "" // never beat at all — that is `unreported`, a different fact
	}
	if p.CPUCores != nil {
		return "" // vitals readable
	}
	return "vitals unreadable — agent predates the vitals beat"
}

// round1 rounds to one decimal so a rendered load reads like an instrument, not
// like a float dump.
func round1(n float64) float64 { return math.Round(n*10) / 10 }

// attentionRankOrder is the decision-15 / D69 ordering, most urgent first.
// Index+1 is the charter rank (1–11), exactly as the decision-32 fixture pins
// it. The eight pre-existing states keep their RELATIVE order and every one of
// them keeps its bucket — only the integers moved.
var attentionRankOrder = []string{
	"removal_failed", // 1
	"failed",         // 2
	"suspended",      // 3
	"degraded",       // 4
	"strained",       // 5
	"filling",        // 6
	"unreported",     // 7
	"behind",         // 8
	"removing",       // 9
	"provisioning",   // 10
	"ok",             // 11
}

// attentionRank is the sort key for a status label — its charter rank, 1 (most
// urgent) through 11 (ok), matching the decision-32 fixture byte-for-byte. An
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
// (ranks 1–8: removal_failed…behind), in-flight (9–10: removing/provisioning),
// healthy (11: ok). The bucket strings are the decision-32 fixture's, verbatim —
// note "in-flight" is hyphenated there, so it is hyphenated here and in -o json.
//
// The boundary is stated as a MEMBERSHIP switch, not as a rank comparison, so a
// new state that someone forgets to rank cannot silently land in HEALTHY — the
// exact inversion this epic exists to kill. Anything unrecognised surfaces in
// attention.
func attentionBucket(status string) string {
	switch status {
	case "removing", "provisioning":
		return "in-flight"
	case "ok":
		return "healthy"
	default:
		// removal_failed, failed, suspended, degraded, strained, filling,
		// unreported, behind — and any unknown label defensively surfaces in the
		// attention bucket rather than hiding.
		return "attention"
	}
}

// attentionDetail is the one-line WHY behind an attention status — the reason
// the control plane already told us, surfaced instead of hoarded: the
// deprovision error for removal_failed, the provision error for failed, the
// suspension reason for suspended, the measured vitals for strained/filling.
// States whose row already explains itself (degraded shows health/agent, behind
// IS the message) yield "".
//
// The UNMETERED MARKER rides on top of whatever the status said, on ANY row: a
// box we cannot read is a fact about the reading, not about the verdict.
func attentionDetail(b cloudclient.Barkpark, status string) string {
	var reason string
	switch status {
	case "removal_failed":
		reason = strings.TrimSpace(b.DeprovisionError)
	case "failed":
		reason = strings.TrimSpace(b.ProvisionError)
	case "suspended":
		reason = strings.TrimSpace(b.SuspendedReason)
	case "strained":
		reason = strainedReason(b)
	case "filling":
		reason = fillingReason(b)
	}
	marker := unmeteredMarker(b)
	switch {
	case reason == "":
		return marker
	case marker == "":
		return reason
	default:
		return reason + " · " + marker
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
//
// git_commit is the SERVING COMMIT (dr-w21-s3). It was missing here for a plain
// reason: this map is hand-built, and the key was simply never typed. The wire
// type decodes it (cloudclient.Barkpark.GitCommit), `GET /v1/barkparks` emits it,
// and cloudBarkparkRow (cloud12_cmd.go) — the SAME struct off the SAME endpoint —
// has always projected it, which is why `bp barkparks -o json` prints real shas
// while `bp cloud status -o json` printed nothing. A projection gap, not a decode
// gap and not a route gap. The key is ALWAYS present (empty string when the
// control plane has no commit for the box) so a consumer can tell "we asked and
// the plane does not know" from "this CLI never asked" — the table renders that
// empty as UNMETERED rather than a blank.
//
// The registry `version` field is deliberately NOT here under any name. It is the
// AGENT BINARY version (internal/agent/report.go `const Version = "0.1.0"`), a
// compile-time constant that reads 0.1.0 fleet-wide while the boxes serve app
// versions 0.2.25.164 … 0.2.25.2628. Emitting it beside the commit would put a
// number that can never move next to one that does, and it would read as
// freshness. If it is ever wanted it ships as `agent_version`, named for what it
// is.
func rankedBarkparkRow(r rankedBarkpark) map[string]any {
	row := map[string]any{
		"git_commit":             r.BP.GitCommit,
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

// commitUnmetered is what the COMMIT column prints for a box whose serving
// commit the control plane does not know. It is LOUD on purpose and it is the
// deploy line's own word (statusDeployWindow's refusal vocabulary): the box that
// forced it is muscle-1, whose registry git_commit is "" because its agent is
// offline — and which still reads update_state `current`. A blank cell or an em
// dash there would read as "fine", which is exactly the unearned green this epic
// exists to kill.
const commitUnmetered = "UNMETERED"

// commitCell renders one row's serving commit for the table: the short sha when
// the control plane knows it, the loud sentinel when it does not. It never
// fabricates and it never returns "" — a row in this column always says
// something.
//
// It is a LABEL, not a verdict: a sha alone cannot say whether the box is behind.
// The commit-distance verdict is computed on the control plane (dr-w21-s2) and
// reaches this surface in dr-w21-s4. Nothing here feeds attentionStatus,
// attentionRank or the sort, so an unknown commit cannot ride to the top of a
// bucket NOR be sorted as fresh — it simply stands there saying UNMETERED.
func commitCell(b cloudclient.Barkpark) string {
	sha := strings.TrimSpace(b.GitCommit)
	if sha == "" {
		return commitUnmetered
	}
	return sanitizeCell(shortSha(sha))
}

// fleetKnowsCommit reports whether ANY row in the whole fleet carries a serving
// commit — the switch for the COMMIT column.
//
// It is measured fleet-wide and not per bucket on purpose. Per bucket, a lone
// unknown box sitting by itself in ATTENTION (muscle-1's exact shape) would turn
// the column OFF and silence the very row the column exists for. Fleet-wide, one
// box that knows its commit makes every bucket accountable for saying whether it
// knows its own. A control plane that reports no commit at all still renders
// byte-identical to before — the older-CP honesty rule the neighbouring
// conditional columns already follow.
func fleetKnowsCommit(ranked []rankedBarkpark) bool {
	for _, r := range ranked {
		if strings.TrimSpace(r.BP.GitCommit) != "" {
			return true
		}
	}
	return false
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
	// Decided ONCE, over the whole fleet, so every bucket answers the same
	// question (see fleetKnowsCommit).
	withCommit := fleetKnowsCommit(ranked)
	renderStatusBucket(out, "ATTENTION", "attention", ranked, withCommit)
	renderStatusBucket(out, "IN-FLIGHT", "in-flight", ranked, withCommit)
	renderStatusBucket(out, "HEALTHY", "healthy", ranked, withCommit)
	renderStatusDeploy(out, cfg, ranked)
	return exitOK
}

// renderStatusBucket prints one bucket section (header + painted table) when it
// has rows, in the already-sorted order. Silent for an empty bucket so the view
// stays lean.
//
// withCommit is passed IN rather than derived from this bucket's rows, so the
// COMMIT column is decided once over the whole fleet (see fleetKnowsCommit).
func renderStatusBucket(out *writer, title, bucket string, ranked []rankedBarkpark, withCommit bool) {
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
	renderStatusRowsWith(out, rows, withCommit)
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
// COMMIT (dr-w21-s3) is a FIFTH conditional column, and the one column whose
// switch is NOT read off this row-set: it is decided fleet-wide by the caller, so
// a bucket holding only unknown-commit rows still prints UNMETERED rather than
// dropping the column and going quiet. Once on, every row says something —
// commitCell never returns "".
//
// Column order keeps the urgent identity left (STATUS · NAME · UPDATE · COMMIT ·
// CHANNEL · HEALTH · AGENT · POLICY) and the long URL + optional DETAIL last, so
// the common case stays readable at 80 columns. COMMIT sits beside UPDATE because
// they answer the same question — what code is this box running.
func renderStatusRows(out *writer, rows []rankedBarkpark) {
	renderStatusRowsWith(out, rows, fleetKnowsCommit(rows))
}

// renderStatusRowsWith is renderStatusRows with the COMMIT switch supplied.
func renderStatusRowsWith(out *writer, rows []rankedBarkpark, withCommit bool) {
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
	if withCommit {
		headers = append(headers, "COMMIT")
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
		if withCommit {
			// NOT statusDash: an unknown commit is UNMETERED, never an em dash.
			row = append(row, commitCell(r.BP))
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

// --- the deploy line (dr-w19-s7) ---------------------------------------------
//
// `bp cloud status` answered "is the box up" and never "does the box ship".
// On 2026-08-07 the fleet's live rate read 27.4% (3.65 attempts per live
// deployment) against 91.7–95.6% three weeks earlier, and every row on this
// screen still said `ok` — the box WAS up. The deploy section below is that
// missing sentence, and nothing more.
//
// IT IS A GAUGE, NEVER A FENCE (charter D330). There is deliberately NO new
// attention rung, NO verdict arm and NO hardcoded floor here: any threshold
// calibrated on healthy July makes today permanently red, which is precisely
// the over-alarm objection wave 18 levelled at raw absorption. The over-alarm
// problem MOVES with the term; swapping terms does not solve it. So the rate is
// printed WITH its denominator, under its window, and it never changes a
// status, a rank or a bucket — the decision-32 vocabulary is untouched.
//
// IT REFUSES ABOVE ALL: below the census's own @min_sample (deploy_ledger.ex
// :264) the line is UNMETERED with the reason, never a percentage and never a
// green. It refuses the same way when the control plane sends no per-site
// `live` at all, when it sends no min_sample, and when the census or the site
// list could not be read — four distinct absences, four distinct sentences,
// none of them a zero.

// statusDeployWindow is the width of the pinned window the deploy line is taken
// over: ONE DAY. The period is daily and not hourly because that is where the
// census's @min_sample of 200 is actually reachable — 6 of 432 hourly buckets
// clear it (0 of 20 in the post-cut regime, max hour 100, half the floor)
// against 20 of 21 daily buckets. An hourly line would be UNMETERED forever.
const statusDeployWindow = 24 * time.Hour

// statusDeployNow is the clock the window is computed against — a package var
// (the deployCensusNow idiom) so a test can pin the window it asserts.
var statusDeployNow = func() time.Time { return time.Now().UTC() }

// statusDeployBox is one box's fold of the census site rows attributed to it.
//
// LiveKnown is the honesty bit: a control plane predating #10519 sends site rows
// with no `live` key, DeployCensusSite.Live decodes to nil, and summing nils
// would report every box as shipping nothing. One nil row poisons the whole
// box's live count, which is the correct direction — a partial sum is not a
// measurement.
type statusDeployBox struct {
	Volume    int
	Live      int
	Sites     int
	LiveKnown bool
}

// statusDeployFold attributes census site rows to boxes via the site list
// (census rows carry site_id; cloudclient.Site carries BarkparkID), and returns
// the per-box fold plus the rows it could NOT attribute — a site the fleet
// listing does not cover is reported, never silently dropped into nobody's
// numbers.
func statusDeployFold(census cloudclient.DeployCensus, sites []cloudclient.Site) (map[string]*statusDeployBox, int, int) {
	owner := make(map[string]string, len(sites))
	for _, s := range sites {
		if id := strings.TrimSpace(s.BarkparkID); id != "" {
			owner[s.ID] = id
		}
	}
	boxes := make(map[string]*statusDeployBox, len(owner))
	orphanRows, orphanVolume := 0, 0
	for _, row := range census.Sites {
		bid, attributed := owner[row.SiteID]
		if !attributed {
			orphanRows++
			orphanVolume += row.Volume
			continue
		}
		b := boxes[bid]
		if b == nil {
			b = &statusDeployBox{LiveKnown: true}
			boxes[bid] = b
		}
		b.Volume += row.Volume
		b.Sites++
		// READ POSITIVELY OFF THE WIRE. `Volume - Failed - Deferred` is
		// forbidden: it folds in-flight, cancelled and residual rows back into
		// live and re-creates the unnamed remainder dr-w16-s2 deleted.
		if row.Live == nil {
			b.LiveKnown = false
		} else {
			b.Live += *row.Live
		}
	}
	return boxes, orphanRows, orphanVolume
}

// statusDeployLine renders ONE box's deploy line: the live rate with its
// denominator, or the named refusal. Every arm that is not a measurement says
// UNMETERED and says why; none of them is ever a 0%.
func statusDeployLine(b *statusDeployBox, minSample int) string {
	if b == nil || b.Volume == 0 {
		return "no deploy rows in this window — nothing was attempted here, which is not the same as nothing failing"
	}
	if !b.LiveKnown {
		return fmt.Sprintf("UNMETERED — %d attempted; this control plane sends no per-site `live`, so whether anything shipped is unknown (never read this as zero)", b.Volume)
	}
	if minSample <= 0 {
		return fmt.Sprintf("UNMETERED — %d attempted, %d live; this control plane sent no min_sample, so nothing says whether a percentage on this sample is a measurement", b.Volume, b.Live)
	}
	if b.Volume < minSample {
		return fmt.Sprintf("UNMETERED — %d attempted is below the census min_sample of %d (%d live); a percentage on this sample would be noise", b.Volume, minSample, b.Live)
	}
	return fmt.Sprintf("live %d/%d (%s)", b.Live, b.Volume, pctOf(float64(b.Live), float64(b.Volume)))
}

// statusDeployReadFailure renders a census that could NOT be read, reusing the
// verb's own refusal sentences (deployCensusMessage) so `bp cloud status` and
// `bp cloud deployments` cannot tell an operator two different stories about the
// same 403. A non-census error (transport, a proxy) still names itself.
func statusDeployReadFailure(from, to time.Time, err error) string {
	var ce *cloudclient.DeployCensusError
	if errors.As(err, &ce) {
		return deployCensusMessage(from, to, ce)
	}
	return "could not read the deploy census for your team: " + err.Error() + ". Nothing was read: this is NOT a fleet with zero failures."
}

// renderStatusDeploy prints the DEPLOY section: one line per box in the same
// rank order as the tables above, carrying the box's live rate WITH its
// denominator over a pinned DAILY window — or the refusal that stopped it being
// a number.
//
// TABLE ONLY, ON PURPOSE. `-o json` emits the decision-15 ranked structure whose
// keys scripts already consume; this section costs two extra control-plane reads
// and is a human triage line, so it does not silently change that contract.
// `bp cloud deployments` is the machine-readable reader of the same census.
func renderStatusDeploy(out *writer, cfg *Config, ranked []rankedBarkpark) {
	to := statusDeployNow().UTC().Truncate(time.Second)
	from := to.Add(-statusDeployWindow)

	out.outf("")
	out.outf("DEPLOY · period: DAILY · window %s", deployCensusWindowPhrase(from, to))
	out.outf("  live_rate is a GAUGE and not a fence: it carries its own denominator, refuses a percentage below the census min_sample, and changes no status above.")

	census, cerr := cfg.CloudClient().FleetDeployCensus(cloudCtx(), from, to)
	if cerr != nil {
		out.outf("  NOT READ — %s", statusDeployReadFailure(from, to, cerr))
		return
	}
	sites, serr := cfg.CloudClient().ListSites(cloudCtx())
	if serr != nil {
		out.outf("  NOT ATTRIBUTED — the census was read (%d attempted rows over this window) but the site list was not: %s. Without it a census row cannot be tied to a box; `bp cloud deployments` reads the same window fleet-wide.",
			census.Volume, serr.Error())
		return
	}

	boxes, orphanRows, orphanVolume := statusDeployFold(census, sites)
	width := 0
	for _, r := range ranked {
		if n := runewidth.StringWidth(r.BP.Name); n > width {
			width = n
		}
	}
	for _, r := range ranked {
		name := sanitizeCell(r.BP.Name)
		pad := width - runewidth.StringWidth(r.BP.Name)
		if pad < 0 {
			pad = 0
		}
		out.outf("  %s%s  %s", name, strings.Repeat(" ", pad), statusDeployLine(boxes[r.BP.ID], census.MinSample))
	}
	if orphanRows > 0 {
		out.outf("  %d census site row(s) (%d attempted) belong to no box in this fleet listing and are in NO line above — run `bp cloud deployments` to see them.",
			orphanRows, orphanVolume)
	}
}

// printCloudStatusHelp writes `bp cloud status` usage.
func printCloudStatusHelp(out *writer) {
	const help = `bp cloud status — your fleet, triaged (charter decision 15).

USAGE
  bp cloud status [-o table|json|yaml]

WHAT IT SHOWS
  every Barkpark in your team's fleet, ranked most-urgent first and bucketed:

    ATTENTION   removal_failed · failed · suspended · degraded · strained ·
                filling · unreported · behind
    IN-FLIGHT   removing · provisioning
    HEALTHY     ok

  Two of those rungs read the box's own vitals off its latest health beat:

    strained    sustained load per core over the fence (15m average; a box
                whose agent predates load15 falls back to the 1m average
                against a higher, less sensitive one). Says LOAD, not CPU —
                load counts I/O wait, so a stalled box counts even at 0% CPU.
    filling     disk at or past 90% used — the SAME ceiling 'bp cloud usage'
                already calls over_limit, so the two views cannot disagree.

  A box that reports nothing measurable is NEVER strained or filling: an
  unmeasured vital reads "we did not measure", never "measured, and it is fine".
  A box that is beating but whose agent predates the vitals beat says so on its
  own row rather than passing silently as healthy.

  Attention rows carry a DETAIL column with the control plane's own reason
  (provision error, deprovision error, suspension reason, the measured load or
  disk reading) when it has one.
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

  A DEPLOY section follows the tables: one line per box carrying its live rate
  WITH its denominator (live 525/1914) over a pinned DAILY window of the team
  deploy census — because a box can be perfectly 'ok' and still ship nothing.
  It is a GAUGE, not a fence: no status, rank or bucket above reads it, and
  below the census min_sample the line says UNMETERED and why, never a
  percentage and never a green. The same four absences the census has are four
  distinct sentences here (census unreadable, sites unattributable, no per-site
  live from an older control plane, sample below the floor) and not one of them
  renders as a zero. 'bp cloud deployments' is the full, machine-readable read
  of the same census; the DEPLOY section is table-output only.

OUTPUT
  -o table   ranked, bucketed, colored (default on a tty), plus the DEPLOY lines
  -o json    the ranked structure: {ok, count, buckets, barkparks[]}
  -o yaml    the same, as YAML`
	out.outf("%s", help)
}
