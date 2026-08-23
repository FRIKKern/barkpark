package cli

// cloud_deliveries_cmd.go is `bp cloud deliveries <sha>` — the FIRST human
// reader of the PLATFORM delivery record (GET /v1/deliveries). The record has
// shipped, is PAT-reachable, and until this file no surface anywhere read a row
// out of it: the epic's own finished experience is two commands and one PAT, and
// this is the second command.
//
// WHAT IT ANSWERS: "my merge went in — what actually happened to it?" One sha,
// its clocks in causal order — merged, waited, built, serving — and the RUN that
// delivered it, saying out loud when that run is not the sha's own.
//
// IT NAMES ITS POPULATION ON THE HEADER LINE, EVERY TIME. `deliveries` is a word
// this CLI already uses: `bp cloud webhook deliveries` lists ONE TENANT's webhook
// send log. These rows are Barkpark's own platform deploys — a different table,
// a different scope, no overlap at all — and the two are one keystroke apart in
// an operator's muscle memory. The schema renamed its own table
// `platform_deliveries` over this collision; the render says it in words.
//
// D429's RENDERING RULE, VERBATIM: this verb renders ONE sha and MUST NOT print
// a population percentage at all — it prints that sha's own SECONDS, attributed.
// Population figures (36.7% carried, the pickup percentiles) live in the charter
// and the wave Paper only, always paired with their window and outlier policy,
// and p95 is not printed anywhere by anyone: it measured 12.8s vs 153.8s across
// two defensible definitions of the same window, so it is not a stable statistic.
//
// EVERY NULL FIELD IS AN UNMETERED SENTENCE THAT NAMES WHY. SEVEN of the
// thirteen wire keys are legitimately NULL, and each of them coalesces into a
// comforting lie: a missing build is "built in 0s", a missing serving_since is
// "went live at the epoch", a missing merged_at is "merged at the epoch", a
// missing queue-split bucket is "0s spent there". The shipped house voice for
// this is `bp cloud status`'s "UNMETERED — <why>", and these lines copy it.
//
// AND `carried` IS THE EIGHTH, WITH ITS OWN WORD. It is a nullable BOOLEAN, so
// its coalesced lie is not a suspicious 0 but a plausible sentence — "this sha's
// OWN run" — which a reader has no way to doubt. It therefore renders THREE
// states and the third says UNRECORDED, in the same voice, and says that the
// OWNERSHIP of the seconds below is what is unknown (the seconds themselves may
// be measured perfectly well and still belong to somebody else's run).
//
// AN EMPTY PAGE IS AN ANSWER, NOT A FAILURE. An unknown sha is a 200 with an
// empty list by the route's explicit design, so the read SUCCEEDED and this verb
// exits 0 — and prints, loudly, that nothing was ever recorded for the sha,
// which is a different sentence from "the deploy failed" and from "no such
// route". The refusals (401 / 503 / 500) are the failure exits.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// deliveriesDefaultLimit is how many rows this verb asks for when the caller
// pins none. One sha can honestly have SEVERAL rows (a carried sha is delivered
// by one run and may be re-delivered by another), so this is not 1 — but it is
// far below the route's 200 ceiling, because a sha with dozens of delivery rows
// is a story about the recorder, not about the sha.
const deliveriesDefaultLimit = 20

// runCloudDeliveries is `bp cloud deliveries <sha> [--limit N]`: read the
// platform delivery record for ONE commit and render its timeline — or the
// refusal, named. Needs `bp login` and a credential carrying ability "read"; no
// operator grant is involved (the route is user-or-PAT on purpose, because a
// record only a browser session can read is one no script can check).
func runCloudDeliveries(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudDeliveriesHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudDeliveriesHelp(out)
		return exitOK
	}

	const usage = "bp cloud deliveries <sha> [--limit N]"
	a, err := parseHzArgs(args, []string{"limit"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("takes exactly one commit sha (usage: %s)", usage), exitUsage)
	}
	sha, serr := deliveriesSHA(a.pos[0])
	if serr != nil {
		return useError(out, "usage", serr.Error(), exitUsage)
	}
	limit, lerr := deliveriesLimit(a)
	if lerr != nil {
		return useError(out, "usage", lerr.Error(), exitUsage)
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to read the platform delivery record", exitAuth)
	}

	page, derr := cfg.CloudClient().PlatformDeliveries(cloudCtx(), sha, limit)
	if derr != nil {
		// BRANCH ON THE ERROR FIRST, ALWAYS. Below this line a zero-valued page
		// renders as "nothing was ever recorded for this sha" — a silent deploy
		// reported as a measurement, which is this epic's whole defect.
		return deliveriesFail(out, sha, derr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitDeliveriesRaw(out, page)
		return exitOK
	}
	renderDeliveries(out, sha, page)
	return exitOK
}

// deliveriesSHA validates the positional the same way the control plane
// normalises it (trim + lowercase), so the sha this CLI queries on is the sha
// the route filters on. A junk positional is refused HERE rather than sent, so
// "no rows" can never be an answer about a typo.
func deliveriesSHA(raw string) (string, error) {
	s := strings.ToLower(strings.TrimSpace(raw))
	if s == "" {
		return "", errors.New("give a commit sha to look up — an empty sha would read the whole record, and this verb renders ONE sha")
	}
	if len(s) < 7 || len(s) > 64 {
		return "", fmt.Errorf("%q is not a commit sha — the record keys on 7-64 lowercase hex characters", raw)
	}
	for _, r := range s {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return "", fmt.Errorf("%q is not a commit sha — the record keys on 7-64 lowercase hex characters", raw)
		}
	}
	return s, nil
}

// deliveriesLimit reads --limit: how many rows to ASK the control plane for. The
// route clamps it to its own ceiling, so this is a request and not a promise.
func deliveriesLimit(a *hzArgs) (int, error) {
	raw, has := lastVal(a, "limit")
	if !has {
		return deliveriesDefaultLimit, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("--limit wants a positive whole number of rows, got %q", raw)
	}
	return n, nil
}

// emitDeliveriesRaw writes the record for a machine consumer: json is the
// control plane's envelope BYTES verbatim (the emitDeployCensusRaw idiom — the
// envelope IS the contract), yaml a faithful re-encode.
func emitDeliveriesRaw(out *writer, page cloudclient.DeliveriesPage) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(page.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(page.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// deliveriesFail renders a record that could NOT be read. Each branch says
// plainly that NOTHING was read — never "no deliveries" — and names the cure.
func deliveriesFail(out *writer, sha string, err error) int {
	var de *cloudclient.DeliveriesError
	if !errors.As(err, &de) {
		return cloudFail(out, "read the platform delivery record", err)
	}
	return useError(out, deliveriesErrLabel(de), deliveriesMessage(sha, de), deliveriesExit(de.HTTPStatus))
}

// deliveriesErrLabel is the `bp:` machine label. The 503 labels itself with the
// route's own REASON (`platform_deliveries_missing`) rather than the generic
// `unavailable`, because that reason is the whole actionable content of the
// refusal — a script grepping "unavailable" cannot tell a missing migration from
// a dead upstream.
func deliveriesErrLabel(de *cloudclient.DeliveriesError) string {
	if de.Reason != "" {
		return de.Reason
	}
	if de.Code == "" {
		return "failed"
	}
	return de.Code
}

// deliveriesExit maps a refusal onto the CLI's stable exit ladder by STATUS
// FAMILY (the deployCensusExit idiom), so a refusal code added later is still
// exit-coded correctly without a CLI change.
func deliveriesExit(status int) int {
	switch {
	case status == 401 || status == 403:
		return exitAuth // 3
	case status == 404:
		return exitNotFound // 4
	case status == 422:
		return exitValidation // 5
	case status >= 500:
		return exitServer // 8
	default:
		return exitGeneric // 1
	}
}

// deliveriesMessage is the one human sentence per refusal.
//
// THE 503 IS ITS OWN SENTENCE, DISCRIMINATED ON THE ROUTE'S `reason` AND NOT ON
// THE STATUS FAMILY. "The control plane is unavailable" would send an operator
// looking at the box; the truth is narrower and immediately fixable: this
// control plane never ran the cloud/ migration, because an api-only merge
// deploys the instance leg without it. The route says exactly that in `detail`,
// so the detail is printed VERBATIM rather than paraphrased into a second,
// drifting copy of the same explanation.
func deliveriesMessage(sha string, de *cloudclient.DeliveriesError) string {
	nothing := "Nothing was read: this is NOT 'no delivery was recorded for " + shortSha(sha) + "'."
	switch {
	case de.HTTPStatus == 503 && de.Reason == "platform_deliveries_missing":
		detail := de.Detail
		if detail == "" {
			detail = "this control plane has not run the platform_deliveries migration yet"
		}
		return "this control plane has NO platform delivery record to read (503 " + de.Reason + "): " + sanitizeCell(detail) +
			" " + nothing + " Retry once a cloud/ release has landed on the control plane."
	case de.HTTPStatus == 401:
		return "could not read the platform delivery record for " + shortSha(sha) +
			" — the control plane did not recognise this credential (401 unauthorized). " + nothing +
			" Run `bp login` and try again; a PAT carrying ability \"read\" is enough, no operator grant is involved."
	case de.HTTPStatus == 403:
		return "the control plane refused this credential for the platform delivery record (403 forbidden). " + nothing +
			" This read needs a token carrying ability \"read\"; ask a team owner for one, or run `bp login` again."
	case de.HTTPStatus >= 500:
		return "the control plane failed to read the platform delivery record for " + shortSha(sha) +
			" (HTTP " + strconv.Itoa(de.HTTPStatus) + ": " + sanitizeCell(de.Error()) + "). " + nothing + " Retry; if it persists the read query itself is the fault."
	default:
		return "could not read the platform delivery record for " + shortSha(sha) +
			" (HTTP " + strconv.Itoa(de.HTTPStatus) + ": " + sanitizeCell(de.Error()) + "). " + nothing
	}
}

// renderDeliveries is the human view: the header naming the sha AND the
// population, then one timeline block per recorded delivery, newest first.
func renderDeliveries(out *writer, sha string, page cloudclient.DeliveriesPage) {
	out.outf("%s", deliveriesHeader(sha))
	out.outf("%s", deliveriesPopulationLine(page))
	out.outf("%s", deliveriesFilterLine(sha, page))
	out.outf("")

	if len(page.Deliveries) == 0 {
		out.outf("%s", deliveriesEmptyState(sha))
		return
	}

	for i, d := range page.Deliveries {
		if i > 0 {
			out.outf("")
		}
		renderDelivery(out, sha, d)
	}
}

// deliveriesHeader is the FIRST line, and it names the population it read in the
// same breath as the sha. `bp cloud webhook deliveries` exists and means a
// tenant instance's webhook send log; nothing on screen but this line
// distinguishes the two, so it is not optional decoration.
func deliveriesHeader(sha string) string {
	return "platform deliveries · sha " + sanitizeCell(sha) +
		" — Barkpark's OWN platform deploys (the platform delivery record), NOT a tenant's webhook log (`bp cloud webhook deliveries` is that other thing)"
}

// deliveriesPopulationLine states the scope the control plane declared and how
// many rows THIS page carries.
//
// A SCOPE THE CONTROL PLANE DID NOT NAME SAYS SO. These rows are never
// team-filtered — a platform deploy has no site row and therefore no team_id —
// and the route says `scope: "platform"` precisely so a reader does not assume
// the page was narrowed to their own fleet. An older control plane sends no
// scope at all, and that renders as NOT NAMED rather than as a silent omission a
// reader cannot notice.
func deliveriesPopulationLine(page cloudclient.DeliveriesPage) string {
	rows := "1 delivery recorded"
	if page.Count != 1 {
		rows = fmt.Sprintf("%d deliveries recorded", page.Count)
	}
	scope := strings.TrimSpace(page.Scope)
	if scope == "" {
		return "  population NOT NAMED — this control plane sent no scope, so which deploys these rows cover is unknown · " + rows + " on this page"
	}
	return "  scope: " + sanitizeCell(scope) + " — these rows are NOT team-filtered (a platform deploy has no site row, so there is no team to scope by) · " + rows + " on this page"
}

// deliveriesFilterLine renders the control plane's OWN account of what this
// page is: the sha it says it filtered on (`page.SHA`, the echoed normalised
// filter — a pointer precisely so null differs from pinned) and the row window
// it clamped the read to (`page.Limit`).
//
// WHY THE ECHO IS RENDERED AT ALL (dr-w27-bl): before this line the render
// echoed the OPERATOR'S OWN INPUT back at them — the header prints the typed
// positional, so a normalisation mismatch, an echo mismatch, or a control plane
// filtering on a different sha than the one requested was structurally
// invisible. The echo is the wire's answer to "what did you actually filter
// on?", and a page whose echo disagrees with the request answers a DIFFERENT
// question than the one the caller typed — that is said loudly, never dropped.
//
// A null echo is NOT an error: an older control plane, or a read the route ran
// unfiltered, sends no echo — and that renders as NOT ECHOED rather than being
// silently omitted, so the reader knows the rows below are vouched for only by
// their own per-row sha lines.
func deliveriesFilterLine(requested string, page cloudclient.DeliveriesPage) string {
	limit := "page limit NOT NAMED — this control plane did not say what row window it clamped this read to"
	if page.Limit > 0 {
		limit = fmt.Sprintf("page limit %d (the row window the control plane clamped this read to)", page.Limit)
	}
	if page.SHA == nil {
		return "  filter NOT ECHOED — the control plane did not say which sha it filtered on, so the rows below are vouched for\n" +
			"  only by their own sha lines, never by this read's filter · " + limit
	}
	echo := strings.ToLower(strings.TrimSpace(*page.SHA))
	switch {
	case echo == requested:
		return "  filter echoed: the control plane confirms it filtered on sha " + sanitizeCell(echo) + " · " + limit
	case strings.HasPrefix(echo, requested):
		return "  filter echoed: the control plane filtered on the full sha " + sanitizeCell(echo) +
			", extending the prefix you typed · " + limit
	default:
		return "  FILTER MISMATCH — you asked for " + shortSha(requested) + " but the control plane says it filtered on " + sanitizeCell(echo) + ",\n" +
			"  so this page answers a DIFFERENT question than the one you typed · " + limit
	}
}

// deliveriesEmptyState is the honest 200-with-nothing render. It is the single
// most useful thing this record can say about a deploy that went silent, and it
// is three different sentences away from the ones it must not be confused with.
func deliveriesEmptyState(sha string) string {
	return "NO delivery was ever recorded for " + shortSha(sha) + ".\n" +
		"  The control plane answered 200 with an empty list — the route exists and this is NOT a 404.\n" +
		"  It is also NOT \"the deploy failed\": it means nothing ever WROTE a row for this sha. A sha that\n" +
		"  merged before the recorder existed, a deploy whose recorder step never ran, and a sha that was\n" +
		"  never merged at all are indistinguishable from here — all three look exactly like this."
}

// renderDelivery is ONE row: the run that delivered it, then the clocks in
// causal order. Every clock either prints its own measured value or an UNMETERED
// sentence naming why it is unknown — never 0, never a blank cell.
func renderDelivery(out *writer, requested string, d cloudclient.PlatformDelivery) {
	out.outf("%s", deliveriesRowShaLine(requested, d))
	out.outf("%s", deliveriesRunLine(d))
	if line := deliveriesCarriedLine(d); line != "" {
		out.outf("%s", line)
	}
	out.outf("  merged     %s", deliveriesMergedLine(d))
	out.outf("  waited     %s", deliveriesQueuedLine(d))
	out.outf("  split      %s", deliveriesSplitLine(d))
	out.outf("  built      %s", deliveriesBuiltLine(d))
	out.outf("  serving    %s", deliveriesServingLine(d))
	out.outf("  moved      %s", deliveriesTransitionLine(d))
	out.outf("  first seen %s · recorded %s (when the control plane wrote the row, not a deploy clock)",
		sanitizeCell(d.FirstSeenAt), sanitizeCell(d.RecordedAt))
}

// deliveriesRowShaLine opens every delivery block with the RECORD'S OWN sha
// (`d.SHA`), never the caller's positional. This is the dr-w27-bl fix: until it
// existed, `bp cloud deliveries <sha>` proved nothing about the rows it printed
// — the header names the sha the OPERATOR typed, so a control plane answering
// with a different commit's delivery rendered exactly like the right answer.
// One sha can honestly carry several rows (two_rows_one_sha), which is exactly
// why identity must be read off each row rather than assumed from the query.
//
// A row whose recorded sha does not match the request is a LOUD per-row
// mismatch, not a dropped fact. A prefix relation in either direction is
// consistent (the caller may type a 7-char prefix of the full recorded sha);
// anything else means this row answers a different question than the one asked.
func deliveriesRowShaLine(requested string, d cloudclient.PlatformDelivery) string {
	own := strings.ToLower(strings.TrimSpace(d.SHA))
	if own == "" {
		return "sha UNRECORDED — this row carries NO sha of its own; nothing but your query links it to " + shortSha(requested)
	}
	line := "sha " + sanitizeCell(own) + " — the record's OWN sha for this row, not your query echoed back"
	if own != requested && !strings.HasPrefix(own, requested) && !strings.HasPrefix(requested, own) {
		line += "\n  ROW MISMATCH — this row's recorded sha is NOT the sha you asked for (" + shortSha(requested) + "): the control plane\n" +
			"             answered with a DIFFERENT commit's delivery. Trust the row's own sha above, never the header's echo of your input."
	}
	return line
}

// deliveriesRunLine names the delivering run and the leg it delivered, and says
// on the SAME line whether the run belongs to this sha.
func deliveriesRunLine(d cloudclient.PlatformDelivery) string {
	own := "carried UNRECORDED — whether this run is this sha's own was never measured"
	switch {
	case d.Carried == nil:
		// nil is NOT false. Leave the UNRECORDED sentence standing.
	case *d.Carried:
		own = "CARRIED — not this sha's own run"
	default:
		own = "this sha's OWN run"
	}
	target := strings.TrimSpace(d.Target)
	if target == "" {
		target = "target NOT NAMED"
	} else {
		target = "target " + sanitizeCell(target)
	}
	return "run " + sanitizeCell(d.DeliveringRunID) + " · " + target + " · " + own
}

// deliveriesCarriedLine is the attribution block, and it has THREE outcomes
// because `carried` has three states. It returns "" for the one state that needs
// no block — a MEASURED false, where the run line's "this sha's OWN run" already
// said everything true.
//
// carried:true — a carried sha was swept up by a LATER sha's run (its own run
// carried zero jobs), so the queue and build seconds on this row are THAT run's,
// and printing them without this block attributes another commit's timings to
// this one.
//
// carried:nil — NOBODY MEASURED IT, and this block exists because that state is
// the one a reader cannot detect for themselves. The failure it prevents is not
// a missing number but a plausible sentence: a `bool` decoder turns the wire's
// `null` into `false` and the render then states, with no hedge a human could
// notice, that the run belongs to this sha. What is unknown here is precisely
// OWNERSHIP — the seconds below may be measured perfectly well and still belong
// to a run this record cannot attribute to this sha — so the block says that
// rather than casting doubt on the clocks themselves, which would be a second,
// different lie.
//
// Neither branch quotes the population share: D429 forbids a population
// percentage on a single-sha render.
func deliveriesCarriedLine(d cloudclient.PlatformDelivery) string {
	if d.Carried == nil {
		return "  carried UNRECORDED — whether run " + sanitizeCell(d.DeliveringRunID) + " is this sha's own run was NEVER MEASURED (the wire sent null,\n" +
			"           and the schema keeps no default so that ignorance cannot be recorded as a `false`).\n" +
			"           OWNERSHIP of the waited/built seconds below is therefore UNKNOWN: they may be this sha's own,\n" +
			"           or a later sha's run that swept this sha up — this record cannot tell you which, and neither can this line."
	}
	if !*d.Carried {
		return ""
	}
	return "  carried: run " + sanitizeCell(d.DeliveringRunID) + " is NOT this sha's own run — a LATER sha's run swept this sha up as a passenger,\n" +
		"           so the waited/built seconds below measure THAT run's queue and build, never this sha's own."
}

// deliveriesMergedLine renders merged_at, or why it is unknown.
func deliveriesMergedLine(d cloudclient.PlatformDelivery) string {
	if d.MergedAt == nil || strings.TrimSpace(*d.MergedAt) == "" {
		return "UNMETERED — no merged_at was recorded for this delivery, so when this sha entered main is unknown (never read this as the epoch, and never as 'not merged')"
	}
	return sanitizeCell(*d.MergedAt)
}

// deliveriesQueuedLine renders the queue wait, or why it is unknown.
//
// It prints the TOTAL. The decomposition is the `split` line below it, which is
// rendered from the wire's own three columns and never inferred from this one.
func deliveriesQueuedLine(d cloudclient.PlatformDelivery) string {
	if d.QueuedSeconds == nil {
		return "UNMETERED — the recorder could not read this run's job timestamps, so how long it waited before a runner picked it up is unknown (never read this as 0s)"
	}
	return deliveriesSeconds(*d.QueuedSeconds) + " between the run being created and a runner picking the job up"
}

// deliveriesSplitLine renders the queue wait broken into the three intervals an
// operator can actually act on (charter D430), each straight off its own wire
// column and each independently UNMETERED when the query that produces it
// failed.
//
//	self   — waiting on ANOTHER deploy.yml run's build to finish
//	stall  — the residual co-incident with >= 2 other workflows also created and
//	         not yet picked up, i.e. the runner pool itself being the constraint
//	pickup — THE RESIDUAL. It is defined as what is left after self and stall and
//	         is never a magnitude threshold, which is said on the line every
//	         time: a reader who takes "pickup" for "slow runner pickup" will go
//	         looking at GitHub's runner fleet for seconds that were spent waiting
//	         on this repo's own queue.
//
// A NIL BUCKET NEVER BECOMES A 0, because a 0 here does more damage than a 0
// anywhere else on the row: the three buckets look like arithmetic, so a missing
// one silently reassigns its seconds to whichever bucket WAS measured. And a row
// with no bucket measured at all says so as one sentence rather than three,
// because "three separate unknowns" is not what happened — one recorder went
// quiet.
func deliveriesSplitLine(d cloudclient.PlatformDelivery) string {
	if d.QueuedSelfSeconds == nil && d.QueuedStallSeconds == nil && d.QueuedPickupSeconds == nil {
		return "UNMETERED — this row carries no queue split at all, so WHERE the wait above went is unknown " +
			"(self / stall / pickup were each null on the wire; never read any of them as 0s)"
	}
	return "self " + deliveriesBucket(d.QueuedSelfSeconds) +
		" · stall " + deliveriesBucket(d.QueuedStallSeconds) +
		" · pickup " + deliveriesBucket(d.QueuedPickupSeconds) +
		" — pickup is the RESIDUAL (what is left after self and stall), never a magnitude threshold" +
		deliveriesSplitCaveat(d)
}

// deliveriesBucket is one bucket of the split: its measured seconds, or the word
// that says nobody measured THIS bucket. It stays short because three of these
// share a line, and the long-form reason lives in the caveat that follows.
func deliveriesBucket(n *int) string {
	if n == nil {
		return "UNMETERED"
	}
	return deliveriesSeconds(*n)
}

// deliveriesSplitCaveat warns when the split is PARTIAL. A partly-measured split
// is the one shape a reader will do arithmetic on without noticing: two buckets
// present and one UNMETERED reads as "the third was ~0", and the residual
// definition makes that reading actively wrong.
func deliveriesSplitCaveat(d cloudclient.PlatformDelivery) string {
	if d.QueuedSelfSeconds != nil && d.QueuedStallSeconds != nil && d.QueuedPickupSeconds != nil {
		return ""
	}
	return ". PARTIAL: an UNMETERED bucket was not measured, so these buckets do NOT add up to the wait above and the missing one is not 0"
}

// deliveriesBuiltLine renders the build duration, or why it is unknown.
func deliveriesBuiltLine(d cloudclient.PlatformDelivery) string {
	if d.BuildSeconds == nil {
		return "UNMETERED — no build duration was recorded for this run, so how long the build took is unknown (never read this as 0s, and never as 'instant')"
	}
	return deliveriesSeconds(*d.BuildSeconds) + " of build, from the job starting to the deploy finishing"
}

// deliveriesServingLine renders serving_since, or why it is unknown.
func deliveriesServingLine(d cloudclient.PlatformDelivery) string {
	if d.ServingSince == nil || strings.TrimSpace(*d.ServingSince) == "" {
		return "UNMETERED — nothing recorded when this sha started serving, so whether it ever reached the web is unknown (never read this as the epoch, and never as 'never live')"
	}
	return sanitizeCell(*d.ServingSince)
}

// deliveriesTransitionLine renders THE ROLLBACK VERDICT — what this delivery did
// to the platform, graded PREVIOUS-vs-NEW: was the sha it delivered ahead of,
// behind, or off the line from what the box was serving before.
//
// This is the field the crown gained so a rollback would stop reading as an
// ordinary deploy, and until dr-w27-s2 it never reached a human at all: the
// serializer emitted it, the decoder declared no field for it, and
// `json.Unmarshal` dropped it in silence, so a row whose transition was
// `rollback` printed byte-identically to one that moved `forward`.
//
// nil IS "NEVER ATTEMPTED" AND IS NOT "unknown". The schema keeps two distinct
// statements here on purpose (platform_delivery.ex): the word `unknown` means
// the writer TRIED to grade the move and could not decide — a gc'd sha, an
// unreachable box, a shallow clone — while a NULL means no verdict was ever
// attempted, usually because the row predates the columns. Collapsing them
// would tell an operator a grading was attempted and failed on every historical
// row in the table, which is a fact about this code rather than about the
// deploy. So nil gets its own UNRECORDED sentence, in the shape the carried
// block already established for the same reason.
//
// AN UNRECOGNISED WORD IS PRINTED, NEVER SWALLOWED. The vocabulary is closed
// today (forward | rollback | diverged | noop | unknown) and the writer holds it
// as a changeset inclusion, but a control plane running ahead of this binary can
// send a sixth word — and a `default:` that dropped it would render a graded
// move as an ungraded one, which is precisely the silence this line exists to
// end.
func deliveriesTransitionLine(d cloudclient.PlatformDelivery) string {
	previous := "previous sha NOT RECORDED"
	if d.PreviousSHA != nil && strings.TrimSpace(*d.PreviousSHA) != "" {
		previous = "from " + shortSha(strings.TrimSpace(*d.PreviousSHA))
	}

	if d.Transition == nil {
		return "UNRECORDED — NO rollback verdict was ever attempted for this delivery (the wire sent null, and the schema keeps\n" +
			"             no default so 'never attempted' cannot be recorded as a word). It is NOT the same as `unknown`, which\n" +
			"             means the writer TRIED to grade the move and could not decide. Whether this deploy went forward or\n" +
			"             rolled the platform back is not knowable from this row · " + previous
	}

	switch verdict := strings.TrimSpace(*d.Transition); verdict {
	case "rollback":
		return "ROLLBACK — this delivery moved the platform BACK: the sha it delivered is an ANCESTOR of what was being served before · " + previous
	case "forward":
		return "forward — the delivered sha is a descendant of what was being served before · " + previous
	case "diverged":
		return "DIVERGED — neither sha is an ancestor of the other, so the platform is serving code that left the line · " + previous
	case "noop":
		return "noop — the delivered sha is the one already being served, so this deploy delivered nothing new · " + previous
	case "unknown":
		return "unknown — the writer TRIED to grade this move and could NOT decide (a gc'd sha, an unreachable box, a shallow clone).\n" +
			"             This is a recorded refusal, not a missing one · " + previous
	case "":
		return "UNRECORDED — the wire carried an EMPTY transition, which is neither a verdict nor an honest null · " + previous
	default:
		return sanitizeCell(verdict) + " — a transition word this binary does not know (it grades PREVIOUS-vs-NEW, and the vocabulary it knows is\n" +
			"             forward · rollback · diverged · noop · unknown). Printed verbatim rather than dropped; upgrade `bp` to read it · " + previous
	}
}

// deliveriesSeconds renders a measured duration as SECONDS first, with a coarse
// human reading beside it once it stops being readable in seconds. Seconds lead
// because seconds are what was recorded — the parenthetical is a convenience and
// is never the only figure on the line.
func deliveriesSeconds(n int) string {
	if n < 90 {
		return fmt.Sprintf("%ds", n)
	}
	m, s := n/60, n%60
	if m < 60 {
		return fmt.Sprintf("%ds (%dm %ds)", n, m, s)
	}
	return fmt.Sprintf("%ds (%dh %dm)", n, m/60, m%60)
}

// printCloudDeliveriesHelp writes `bp cloud deliveries` usage.
func printCloudDeliveriesHelp(out *writer) {
	const help = `bp cloud deliveries — what actually happened to ONE merge.

USAGE
  bp cloud deliveries <sha> [--limit N]

WHAT IT READS
  The PLATFORM delivery record (GET /v1/deliveries): Barkpark's own deploys of
  this repo — one row per (sha, delivering run, first sighting) — with the clocks
  around each one. It is NOT 'bp cloud webhook deliveries', which lists ONE
  tenant instance's webhook send log and shares nothing with this but a word.

WHAT IT PRINTS
  merged · waited · split · built · serving · moved, in causal order, for one sha — plus
  the run that delivered it, saying OUT LOUD when that run is not the sha's own
  (a run that carried zero jobs gets its sha swept up by a later run, and then
  the waited/built seconds belong to that later run).

  The split breaks the wait into self · stall · pickup, where pickup is the
  RESIDUAL — what is left after the other two, never a magnitude threshold.

  ATTRIBUTION HAS THREE STATES, NOT TWO: this sha's OWN run, CARRIED by a later
  sha's run, or carried UNRECORDED — nobody measured which, in which case the
  OWNERSHIP of the seconds is unknown even when the seconds themselves are not.

  'moved' is the ROLLBACK VERDICT: forward · ROLLBACK · DIVERGED · noop, graded
  PREVIOUS-vs-NEW (what this box served before against what it serves now), plus
  the sha it moved from. A RECORDED 'unknown' means the writer tried and could
  not decide; UNRECORDED means no verdict was ever attempted — every row older
  than the columns reads that way, and it is not the same statement.

  A field the recorder could not reach prints as UNMETERED with the reason. It is
  never 0, never false and never blank: a missing build is not a build that took
  no time, and an unrecorded attribution is not a run that belonged to this sha.

  One sha, its own seconds. No population percentage is printed here at all —
  those belong with their window and their outlier policy, not on a single row.

FLAGS
  --limit N   how many rows to ask for (default 20; the route clamps its own
              ceiling). A sha can honestly have several rows.

EXIT
  0  the record was read — including an empty read, which means NOTHING was ever
     recorded for this sha (a 200 with an empty list, never a 404)
  3  the control plane refused the credential (401/403)
  8  the control plane has no delivery record to read (503) or the read failed`
	out.outf("%s", help)
}
