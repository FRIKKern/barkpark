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
	"strconv"
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
// label. The TWELVE labels (charter D69 + jpf-w1 D7), MOST URGENT FIRST, are:
//
//  1. removal_failed — deprovision_status = "failed"
//  2. failed         — no host && provision_status = "failed"
//  3. suspended      — suspended = true (and not removing)
//  4. degraded       — live && (health_status != "up" || agent_status != "online")
//  5. strained       — live && sustained load per core over the D67 fence
//  6. filling        — live && disk_used_percent >= 90
//  7. unreported     — live && the CP has never heard a byte from the box
//  8. deploy_stalled — live && a queued deployment no builder has claimed for 5m
//  9. behind         — live && (update_state = "behind" || commit_ancestry = "behind")
//  10. removing      — deprovision_status ∈ {pending, claimed}
//  11. provisioning  — no host, nothing failed
//  12. ok            — live, healthy, current
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
	// A current control plane ALWAYS emits queued_deploy_age_seconds, including
	// an explicit null when nothing is queued. Missing is therefore a broken or
	// pre-contract producer, not evidence that the deploy queue is healthy.
	case live && b.QueuedDeployAgeSecondsMissing:
		return "degraded"
	case live && strained(b):
		return "strained"
	case live && filling(b):
		return "filling"
	// jpf-w1 D7: a queued deployment no builder has claimed for 5 minutes.
	// AFTER the vitals rungs — a degraded/strained box's stuck queue is a
	// SYMPTOM, so the box's own condition outranks it — and BEFORE `behind`:
	// a deploy someone asked for and nobody is building is more urgent than
	// passive update drift.
	case live && deployStalled(b):
		return "deploy_stalled"
	// TWO independent sources can say `behind`, and until dr-w24-s2 only the
	// weaker one was read (see behindByCommits). The rung is UNCHANGED — same
	// label, same bucket, same decision-32 vocabulary (rank 8 → 9 with the
	// deploy_stalled insertion) — it simply stops missing the boxes whose
	// release-tag grade cannot express the gap.
	case live && (b.UpdateState == "behind" || behindByCommits(b)):
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

// queuedDeployStalledAfterSeconds is the `deploy_stalled` fence (jpf-w1 D6/D7):
// how long a queued container-site deployment may sit with NO builder claiming
// it before the fleet screen says so. The CLIENT owns this number by design —
// the control plane serves only the raw `queued_deploy_age_seconds` — and it is
// deliberately ONE THIRD of the CP's 15-minute StaleDeploymentReaper horizon
// (registry.ex `queued_deploy_alarm_after_seconds`, default 300, documents the
// same relationship server-side): the reaper is a MUTATING builder-lease sweep
// that is claimed_at-gated and can NEVER see a never-claimed row; this alarm
// exists for exactly that orphan class, because the builder is structurally
// silent on failure (Run() discards claim errors unlogged).
const queuedDeployStalledAfterSeconds = 300

// deployStalled reports whether the box has a queued deployment older than the
// fence. nil NEVER stalls — it is both "nothing queued" and "a CP that predates
// the field", and neither is a measured problem (the same honest-silence rule
// the vitals fences keep: an alarm may only fire on a number it was given).
func deployStalled(b cloudclient.Barkpark) bool {
	return b.QueuedDeployAgeSeconds != nil && *b.QueuedDeployAgeSeconds >= queuedDeployStalledAfterSeconds
}

func queuedDeployAgeMarker(b cloudclient.Barkpark) string {
	if !b.QueuedDeployAgeSecondsMissing {
		return ""
	}
	return "deploy queue unreadable — control plane omitted queued_deploy_age_seconds"
}

// deployStalledReason renders the WHY for a deploy_stalled row: how long the
// oldest queued deployment has waited and the fact that makes the wait a
// problem — no builder has claimed it. Empty when the fence did not fire, so
// it can never assert a stall it did not measure.
func deployStalledReason(b cloudclient.Barkpark) string {
	if !deployStalled(b) {
		return ""
	}
	return fmt.Sprintf("deploy queued %s — no builder claimed it",
		humanElapsed(*b.QueuedDeployAgeSeconds))
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

// --- the runaway marker (the 2026-08-06 guerrilla incident) -------------------
//
// WHAT HAPPENED, because the shape of this function is dictated by it: an SSH
// session died and left `journalctl -u bp-site-build-* --since -14d --no-pager`
// reparented to PID 1, scanning fourteen days of journal for a unit glob that
// matched nothing, at 66.3% of a core, for 2h46m, on a box with two cores. Load
// hit 6.3, https://guerrilla.barkpark.cloud/api/schemas flapped 200/500/500, and
// the ONLY thing that noticed was a human's `bp task claim` failing with a
// transient error. Every vital this screen already renders was an AGGREGATE —
// load, cpu, mem — and an aggregate can say a box is being spent but never by
// WHOM, which is the only thing an operator can act on.
//
// It is a DETAIL LINE and deliberately NOT a rung, exactly like unmeteredMarker
// above. The decision-15 vocabulary is pinned across three surfaces by the
// decision-32 fixture (attention_order.json) and the SPA mirrors it; a twelfth
// status invented here alone would be the drift D32 exists to prevent. It rides
// on top of whatever the status said, on ANY row — including a row that reads
// `ok`, which is precisely the row the incident was sitting on for its first
// two hours, before the load average caught up and made it `strained`.
//
// It never fabricates: an unmeasured box (nil list — an agent predating the
// probe, or a box with no `ps`) and a measured-quiet box (an empty list) both
// render "", because neither has a runaway to name. Those two ARE distinguished
// on the wire and in `-o json`; what they are not is a sentence on a table row
// claiming something happened.
func runawayMarker(b cloudclient.Barkpark) string {
	p := b.Pressure
	if p == nil || len(p.RunawayProcs) == 0 {
		return ""
	}
	worst := p.RunawayProcs[0]
	// The three facts the incident report needed and did not have: how long, how
	// much, and — the one that ends the investigation — what.
	s := fmt.Sprintf("runaway: pid %d orphaned %s at %s%% CPU — %s",
		int(worst.PID), humanElapsed(worst.ElapsedS),
		trimFloat(round1(worst.CPUPercent)), truncateCell(worst.Command, runawayCommandCell))
	if n := len(p.RunawayProcs) - 1; n > 0 {
		// The count is carried even though the commands are not: a box with FOUR
		// abandoned journalctls is a different story from a box with one, and
		// `-o json` has all of them.
		s += fmt.Sprintf(" (+%d more)", n)
	}
	return s
}

// runawayCommandCell caps the argv INSIDE the table cell. The agent already caps
// what it sends (120 runes); this is the narrower cap the DETAIL column can
// carry without pushing the URL off an 80-column terminal. The full command the
// agent sent is always in `-o json`, so the table never becomes the only copy.
const runawayCommandCell = 48

// humanElapsed renders a process age the way an operator says it out loud —
// "2h46m", not "10001". Seconds below a minute keep their unit rather than
// rounding to "0m", because a detector that reports a young process at all is
// reporting something surprising and the number should not be flattened.
func humanElapsed(seconds float64) string {
	if seconds < 0 {
		return "?"
	}
	total := int(seconds)
	switch {
	case total < 60:
		return fmt.Sprintf("%ds", total)
	case total < 3600:
		return fmt.Sprintf("%dm", total/60)
	default:
		return fmt.Sprintf("%dh%02dm", total/3600, (total%3600)/60)
	}
}

// --- commit distance (dr-w24-s2) ---------------------------------------------
//
// `update_state` is the box's RELEASE-TAG self-grade; `commit_ancestry` /
// `commit_distance` are the control plane's own compare of the sha the box
// actually serves against `main`. They answer different questions and they
// disagree in production right now — one row reads commit_distance 2493,
// commit_ancestry "behind", update_state "current" — because no release tag has
// been cut since 2026-07-08, so every box that reached the newest tag is pinned
// at `current` however far main runs ahead. (update_state is NOT structurally
// incapable of saying `behind`: a live row says exactly that today, 0.2.24 vs
// 0.2.25. It just cannot see an untagged gap.)
//
// The measurement has been written hourly and read by NOBODY: before this slice
// no serializer, no CLI and no console carried it. These four functions are the
// whole reader.

// commitDistanceUnmetered is what the BEHIND column prints for a box the plane
// asked about and could not grade. Loud on purpose, and never a number: a NULL
// distance rendered as `0` would say "even with main" about a box nobody could
// measure — an unearned green in a brand-new column. Three prod rows are NULL
// today (the three whose git_commit is empty), and a GitHub rate-limit 403 is
// indistinguishable from a 404 here (the shared HTTP client discards headers),
// so this cell is a day-one case, not a hypothetical.
const commitDistanceUnmetered = "UNMETERED"

// behindByCommits reports whether the CONTROL PLANE measured this box as behind
// `main`, independent of what the release-tag grade says. This is the arm that
// was missing from attentionStatus: a 2,493-behind box whose update_state reads
// `current` never entered ATTENTION, so the one honest column and the one
// reassuring column sat in the SAME ROW and only the reassuring one reached a
// human.
func behindByCommits(b cloudclient.Barkpark) bool {
	return strings.TrimSpace(b.CommitAncestry) == "behind"
}

// commitDistanceUnknown reports a box the plane MEASURED and could not grade —
// an ancestry it did tell us, with no number behind it. It is deliberately NOT
// true for a control plane that sent no ancestry at all: that plane predates the
// emission and has said nothing, which is a different fact and must not push
// every legacy row to the top of its bucket.
func commitDistanceUnknown(b cloudclient.Barkpark) bool {
	return strings.TrimSpace(b.CommitAncestry) != "" && b.CommitDistance == nil
}

// behindCell renders one row's commit distance for the BEHIND column. Empty ONLY
// for a control plane that sent no ancestry (the older-CP rule the neighbouring
// conditional columns already follow — the column then collapses out entirely
// and the view is byte-identical to before). Once the plane speaks, every row
// says something, and an ungradeable row says UNMETERED rather than a number it
// does not have.
func behindCell(b cloudclient.Barkpark) string {
	ancestry := strings.TrimSpace(b.CommitAncestry)
	if ancestry == "" {
		return ""
	}
	if b.CommitDistance == nil {
		return commitDistanceUnmetered
	}
	n := strconv.Itoa(*b.CommitDistance)
	switch ancestry {
	case "current":
		// A MEASURED zero — the box serves a commit identical to main.
		return "even"
	case "behind":
		return n
	case "ahead_of_main":
		return "ahead " + n
	case "diverged":
		// Missing n commits AND carrying code main does not have. Rendered, not
		// ranked: widening the attention ladder is a charter decision, not this
		// slice's (filed as dr-w24-followup-diverged-is-not-ranked).
		return "diverged " + n
	default:
		return sanitizeCell(ancestry)
	}
}

// behindDetail is the WHY for a row that is behind BY COMMITS — the sentence
// that keeps the release-tag grade from reading as an all-clear beside it. A row
// that is behind by its own release tag keeps the pre-existing "" (behind IS the
// message there, and the UPDATE column already shows running → latest).
func behindDetail(b cloudclient.Barkpark) string {
	if !behindByCommits(b) {
		return ""
	}
	reason := "behind main by an unmeasured number of commits"
	if b.CommitDistance != nil {
		reason = fmt.Sprintf("%d commits behind main", *b.CommitDistance)
	}
	// Name the disagreement explicitly when the tag grade says anything other
	// than behind — that contradiction IS the finding, and an operator reading
	// `current` elsewhere on the row deserves to be told why it is there.
	if grade := strings.TrimSpace(b.UpdateState); grade != "" && grade != "behind" {
		reason += " · release-tag grade still reads " + sanitizeCell(grade)
	}
	return reason
}

// --- serving commit (dr-w21-s3) ----------------------------------------------
//
// The sha above is the FACT; the commit-distance block above it is the plane's
// GRADE of that fact. Both ship, because they fail differently: the plane can
// know what a box serves and still be unable to grade it (a rate-limited
// compare), and it can grade nothing at all because the box's agent is offline
// and never reported a sha.

// commitCell renders one row's serving commit for the COMMIT column: the short
// sha when the control plane knows it, the loud UNMETERED when it does not.
//
// It never fabricates and — unlike behindCell — it never returns "". Once the
// column is on, every row says something. That is why the column's switch cannot
// be read off this function (see fleetKnowsCommit): an empty sha is not the
// older-CP signal here, because a single row cannot distinguish "this plane does
// not emit commits" from "this box did not report one".
//
// It is a LABEL, not a verdict. A sha alone cannot say whether a box is behind —
// that is the BEHIND column, computed on the control plane. Nothing here feeds
// attentionStatus, attentionRank or the sort, so an unknown commit can neither
// climb to the top of a bucket NOR be sorted as fresh; it stands there saying
// UNMETERED.
//
// It reuses commitDistanceUnmetered rather than declaring a twin: UNMETERED is
// this file's one refusal word and it means the same thing in both columns — we
// asked, and we could not measure. A blank cell or an em dash would read as
// "fine", which is the unearned green this whole line of work exists to kill.
// The row that forces it is muscle-1: agent offline, git_commit "", and still
// reading update_state `current`.
func commitCell(b cloudclient.Barkpark) string {
	sha := strings.TrimSpace(b.GitCommit)
	if sha == "" {
		return commitDistanceUnmetered
	}
	// dr-w22-bl SINCE WHEN, appended only when the plane MEASURED it. The sha
	// alone answers "what is it running"; the operator's next question is always
	// "since when", and until this the only place to get that was
	// `GET /v1/barkparks/:id/events` — require_user, 200 rows a page, about
	// three hours of a fourteen-day history.
	//
	// A SUFFIX AND NOT A COLUMN, on purpose. An empty first-seen is the NORMAL
	// reading for a box that has not changed sha since the plane grew the column,
	// so a dedicated column would print UNMETERED down its whole length on a
	// perfectly healthy fleet and teach the reader to ignore the word. Absent
	// here simply means the cell is the bare sha it has always been — the older-CP
	// render, byte-identical, which is also what a plane that omits the key gets.
	if since := strings.TrimSpace(b.GitCommitFirstSeenAt); since != "" {
		return sanitizeCell(shortSha(sha) + " (since " + relativeAge(since) + ")")
	}
	return sanitizeCell(shortSha(sha))
}

// fleetKnowsCommit reports whether ANY row in the whole fleet carries a serving
// commit. It is the COMMIT column's switch, and it is the one conditional column
// whose switch is measured over the FLEET rather than over the bucket being
// rendered.
//
// That is deliberate, and it is the whole subtlety of this column. Per bucket, a
// lone unknown box sitting by itself in ATTENTION — muscle-1's exact shape —
// would turn the column OFF and silence the very row the column exists for.
// Fleet-wide, one box that knows its commit makes every bucket accountable for
// saying whether it knows its own.
//
// The older-CP honesty rule still holds at the other end: a control plane that
// reports no commit for any box turns the column off entirely and renders
// byte-identical to before, exactly as the neighbouring conditional columns do.
func fleetKnowsCommit(fleet []rankedBarkpark) bool {
	for _, r := range fleet {
		if strings.TrimSpace(r.BP.GitCommit) != "" {
			return true
		}
	}
	return false
}

// round1 rounds to one decimal so a rendered load reads like an instrument, not
// like a float dump.
func round1(n float64) float64 { return math.Round(n*10) / 10 }

// attentionRankOrder is the decision-15 / D69 / jpf-w1-D7 ordering, most
// urgent first. Index+1 is the charter rank (1–12), exactly as the decision-32
// fixture pins it. The pre-existing states keep their RELATIVE order and every
// one of them keeps its bucket — only the integers moved.
var attentionRankOrder = []string{
	"removal_failed", // 1
	"failed",         // 2
	"suspended",      // 3
	"degraded",       // 4
	"strained",       // 5
	"filling",        // 6
	"unreported",     // 7
	"deploy_stalled", // 8 (jpf-w1 D7 — after the box-condition rungs, before behind)
	"behind",         // 9
	"removing",       // 10
	"provisioning",   // 11
	"ok",             // 12
}

// attentionRank is the sort key for a status label — its charter rank, 1 (most
// urgent) through 12 (ok), matching the decision-32 fixture byte-for-byte. An
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
// (ranks 1–9: removal_failed…behind), in-flight (10–11: removing/provisioning),
// healthy (12: ok). The bucket strings are the decision-32 fixture's, verbatim —
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
		// unreported, deploy_stalled, behind — and any unknown label defensively
		// surfaces in the attention bucket rather than hiding.
		return "attention"
	}
}

// attentionDetail is the one-line WHY behind an attention status — the reason
// the control plane already told us, surfaced instead of hoarded: the
// deprovision error for removal_failed, the provision error for failed, the
// suspension reason for suspended, the measured vitals for strained/filling.
// States whose row already explains itself (degraded shows health/agent, a
// release-tag `behind` IS the message) yield "". A box behind BY COMMITS is the
// exception (dr-w24-s2): its release-tag grade is sitting on the same row saying
// `current`, so the row does NOT explain itself and behindDetail says so.
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
	case "deploy_stalled":
		reason = deployStalledReason(b)
	case "behind":
		// "" for a release-tag behind (the UPDATE column already says it); the
		// commit-distance sentence for a box whose tag grade disagrees.
		reason = behindDetail(b)
	}
	// Markers ride on top of the status's own reason, on ANY row — including a
	// row that reads `ok`, which is the whole point of every one of them: what we
	// could not read (unmeteredMarker), what is eating the box right now
	// (runawayMarker), what it is answering (err5xxMarker), and whether the
	// deploy pair is intact (slotUnitMarker — a box serving on green with a
	// FAILED blue is correctly `ok` and still needs the sentence). Joined with
	// the same separator the strained reason uses for its swap clause, and every
	// empty one drops out rather than leaving a dangling dot.
	parts := make([]string, 0, 6)
	for _, s := range []string{reason, queuedDeployAgeMarker(b), slotUnitMarker(b), runawayMarker(b), err5xxMarker(b), unmeteredMarker(b)} {
		if s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, " · ")
}

// --- the 5xx marker (dr-w5-followup-5xx-reaches-no-eyes) ----------------------
//
// THE RULING: DETAIL LINE, NOT A RUNG — the same call runawayMarker's block
// above already argues, accepted here for the same two reasons. (1) The
// decision-15 vocabulary is pinned across three surfaces by the decision-32
// fixture and mirrored by the SPA; a twelfth status minted here alone is the
// drift D32 exists to prevent, and a rung would have to move the ladder, both
// fixtures and semrole.For in one commit for a signal that is (2) built on a
// 60s PER-SLOT ring that re-arms EMPTY on every blue/green flip — a rung keyed
// on it would flap to "unmeasured" on every deploy, and this fleet deploys
// constantly. A detail line pays no flap cost: it changes no rank and no
// bucket, it simply says the sentence D75 exists to make sayable — "this box
// the table calls healthy is answering ~0.22 5xx/s" — on whatever row it rides.
//
// THE THREE STATES STAY THREE STATES, and none of them is another. The TABLE
// marker below prints only the positive rate — exactly runawayMarker's policy:
// a sentence on a table row claims something happened, and neither "we did not
// measure" nor "measured, quiet" is a happening (the decision-15 tests pin an
// ok row's detail EMPTY for both). The full tri-state renders in `-o json`
// (err5xxRow), where a machine reader gets nil-as-unmeasured, zero-as-zero and
// the rate as itself — never collapsed into each other.
func err5xxMarker(b cloudclient.Barkpark) string {
	p := b.Pressure
	if p == nil || p.Err5xxPerS == nil || *p.Err5xxPerS <= 0 {
		return ""
	}
	return fmt.Sprintf("answering %.2f 5xx/s (60s per-slot ring — the beat's own number, blind to 5xx the BEAM never served)", *p.Err5xxPerS)
}

// err5xxRow is the `-o json` projection of the same reading, and it is where
// the three states are DISTINGUISHED for a machine reader:
//   - state "unmeasured", per_s null — the beat carried no reading (nil on the
//     wire, or the agent's -1 sentinel relayed). No reading is NOT zero.
//   - state "zero", per_s 0 — the 60s window was READ and held no 5xx. A real
//     zero, still bounded: the ring is per-slot and blind to 5xx the BEAM
//     never served.
//   - state "answering", per_s <rate> — the beat's own number, never
//     recomputed here.
func err5xxRow(b cloudclient.Barkpark) map[string]any {
	p := b.Pressure
	if p == nil || p.Err5xxPerS == nil || *p.Err5xxPerS < 0 {
		return map[string]any{"state": "unmeasured", "per_s": nil}
	}
	if *p.Err5xxPerS == 0 {
		return map[string]any{"state": "zero", "per_s": 0.0}
	}
	return map[string]any{"state": "answering", "per_s": *p.Err5xxPerS}
}

// --- the slot-unit marker (dr-bl-w5-failed-slot-unit-is-invisible) -----------
//
// WHAT WAS MISSING: on 2026-08-06 guerrilla's `barkpark-slot@blue` sat in
// `failed` — an 8m30s stop-sigterm timeout ending in SIGKILL, itself a symptom
// of a box at 92.9% swap — and this screen said `ok`. It was ACCIDENTALLY right:
// green was serving, so the box genuinely was serving. But the verdict had zero
// unit-state inputs, so it would have said `ok` with either half dead and with
// BOTH. A light that cannot go out is not a light.
//
// DETAIL LINE, NOT A RUNG — the third time this call is made in this file
// (runawayMarker, err5xxMarker) and for the stronger of their two reasons. The
// decision-15 vocabulary is pinned across three surfaces by the decision-32
// fixture (attention_order.json) and mirrored by the SPA, and a twelfth status
// minted here would be the drift D32 exists to prevent. But the deciding reason
// is that the ROW'S VERDICT IS ALREADY CORRECT: a box serving on green with a
// failed blue IS ok, and re-ranking it would trade a false negative for a false
// positive. What was missing was never the verdict — it was the SENTENCE.
//
// It never fabricates, on the same rule the two markers above keep: an
// unmeasured box (nil list — no systemd, or an agent predating the probe) and a
// measured-intact box (a pair both active) both render "", because neither has
// a failure to name. Those two ARE distinguished in `-o json` (slotUnitsRow).
func slotUnitMarker(b cloudclient.Barkpark) string {
	p := b.Pressure
	if p == nil || len(p.SlotUnits) == 0 {
		return ""
	}
	var (
		slots   []cloudclient.SlotUnit
		failed  []cloudclient.SlotUnit
		serving []string
		sites   []cloudclient.SlotUnit
	)
	for _, u := range p.SlotUnits {
		if strings.Contains(u.Unit, slotUnitPrefix) {
			slots = append(slots, u)
			switch {
			case u.ActiveState == "active" && slotUnitRunning(u):
				serving = append(serving, slotUnitShortName(u))
			case u.ActiveState == "failed":
				failed = append(failed, u)
			}
			continue
		}
		if u.ActiveState == "failed" {
			sites = append(sites, u)
		}
	}

	parts := make([]string, 0, 3)
	switch {
	case len(failed) > 0 && len(serving) > 0:
		// THE CASE THE ROW IS ABOUT, and the reason the verdict stays `ok`: the
		// box IS serving. The detail says half the pair is down anyway, because
		// the next deploy has nowhere to cut over TO.
		parts = append(parts, fmt.Sprintf("serving on %s; %s",
			strings.Join(serving, "+"), slotUnitFailureClause(failed)))
	case len(failed) > 0:
		// Failed AND nothing serving. Still not a rung — `health_status` is the
		// field that owns "is this box answering" and it is on the same row — but
		// the contradiction is named when health disagrees.
		parts = append(parts, "NO slot is serving; "+slotUnitFailureClause(failed))
		parts = append(parts, slotUnitHealthContradiction(b)...)
	case len(slots) > 0 && len(serving) == 0:
		// Nothing failed and nothing serving: every slot is inactive/activating.
		// A mid-cutover beat looks exactly like this for a few seconds, so it is
		// only worth a sentence when health claims the box is UP — that is a
		// contradiction, not a race.
		if c := slotUnitHealthContradiction(b); len(c) > 0 {
			parts = append(parts, "no blue/green slot is active")
			parts = append(parts, c...)
		}
	}

	if len(sites) > 0 {
		names := make([]string, 0, len(sites))
		for _, u := range sites {
			names = append(names, slotUnitShortName(u))
		}
		s := fmt.Sprintf("%d site unit(s) failed: %s", len(sites), strings.Join(names, ", "))
		// The agent caps the site list and reports what the cap hid, so a short
		// list says it is short rather than passing for a whole one.
		if p.SlotUnitsTruncated != nil && *p.SlotUnitsTruncated > 0 {
			s += fmt.Sprintf(" (+%d more)", int(*p.SlotUnitsTruncated))
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, " · ")
}

// slotUnitPrefix is the blue/green template unit's name. A unit that does not
// carry it is a spawned SITE unit, which is a different story on the same list.
const slotUnitPrefix = "barkpark-slot@"

// slotUnitRunning is the second half of "is this slot serving": systemd says
// active AND a main process exists. An `active` unit with MainPID 0 has no
// process (a oneshot that exited), and treating it as serving is how a box with
// nothing running reads healthy. A nil pid is UNKNOWN and does NOT vouch —
// unmeasured never becomes evidence for the reassuring answer.
func slotUnitRunning(u cloudclient.SlotUnit) bool {
	return u.MainPID != nil && *u.MainPID > 0
}

// slotUnitShortName is the unit stripped to what an operator says out loud:
// "barkpark-slot@green.service" → "green", "barkpark-site@search__b.service" →
// "search__b". A unit that matches neither shape is carried VERBATIM rather than
// mangled.
func slotUnitShortName(u cloudclient.SlotUnit) string {
	name := strings.TrimSuffix(u.Unit, ".service")
	if i := strings.Index(name, "@"); i >= 0 {
		return name[i+1:]
	}
	return name
}

// slotUnitFailureClause names the failed slot(s) with the two facts that decide
// what an operator does next: WHY systemd calls it failed, and SINCE WHEN.
//
// The reason is Result + ExecMainStatus TOGETHER, never Result alone. Measured
// 2026-09-01: a deliberate retire reads Result "exit-code" with status 143 —
// 128+15, a clean SIGTERM — because the unit file lacks SuccessExitStatus=143
// (PR #14863). Printing "(exit-code)" and dropping the 143 would report that
// retire as a crash.
func slotUnitFailureClause(failed []cloudclient.SlotUnit) string {
	out := make([]string, 0, len(failed))
	for _, u := range failed {
		s := fmt.Sprintf("%s slot FAILED", slotUnitShortName(u))
		if why := slotUnitReason(u); why != "" {
			s += " (" + why + ")"
		}
		if u.StateSince != nil && strings.TrimSpace(*u.StateSince) != "" {
			// systemd's own timestamp string, verbatim: a reformat here would be
			// a second source of truth for a fact systemd already states.
			s += " since " + strings.TrimSpace(*u.StateSince)
		}
		out = append(out, s)
	}
	return strings.Join(out, ", ")
}

func slotUnitReason(u cloudclient.SlotUnit) string {
	result := ""
	if u.Result != nil {
		result = strings.TrimSpace(*u.Result)
	}
	if u.ExecMainStatus == nil || *u.ExecMainStatus < 0 {
		return result
	}
	if result == "" {
		return fmt.Sprintf("status %d", int(*u.ExecMainStatus))
	}
	return fmt.Sprintf("%s %d", result, int(*u.ExecMainStatus))
}

// slotUnitHealthContradiction is the sentence that only exists because two
// independent readings disagree: systemd says no slot is serving and the
// control plane's health gate says the box is up. It is deliberately phrased as
// a disagreement rather than a verdict — the gate probes over HTTP through
// Caddy and could be reading a cached or stale answer, and systemd could be
// mid-cutover. Naming BOTH readings is what lets an operator resolve it; naming
// one would be picking a winner nobody measured.
func slotUnitHealthContradiction(b cloudclient.Barkpark) []string {
	if b.HealthStatus != "up" {
		return nil
	}
	return []string{"health says up — systemd and the gate disagree"}
}

// slotUnitsRow is the `-o json` projection, and it is where the THREE STATES the
// table collapses stay three: an absent key is UNMEASURED (no systemd, or an
// agent predating the probe), `[]` is MEASURED AND INTACT, and a populated list
// is the units themselves — every property the control plane sent, not the
// table's one-line glance. Same rule and same reason as runaway_procs above: a
// `"slot_units": []` for a box nobody looked at is the most reassuring lie this
// payload could tell.
func slotUnitsRow(b cloudclient.Barkpark) []any {
	if b.Pressure == nil || b.Pressure.SlotUnits == nil {
		return nil
	}
	rows := make([]any, 0, len(b.Pressure.SlotUnits))
	for _, u := range b.Pressure.SlotUnits {
		row := map[string]any{
			"unit":         u.Unit,
			"active_state": u.ActiveState,
			"sub_state":    u.SubState,
			"serving":      slotUnitRunning(u),
		}
		if u.Result != nil {
			row["result"] = *u.Result
		}
		if u.MainPID != nil {
			row["main_pid"] = int(*u.MainPID)
		}
		if u.ExecMainStatus != nil {
			row["exec_main_status"] = int(*u.ExecMainStatus)
		}
		if u.StateSince != nil {
			row["state_since"] = *u.StateSince
		}
		rows = append(rows, row)
	}
	return rows
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
		// Tiebreak ZERO (dr-w24-s2): an UNMETERED commit distance sorts to the
		// TOP of its rank — the field's own contract (registry/barkpark.ex: "show
		// NULL as unmetered and sort it to the TOP"). A box we could not grade is
		// the one to look at first, not the one to bury under boxes we could.
		//
		// It sits INSIDE the rank, never across it, so the decision-15 ladder and
		// the decision-32 fixture order are untouched; and it is keyed on
		// commitDistanceUnknown, which is false for a control plane that sent no
		// ancestry at all — so an older CP's whole fleet ties here and falls
		// straight through to the name order it has always had.
		if ui, uj := commitDistanceUnknown(out[i].BP), commitDistanceUnknown(out[j].BP); ui != uj {
			return ui
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
		// dr-w21-s3: the SERVING COMMIT — the raw sha the box actually runs, the
		// fact the commit_ancestry/commit_distance keys below are the plane's
		// GRADE of. It was missing here for a plain reason: this map is hand-
		// built and the key was simply never typed. The wire type decodes it
		// (cloudclient.Barkpark.GitCommit), GET /v1/barkparks emits it, and
		// cloudBarkparkRow (cloud12_cmd.go) — the SAME struct off the SAME
		// endpoint — has always projected it, which is why `bp barkparks -o json`
		// printed real shas while `bp cloud status -o json` printed no such key
		// at all. A PROJECTION gap, not a decode gap and not a route gap.
		//
		// ALWAYS present (empty string when the plane has no commit for the box),
		// the same honesty rule commit_ancestry follows: a consumer must be able
		// to tell "we asked and the plane does not know" from "this CLI never
		// asked". The table renders that empty as UNMETERED, never a blank.
		//
		// The registry `version` field is deliberately NOT here under any name.
		// It is the AGENT BINARY version (internal/agent/report.go `const Version
		// = "0.1.0"`), a compile-time constant reading 0.1.0 fleet-wide while the
		// boxes serve 0.2.25.164 … 0.2.25.2628. A number that can never move,
		// sitting beside one that does, would read as freshness. If it is ever
		// wanted it ships as `agent_version`, named for what it is.
		"git_commit": r.BP.GitCommit,
		// dr-w22-bl: SINCE WHEN the box has served that sha, RFC3339, ALWAYS
		// present (empty string when the plane never observed the transition) —
		// the same honesty rule `git_commit` itself follows one line above. A
		// script must be able to tell "the plane has no first-appearance for this
		// box" from "this CLI never asked", and an absent key cannot say that.
		//
		// The number it replaces reaching for: the `(sha, first_seen)` history has
		// existed in `agent_events` for 14 days all along (measured on prod
		// 2026-09-01: 132,120 rows, 2026-08-18T03:30:20Z -> 2026-09-01T23:19:22Z),
		// but its only reader is `GET /v1/barkparks/:id/events` — `require_user`,
		// 200 rows a page, ~3h of it. This key rides the fleet list every PAT
		// holder already reads.
		//
		// EMPTY IS UNMEASURED, NEVER "just now". Two honest populations read
		// empty: a box that has not changed sha since the column shipped, and a
		// box whose stored sha was blank when a sha first arrived (that commit may
		// have been running long before the first beat carrying it reached us).
		"git_commit_first_seen_at": r.BP.GitCommitFirstSeenAt,
		// The 5xx tri-state (dr-w5-followup): nil-as-unmeasured, zero-as-zero,
		// rate-as-itself — the json render where the three states stay three.
		"err_5xx":                err5xxRow(r.BP),
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
		// dr-w24-s2: the plane's own commit-distance measurement, beside the
		// release-tag grade it contradicts. ancestry + checked_at are ALWAYS
		// present (empty on a plane that predates the emission) so a script can
		// tell "the plane said nothing" from "the plane measured and got
		// unknown"; the distance itself is tri-state below.
		"commit_ancestry":            r.BP.CommitAncestry,
		"commit_distance_checked_at": r.BP.CommitDistanceCheckedAt,
		"autoupdate_paused":          r.BP.AutoupdatePaused,
		"pinned_release":             r.BP.PinnedRelease,
		"channel":                    r.BP.Channel,
	}
	// Tri-state: only emit autoupdate_enabled when the CP actually reported it, so
	// -o json is as honest as the table (nil = policy unknown, never a fake false).
	if r.BP.AutoupdateEnabled != nil {
		row["autoupdate_enabled"] = *r.BP.AutoupdateEnabled
	}
	// Tri-state, the same idiom: emit commit_distance only when the plane
	// actually measured one. `"commit_distance": 0` for an ungradeable box would
	// read "even with main" to every script that consumes this, which is exactly
	// the lie the *int on the wire type exists to prevent — an absent key forces
	// the consumer to branch, a zero invites it not to. commit_ancestry above
	// carries the reason the number is missing.
	if r.BP.CommitDistance != nil {
		row["commit_distance"] = *r.BP.CommitDistance
	}
	// Tri-state, same idiom (jpf-w1-queue-age-alarm): the queued-deploy age is
	// emitted only when the plane reported a queued row. An absent key is
	// "nothing queued / CP predates the field"; a 0 would tell a script a deploy
	// was queued THIS second, which nobody measured.
	if r.BP.QueuedDeployAgeSeconds != nil {
		row["queued_deploy_age_seconds"] = *r.BP.QueuedDeployAgeSeconds
	}
	// The runaway list, tri-state like every honest field above and by the SAME
	// rule: emit the key only when the box was actually MEASURED. A nil list is
	// an agent that predates the probe (or a box with no `ps`) and the key is
	// absent, forcing a script to branch; a measured-quiet box emits `[]`, which
	// is a real answer and reads as one. `"runaway_procs": []` for a box nobody
	// looked at would be the single most reassuring lie this payload could tell.
	//
	// Unlike the table's DETAIL cell, this carries EVERY row and the FULL command
	// the agent sent — the table is a glance, this is the evidence.
	if r.BP.Pressure != nil && r.BP.Pressure.RunawayProcs != nil {
		procs := make([]any, 0, len(r.BP.Pressure.RunawayProcs))
		for _, p := range r.BP.Pressure.RunawayProcs {
			procs = append(procs, map[string]any{
				"pid":         int(p.PID),
				"elapsed_s":   int(p.ElapsedS),
				"cpu_percent": p.CPUPercent,
				"command":     p.Command,
			})
		}
		row["runaway_procs"] = procs
	}
	// The blue/green unit states, same tri-state idiom and same reason: the key
	// is emitted only when the box was MEASURED, so an absent key forces a script
	// to branch and `[]` is a real "we looked, the pair is there" answer.
	if units := slotUnitsRow(r.BP); units != nil {
		row["slot_units"] = units
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

	// The deploy census + site list, read ONCE (statusDeployRead) and shared by
	// all three consumers below — the per-row marker, the table's DEPLOY
	// section and `-o json`. Read here rather than inside each renderer so the
	// window is computed exactly once: statusDeployNow() moves, and two fetches
	// are two different windows. It never errors — a failure is a named state
	// carrying the sentence that explains it.
	//
	// The MARKER is applied before ANY rendering, because the detail column is
	// switched on by the rows themselves (renderStatusRowsWith): a healthy
	// bucket whose only detail is the deploy sentence must grow the column, and
	// that decision is made at render time off ranked[i].Detail.
	deploy := statusDeployRead(cfg)
	applyDeployMarker(ranked, deploy)

	if out.output == "json" || out.output == "yaml" {
		// dr-w19-s7 followup: the deploy truth reaches the MACHINE reader too.
		// The section costs the same two extra control-plane reads the table
		// pays (census + sites); a script reading the fleet could otherwise
		// see a page of ok boxes on a day the live rate is 27.9%.
		fleetDeploy, perBoxDeploy := statusDeployJSON(deploy, ranked)
		rows := make([]any, 0, len(ranked))
		for _, r := range ranked {
			row := rankedBarkparkRow(r)
			row["deploy"] = perBoxDeploy[r.BP.ID]
			rows = append(rows, row)
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
			"deploy":    fleetDeploy,
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
	renderStatusDeploy(out, deploy, ranked)
	return exitOK
}

// renderStatusBucket prints one bucket section (header + painted table) when it
// has rows, in the already-sorted order. Silent for an empty bucket so the view
// stays lean.
//
// `ranked` is the WHOLE FLEET, not this bucket's rows — the filter happens here.
// That matters for more than convenience: the COMMIT switch is measured off that
// full slice (fleetKnowsCommit) and handed to the renderer, so every bucket
// answers the same question and a bucket holding only unknown-commit rows still
// prints UNMETERED instead of dropping the column and going quiet. Narrowing
// `ranked` to pre-filtered rows here would silently turn that fleet-wide rule
// into a per-bucket one; TestStatusCommitColumnIsFleetWideNotPerBucket is the
// tripwire for exactly that regression.
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
	renderStatusRowsWith(out, rows, fleetKnowsCommit(ranked))
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
//   - COMMIT  the sha the box is actually serving (dr-w21-s3) — the one column
//     whose switch is NOT read off this row-set. It is decided fleet-wide by the
//     caller, because an empty sha cannot tell a plane that emits no commits from
//     a box that reported none, and reading it per bucket would silence a lone
//     unknown box in ATTENTION — the exact row the column exists for. Once on,
//     every row says something: commitCell never returns "".
//   - BEHIND  the plane's measured commit distance from main (dr-w24-s2) — only
//     when the control plane emits an ancestry at all. Once on, every row says
//     something: a number, `even`, or the loud UNMETERED. It is the column that
//     contradicts UPDATE, and that is the point.
//   - CHANNEL the release channel (prod/staging) — only when the CP emits it
//   - POLICY  compact autoupdate flag (pin@tag / paused / off / auto)
//   - DETAIL  the control plane's own reason for a failure/suspension
//
// Column order keeps the urgent identity left (STATUS · NAME · UPDATE · CHANNEL ·
// COMMIT · BEHIND · HEALTH · AGENT · POLICY) and the long URL + optional DETAIL
// last, so the common case stays readable at 80 columns. COMMIT sits immediately
// before BEHIND so the sha and the plane's grade OF that sha read as one phrase
// — "serving c80168100e1a, 2493 behind" — rather than being split by CHANNEL.
func renderStatusRows(out *writer, rows []rankedBarkpark) {
	// No fleet context here, so the switch is measured over the rows given. Every
	// production path goes through renderStatusBucket, which supplies the true
	// fleet-wide answer; this fallback keeps the direct-call test helper honest.
	renderStatusRowsWith(out, rows, fleetKnowsCommit(rows))
}

// renderStatusRowsWith is renderStatusRows with the COMMIT switch supplied by the
// caller, so it can be decided over the whole fleet rather than over one bucket.
func renderStatusRowsWith(out *writer, rows []rankedBarkpark, withCommit bool) {
	// Decide which conditional columns this bucket needs.
	withUpdate, withChannel, withPolicy, withDetail := false, false, false, false
	withBehind := false
	for _, r := range rows {
		if updateCell(r.BP) != "" {
			withUpdate = true
		}
		if behindCell(r.BP) != "" {
			withBehind = true
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
	if withCommit {
		headers = append(headers, "COMMIT")
	}
	if withBehind {
		headers = append(headers, "BEHIND")
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
		if withCommit {
			// NOT statusDash: once the column is on, a box whose sha the plane
			// does not know reads UNMETERED, never an em dash that would say
			// "fine". commitCell already guarantees a non-empty cell.
			row = append(row, commitCell(r.BP))
		}
		if withBehind {
			// NOT statusDash on the VALUE: once the column is on, an ungradeable
			// box reads UNMETERED, never an em dash and never 0. The em dash is
			// reserved for its one honest use — a row the control plane sent no
			// ancestry for at all.
			cell := behindCell(r.BP)
			if cell == "" {
				cell = "—"
			}
			row = append(row, cell)
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

// --- ONE reading, shared by the marker, the table and -o json ----------------

// statusDeployReading is the deploy census + site list read ONCE per
// `bp cloud status` invocation, folded per box.
//
// It exists because the reading now has THREE consumers — the per-row marker
// below, the DEPLOY section and `-o json` — and each of them fetching for
// itself would mean two extra control-plane round trips per consumer and, far
// worse, two consumers able to disagree about the same window: the census
// window is computed off statusDeployNow(), so a second fetch is a SECOND
// window. State is the fleet-level verdict, worded exactly once here.
//
// State is exhaustive: "read" | "census_unreadable" | "sites_unattributable".
// Reason is the sentence that goes with a non-"read" state, and it is the SAME
// sentence in both renders — `bp cloud status` and `bp cloud deployments`
// cannot tell an operator two different stories about the same 403.
type statusDeployReading struct {
	From, To     time.Time
	State        string
	Reason       string
	Boxes        map[string]*statusDeployBox
	MinSample    int
	Volume       int
	OrphanRows   int
	OrphanVolume int
}

// statusDeployRead performs the two control-plane reads and folds them. It
// never returns an error: every failure is a NAMED state with the sentence that
// explains it, because "we could not read the deploy census" and "the fleet has
// no deploy problems" must never render the same way.
func statusDeployRead(cfg *Config) *statusDeployReading {
	to := statusDeployNow().UTC().Truncate(time.Second)
	from := to.Add(-statusDeployWindow)
	rd := &statusDeployReading{From: from, To: to, Boxes: map[string]*statusDeployBox{}}

	census, cerr := cfg.CloudClient().FleetDeployCensus(cloudCtx(), from, to)
	if cerr != nil {
		rd.State = "census_unreadable"
		rd.Reason = statusDeployReadFailure(from, to, cerr)
		return rd
	}
	rd.Volume = census.Volume
	sites, serr := cfg.CloudClient().ListSites(cloudCtx())
	if serr != nil {
		rd.State = "sites_unattributable"
		rd.Reason = fmt.Sprintf(
			"the census was read (%d attempted rows over this window) but the site list was not: %s. Without it a census row cannot be tied to a box.",
			census.Volume, serr.Error())
		return rd
	}
	rd.State = "read"
	rd.MinSample = census.MinSample
	rd.Boxes, rd.OrphanRows, rd.OrphanVolume = statusDeployFold(census, sites)
	return rd
}

// --- the deploy marker (dr-w13-bl-fleet-verdict-is-deploy-blind) -------------
//
// WHAT WAS STILL MISSING after the D330 gauge landed. The DEPLOY section says
// the true thing — but it says it in a DIFFERENT section, below three tables,
// and the TABLE ROW for the box producing every deferral in the fleet still
// printed `ok` with an EMPTY detail. The detail column was not even switched
// on for the HEALTHY bucket, so a reader who scans the three buckets and stops
// has read a page of `ok` rows carrying nothing at all.
//
// D330 STANDS AND IS NOT REOPENED HERE: no rung, no verdict arm, no fence, no
// hardcoded floor. `attentionRankOrder` is byte-untouched by this slice and
// TestStatusDeployIsAGaugeNotAFence still pins it at the charter's twelve.
// This is the FIFTH detail marker (after slotUnit / runaway / err5xx /
// unmetered) and it keeps their contract verbatim: it rides on top of whatever
// the status already said, on ANY row including `ok`, and moves no status, no
// rank and no bucket.
//
// IT NAMES ITS WINDOW, which no per-box sentence on this screen previously did
// (dr-w13-bl-10129-window-is-pinned-by-nothing's third defect: the window is
// decoded, printed once in a section header, and never travels with the number
// it denominates). A rate on a row that does not carry its window is a number
// with no population, and a marker is exactly the place it can be quoted from.
//
// IT SPEAKS ONLY ON A MEASUREMENT, AND ONLY ON A HAPPENING — the same policy
// err5xxMarker and runawayMarker keep. A box whose every attempted deploy
// reached live has nothing to add: a sentence on a table row claims something
// happened, and "everything shipped" is not a happening. And it is SILENT for
// each of the four absences the DEPLOY section already words (below
// min_sample, no per-site `live`, an unread census, no rows) rather than
// minting a fifth wording for the same refusal — silence here is never a green,
// because the section twenty lines down states the refusal in full.
func deployMarker(rd *statusDeployReading, id string) string {
	if rd == nil || rd.State != "read" || rd.MinSample <= 0 {
		return ""
	}
	b := rd.Boxes[id]
	// Not measured, or measured below the census's own floor: the DEPLOY
	// section owns those sentences. Never a percentage here.
	if b == nil || !b.LiveKnown || b.Volume == 0 || b.Volume < rd.MinSample {
		return ""
	}
	// Measured and everything shipped: no happening, no sentence.
	if b.Live >= b.Volume {
		return ""
	}
	return fmt.Sprintf("deploys live %d/%d (%s) over %s — a GAUGE: it moved no status, rank or bucket on this row",
		b.Live, b.Volume, pctOf(float64(b.Live), float64(b.Volume)),
		deployCensusWindowPhrase(rd.From, rd.To))
}

// applyDeployMarker appends the marker to each ranked row's DETAIL, using the
// same " · " separator attentionDetail joins its own markers with, so a row
// that already had a reason keeps it and the deploy sentence rides after it.
// Status, Bucket and Rank are never touched — that is the D330 boundary, in
// code: this function can only ever change a string.
func applyDeployMarker(ranked []rankedBarkpark, rd *statusDeployReading) {
	for i := range ranked {
		m := deployMarker(rd, ranked[i].BP.ID)
		if m == "" {
			continue
		}
		if ranked[i].Detail == "" {
			ranked[i].Detail = m
		} else {
			ranked[i].Detail += " · " + m
		}
	}
}

// statusDeployJSON is the machine half of the deploy section (dr-w19-s7
// followup): the fleet-level node plus one node per box, every refusal a NAMED
// state — never an omitted key and never a zero standing in for "we could not
// say". It reads the SAME statusDeployReading the table and the marker read,
// and words its refusals with the SAME sentences, so the three outputs cannot
// tell an operator different stories.
//
// States, exhaustively (fleet node): "read" | "census_unreadable" |
// "sites_unattributable". Per-box node: "rated" | "below_min_sample" |
// "no_min_sample" | "live_unmetered" | "no_rows" | the two fleet refusals
// echoed per row (so a row consumer never has to join against the fleet node
// to learn why its numbers are null). live/volume/pct are null wherever they
// were not measured — a JSON null is this contract's "could not measure", and
// it is never collapsed into 0.
func statusDeployJSON(rd *statusDeployReading, ranked []rankedBarkpark) (map[string]any, map[string]map[string]any) {
	window := map[string]any{
		"from": rd.From.Format(time.RFC3339),
		"to":   rd.To.Format(time.RFC3339),
	}

	perBox := make(map[string]map[string]any, len(ranked))
	if rd.State != "read" {
		for _, r := range ranked {
			perBox[r.BP.ID] = map[string]any{
				"state": rd.State, "reason": rd.Reason,
				"live": nil, "volume": nil, "pct": nil,
			}
		}
		return map[string]any{"window": window, "state": rd.State, "reason": rd.Reason}, perBox
	}

	var minSampleVal any // null when the control plane sent none — absent is not zero
	if rd.MinSample > 0 {
		minSampleVal = rd.MinSample
	}
	fleet := map[string]any{
		"window":     window,
		"state":      "read",
		"min_sample": minSampleVal,
		"orphans":    map[string]any{"rows": rd.OrphanRows, "volume": rd.OrphanVolume},
	}
	for _, r := range ranked {
		b := rd.Boxes[r.BP.ID]
		switch {
		case b == nil || b.Volume == 0:
			perBox[r.BP.ID] = map[string]any{
				"state": "no_rows", "live": 0, "volume": 0, "pct": nil,
				"reason": "no deploy rows in this window — nothing was attempted here, which is not the same as nothing failing",
			}
		case !b.LiveKnown:
			perBox[r.BP.ID] = map[string]any{
				"state": "live_unmetered", "live": nil, "volume": b.Volume, "pct": nil,
				"reason": fmt.Sprintf("%d attempted; this control plane sends no per-site `live`, so whether anything shipped is unknown (never read this as zero)", b.Volume),
			}
		case rd.MinSample <= 0:
			perBox[r.BP.ID] = map[string]any{
				"state": "no_min_sample", "live": b.Live, "volume": b.Volume, "pct": nil,
				"reason": fmt.Sprintf("%d attempted, %d live; this control plane sent no min_sample, so nothing says whether a percentage on this sample is a measurement", b.Volume, b.Live),
			}
		case b.Volume < rd.MinSample:
			perBox[r.BP.ID] = map[string]any{
				"state": "below_min_sample", "live": b.Live, "volume": b.Volume, "pct": nil,
				"reason": fmt.Sprintf("%d attempted is below the census min_sample of %d (%d live); a percentage on this sample would be noise", b.Volume, rd.MinSample, b.Live),
			}
		default:
			perBox[r.BP.ID] = map[string]any{
				"state": "rated", "live": b.Live, "volume": b.Volume,
				"pct": float64(b.Live) / float64(b.Volume) * 100,
			}
		}
	}
	return fleet, perBox
}

// renderStatusDeploy prints the DEPLOY section: one line per box in the same
// rank order as the tables above, carrying the box's live rate WITH its
// denominator over a pinned DAILY window — or the refusal that stopped it being
// a number.
//
// The MACHINE half of this section is statusDeployJSON above (dr-w19-s7
// followup): -o json carries the same census fold as ADDITIVE `deploy` nodes
// (fleet + per row), so the decision-15 keys scripts already consume are
// untouched and a machine reader no longer sees a fleet of ok boxes on a day
// the live rate is 27.9%. `bp cloud deployments` remains the deep reader.
//
// The section still prints in full even though every rated box now also carries
// the one-line marker in its table row: the marker is silent for the four
// absences and for a box that shipped everything, and those readings are facts
// an operator needs to SEE, not infer from a missing sentence.
func renderStatusDeploy(out *writer, rd *statusDeployReading, ranked []rankedBarkpark) {
	out.outf("")
	out.outf("DEPLOY · period: DAILY · window %s", deployCensusWindowPhrase(rd.From, rd.To))
	out.outf("  live_rate is a GAUGE and not a fence: it carries its own denominator, refuses a percentage below the census min_sample, and changes no status above.")

	switch rd.State {
	case "census_unreadable":
		out.outf("  NOT READ — %s", rd.Reason)
		return
	case "sites_unattributable":
		out.outf("  NOT ATTRIBUTED — %s; `bp cloud deployments` reads the same window fleet-wide.",
			strings.TrimSuffix(rd.Reason, "."))
		return
	}

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
		out.outf("  %s%s  %s", name, strings.Repeat(" ", pad), statusDeployLine(rd.Boxes[r.BP.ID], rd.MinSample))
	}
	if rd.OrphanRows > 0 {
		out.outf("  %d census site row(s) (%d attempted) belong to no box in this fleet listing and are in NO line above — run `bp cloud deployments` to see them.",
			rd.OrphanRows, rd.OrphanVolume)
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
