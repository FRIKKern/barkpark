package cli

// cloud_deploy_census_cmd.go is `bp cloud deployments` — the FIRST human reader
// of the deploy census (GET /v1/deploy-ledger/census, the TEAM-scoped read; the
// operator route it used to call is empty by construction in production). Seven
// waves of the deploy-reliability epic built a ledger that computes a failure
// rate WITH its denominator, and until this file no surface anywhere — CLI, SDK,
// console — read a number out of it. Five surfaces show deployments today (bp
// cloud site status, bp sites deployments, bp sites list, bp cloud status, the
// SPA site detail) and not one of them computes a rate: they are all
// newest-row-per-site by construction, which can express freshness and can never
// express a rate.
//
// WHY A NEW VERB AND NOT A LINE IN `bp cloud status`. `bp cloud status` is
// INSTANCE health, and its vocabulary is frozen against the committed
// cross-surface fixture cloud/priv/static/__fixtures__/attention_order.json.
// Adding a fleet-deploy line there alone would be exactly the cross-surface
// drift that fixture exists to catch.
//
// THE READER MUST BE ABLE TO SAY "I COULD NOT LOOK". A deploy census has FOUR
// distinct ways of not being a number, and three of them decode to a comforting
// ZERO if a reader coalesces nils instead of branching:
//
//   - 401 unauthorized — no session, or a dead one.
//   - 403 forbidden — authenticated, but the credential does not carry ability
//     "read" on this team. It names whatever authority the body reports, and
//     does NOT tell the reader to edit PLATFORM_ADMIN_EMAILS: on the team route
//     the operator allowlist has nothing to do with the refusal.
//   - 422 no_team — the credential belongs to no team, so there is no
//     population to take a census over. Widening the window cannot fix it, so
//     this is a DIFFERENT sentence from the window refusal below.
//   - 422 invalid_window — the window did not parse, or was not pinned.
//   - the IN-BAND refusal inside a 200: failure_rate.refused, because the sample
//     is below min_sample. The counts are real; the PERCENTAGE is refused, and
//     this reader prints the refusal rather than a percentage.
//
// Every one of those renders as a refusal that names itself. None of them ever
// renders as "0 failed".
//
// THE WINDOW IS PINNED AND PRINTED. The route requires from+to (422 otherwise)
// on purpose: daily deploy volume fell 2,766 → 332 over six days, so a floating
// "now minus N" window silently compares two different populations and reports a
// volume collapse as a repair. This verb computes a default window CLIENT-SIDE
// and prints it on every render, so the number on screen always carries the
// population it was taken over.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// deployCensusDefaultDays is the default window width when the caller pins
// neither --from nor --to. Seven days is wide enough to clear the census's
// min_sample on current volume and narrow enough that a class count is still
// about the fleet as it is now.
const deployCensusDefaultDays = 7

// deployCensusSiteRows is how many site rows the human render prints by default.
// The route returns up to 50; this is a display clamp the caller can lift with
// --sites (0 = every row the control plane sent).
const deployCensusSiteRows = 10

// deployCensusNow is the clock the default window is computed against. A package
// var (the cloudCtx idiom) so a test can pin the window it asserts.
var deployCensusNow = func() time.Time { return time.Now().UTC() }

// runCloudDeployments is `bp cloud deployments [--from X --to Y | --days N]
// [--sites N]`: read the team deploy census over a pinned window and render the
// rate WITH its denominator — or the refusal, named. Requires `bp login` and a
// credential carrying ability "read" on a team; no operator grant is involved.
func runCloudDeployments(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudDeploymentsHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudDeploymentsHelp(out)
		return exitOK
	}

	const usage = "bp cloud deployments [--days N | --from <date> --to <date>] [--sites N]"
	a, err := parseHzArgs(args, []string{"from", "to", "days", "sites"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 0 {
		return useError(out, "usage", fmt.Sprintf("takes no positional arguments (usage: %s)", usage), exitUsage)
	}

	from, to, werr := deployCensusWindow(a)
	if werr != nil {
		return useError(out, "usage", werr.Error(), exitUsage)
	}
	sites, serr := deployCensusSiteLimit(a)
	if serr != nil {
		return useError(out, "usage", serr.Error(), exitUsage)
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to read the deploy census for your team", exitAuth)
	}

	census, derr := cfg.CloudClient().FleetDeployCensus(cloudCtx(), from, to)
	if derr != nil {
		// BRANCH ON THE ERROR FIRST, ALWAYS. Below this point a zero-valued
		// census would print "0 failed of 0 attempted" — a fleet that looks
		// perfect because nobody was allowed to look at it.
		return deployCensusFail(out, from, to, derr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitDeployCensusRaw(out, census)
		return exitOK
	}
	renderDeployCensus(out, from, to, census, sites, deployCensusWindowPinned(a))
	return exitOK
}

// deployCensusWindowPinned reports whether the caller pinned BOTH edges with
// --from/--to. A --days window (and the 7-day default) pins only its width: its
// right edge is now and its left edge slides with the clock, which is exactly
// the property the coverage reading has to disclose — the same fleet answers a
// different never-covered count at --days 7 and --days 27 with no row changing.
func deployCensusWindowPinned(a *hzArgs) bool {
	_, hasFrom := lastVal(a, "from")
	return hasFrom
}

// deployCensusWindow resolves the PINNED window: --from/--to together, or a
// --days width ending now. --from and --to are all-or-nothing (a half-pinned
// window is the floating window this route exists to refuse), and --days cannot
// combine with either — two window definitions in one command is an ambiguity,
// not a convenience.
func deployCensusWindow(a *hzArgs) (time.Time, time.Time, error) {
	rawFrom, hasFrom := lastVal(a, "from")
	rawTo, hasTo := lastVal(a, "to")
	rawDays, hasDays := lastVal(a, "days")

	if hasDays && (hasFrom || hasTo) {
		return time.Time{}, time.Time{}, errors.New("--days cannot combine with --from/--to — pin the window one way or the other")
	}
	if hasFrom != hasTo {
		return time.Time{}, time.Time{}, errors.New("--from and --to must be given together — the census window is pinned, never half-open")
	}

	if hasFrom {
		from, err := parseCensusInstant(rawFrom, "--from")
		if err != nil {
			return time.Time{}, time.Time{}, err
		}
		to, err := parseCensusInstant(rawTo, "--to")
		if err != nil {
			return time.Time{}, time.Time{}, err
		}
		if !from.Before(to) {
			return time.Time{}, time.Time{}, errors.New("--from must be earlier than --to")
		}
		return from, to, nil
	}

	days := deployCensusDefaultDays
	if hasDays {
		n, err := strconv.Atoi(strings.TrimSpace(rawDays))
		if err != nil || n <= 0 {
			return time.Time{}, time.Time{}, fmt.Errorf("--days wants a positive whole number of days, got %q", rawDays)
		}
		days = n
	}
	to := deployCensusNow().UTC().Truncate(time.Second)
	return to.AddDate(0, 0, -days), to, nil
}

// deployCensusSiteLimit reads --sites: how many site rows to PRINT (0 = all the
// control plane sent). It is a display clamp only — it never changes the census
// the rate is computed from, so no flag on this verb can move the headline
// number.
func deployCensusSiteLimit(a *hzArgs) (int, error) {
	raw, has := lastVal(a, "sites")
	if !has {
		return deployCensusSiteRows, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || n < 0 {
		return 0, fmt.Errorf("--sites wants a non-negative whole number (0 = every site), got %q", raw)
	}
	return n, nil
}

// lastVal reads the final occurrence of a repeated value flag (the house
// last-wins convention), reporting whether it was given at all.
func lastVal(a *hzArgs, name string) (string, bool) {
	vals := a.vals[name]
	if len(vals) == 0 {
		return "", false
	}
	return vals[len(vals)-1], true
}

// parseCensusInstant accepts an ISO-8601 instant or a bare date (read as
// midnight UTC) — the same two forms the control plane's own parse_window/2
// accepts, so a window this CLI accepts is a window the route accepts.
func parseCensusInstant(raw, flag string) (time.Time, error) {
	s := strings.TrimSpace(raw)
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), nil
	}
	if t, err := time.Parse("2006-01-02", s); err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("%s wants an ISO-8601 date (2026-08-01) or instant (2026-08-01T00:00:00Z), got %q", flag, s)
}

// emitDeployCensusRaw writes the census for a machine consumer: json is the
// control plane's exact envelope BYTES (the emitRollbackRaw idiom — the envelope
// IS the contract, and re-encoding it here would make the CLI a second, drifting
// definition of it); yaml is a faithful re-encode.
func emitDeployCensusRaw(out *writer, census cloudclient.DeployCensus) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(census.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(census.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// deployCensusFail renders a census that could NOT be read. Every branch names
// what refused and prints the window anyway, so the operator can tell a healthy
// population from a population nobody was allowed to look at.
//
// A REFUSAL HAS NO SCOPE LINE TO CORRECT IT. On a 200 the render prints the
// population under the window; on a refusal there is nothing to print, because
// the control plane never told us which team it would have covered. Every
// sentence below therefore says "the deploy census for your team" and NEVER
// "the fleet" — over-claiming scope on the one render that has no scope line
// beneath it is the same defect this epic exists to kill.
func deployCensusFail(out *writer, from, to time.Time, err error) int {
	var ce *cloudclient.DeployCensusError
	if !errors.As(err, &ce) {
		return cloudFail(out, "read the deploy census for your team", err)
	}
	return useError(out, deployCensusErrLabel(ce), deployCensusMessage(from, to, ce), deployCensusExit(ce.HTTPStatus))
}

// deployCensusErrLabel is the `bp:` machine label — the control plane's own
// refusal code where it sent one, with a stable "failed" fallback for a body
// that carried none (a gateway page, a proxy error).
func deployCensusErrLabel(ce *cloudclient.DeployCensusError) string {
	if ce.Code == "" {
		return "failed"
	}
	return ce.Code
}

// deployCensusExit maps a refusal onto the CLI's stable exit ladder by STATUS
// FAMILY (the rollbackExit idiom), so a refusal code the control plane adds
// later is still exit-coded correctly without a CLI change.
func deployCensusExit(status int) int {
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

// deployCensusMessage is the one human sentence per refusal. Each one says
// plainly that NO number was read — never a count, never a rate — names the
// window that was asked for, and points at the fix.
func deployCensusMessage(from, to time.Time, ce *cloudclient.DeployCensusError) string {
	window := deployCensusWindowPhrase(from, to)
	switch {
	case ce.HTTPStatus == 401:
		return "could not read the deploy census for your team for " + window +
			" — the control plane did not recognise this session (401 unauthorized). Nothing was read: this is NOT a population with zero failures. Run `bp login` and try again."
	case ce.HTTPStatus == 403:
		authority := deployCensusAuthority(ce)
		return "could not read the deploy census for your team for " + window +
			" — the control plane refused this credential (403 forbidden" + authority + "). Nothing was read: this is NOT a population with zero failures. " +
			"This read needs a token carrying ability \"read\" on your team; an operator allowlist is not involved. " +
			"Run `bp login` again, or ask a team owner for a token with read access."
	// THE 422s ARE TWO DIFFERENT REFUSALS AND MUST NOT SHARE A SENTENCE. This
	// arm discriminates on the control plane's error CODE, never on the status
	// family: `no_team` says the credential has no population at all, and
	// telling that caller to widen the window sends them round a loop that
	// cannot terminate.
	case ce.HTTPStatus == 422 && ce.Code == "no_team":
		return "could not read the deploy census for " + window +
			" — this credential belongs to no team (422 no_team), so there is no population to take a census over. " +
			"Nothing was read: this is NOT a population with zero failures, and no window can fix it. " +
			"Join or create a team, then run `bp login` again."
	case ce.HTTPStatus == 422:
		detail := ce.Detail
		if detail == "" {
			detail = "the window did not parse"
		}
		return "the control plane refused the census window " + window +
			" (422 " + deployCensusErrLabel(ce) + "): " + sanitizeCell(detail) +
			". Nothing was read. Pin the window with --from/--to (an ISO date or instant) or widen it with --days."
	case ce.HTTPStatus >= 500:
		return "the control plane failed to compute the deploy census for your team for " + window +
			" (HTTP " + strconv.Itoa(ce.HTTPStatus) + ": " + sanitizeCell(ce.Error()) + "). Nothing was read — retry, and if it persists the census query itself is the fault."
	default:
		return "could not read the deploy census for your team for " + window +
			" (HTTP " + strconv.Itoa(ce.HTTPStatus) + ": " + sanitizeCell(ce.Error()) + "). Nothing was read."
	}
}

// deployCensusAuthority renders the authority evidence a 403 body carries, so
// the refusal names WHICH permission was missing rather than just saying no.
func deployCensusAuthority(ce *cloudclient.DeployCensusError) string {
	var parts []string
	if ce.Scope != "" {
		parts = append(parts, "scope="+sanitizeCell(ce.Scope))
	}
	if ce.Required != "" {
		parts = append(parts, "required="+sanitizeCell(ce.Required))
	}
	if len(parts) == 0 {
		return ""
	}
	return " — " + strings.Join(parts, ", ")
}

// deployCensusScopeLine names the POPULATION the census was taken over, on
// every human render, directly under the window.
//
// A window without a population is half a claim: "37.5% failed over seven days"
// reads identically whether it covers the whole fleet or one team's thirteen
// sites, and those are different sentences. The team route sends a `scope` node
// for exactly this reason.
//
// A NIL SCOPE SAYS SO OUT LOUD. An older control plane (and the operator route)
// sends no scope key at all, and DeployCensus.Scope is a pointer so that case
// arrives as nil rather than as team "". This prints "population NOT NAMED" —
// never a silent omission (a reader cannot notice a line that is not there) and
// never an empty team slug dressed as an answer.
//
// THE COUNT IS LABELLED. registered_sites counts sites REGISTERED to the team
// and in scope, which deliberately EXCEEDS len(sites) — a site that has never
// deployed is registered and absent from the sites table below. Printing a bare
// "13" beside twelve site rows is the first thing an operator would have to
// explain away, so the label travels with the number.
func deployCensusScopeLine(scope *cloudclient.DeployCensusScope) string {
	if scope == nil || strings.TrimSpace(scope.Team) == "" {
		return "  scope: population NOT NAMED — this control plane sent no scope node, so which sites these numbers cover is unknown. The numbers are real; the population is not stated."
	}
	return fmt.Sprintf("  scope: team %s · %d sites registered to this team and in scope (not the number that deployed in the window — a site that never deployed is counted here and absent below)",
		sanitizeCell(scope.Team), scope.RegisteredSites)
}

// renderDeployCensus is the human view: the window, the headline rate line (rate
// + volume + denominator, on ONE line, always), then the failure classes, the
// deferrals and the worst sites.
func renderDeployCensus(out *writer, from, to time.Time, census cloudclient.DeployCensus, siteLimit int, pinnedWindow bool) {
	out.outf("deploy census · %s", deployCensusWindowPhrase(from, to))
	out.outf("  the window is pinned by this command, not defaulted by the server — every number below is about THIS population.")
	out.outf("%s", deployCensusScopeLine(census.Scope))
	out.outf("")
	boundaries := deployCensusBoundaries(census.Boundaries)
	out.outf("%s", deployCensusHeadline(census))
	if line := deployCensusHeadlineRemedy(census, boundaries, from, to); line != "" {
		out.outf("%s", line)
	}
	out.outf("  basis: %s", deployCensusBasis(census))
	// THE ONE QUANTITY NO BUCKET SWAP CAN DILUTE, printed beside the rates it
	// cannot be reduced to. Every rate above is a ratio over a population the
	// fleet's own labelling decides the size of; this is a count of publishes
	// that are permanently gone.
	out.outf("  %s", deployCensusAbandonment(census))
	out.outf("  %s", deployCensusCompletenessLine(census.Completeness))
	out.outf("")

	if len(census.Classes) > 0 {
		out.outf("failure classes (share of the %d failed · accuses = who the class blames: box / site / ambiguous)", census.Failed)
		for _, c := range census.Classes {
			out.outf("%s", deployCensusClassRow(c))
		}
		for _, line := range deployCensusShareNotes(census.Classes, boundaries, from, to, census.MinSample) {
			out.outf("%s", line)
		}
		out.outf("")
	}
	if len(census.Deferred) > 0 {
		out.outf("deferrals (in the volume, never in the failure numerator)")
		for _, c := range census.Deferred {
			out.outf("%s", deployCensusClassRow(c))
		}
		// THE DEFERRAL SHARES GET THEIR OWN NOTE, COMPUTED OVER THEIR OWN ROWS.
		// Failure-class shares divide by the settled failures; deferral shares
		// divide by the attempted rows. They are different denominators over the
		// same window, so one merged note would attach a refusal to a population
		// that never produced it.
		for _, line := range deployCensusShareNotes(census.Deferred, boundaries, from, to, census.MinSample) {
			out.outf("%s", line)
		}
		out.outf("")
	}
	// THE CROSS-REFERENCE, printed between the two cohorts it connects. Box
	// capacity is ONE physical cause reported through TWO of them —
	// ABANDONED_AT_CAPACITY inside the failure numerator, BOX_AT_CAPACITY_DEFERRED
	// outside it — and nothing else on this screen says they are the same box
	// being full. It re-classifies nothing.
	if line := deployCensusCapacityLine(census); line != "" {
		out.outf("%s", line)
		out.outf("")
	}
	renderDeployDeferralWait(out, census.DeferralWait)
	renderDeployCoverageCohorts(out, census.CoverageCohorts, pinnedWindow)

	if len(census.NotAttempted) > 0 {
		out.outf("never attempted (outside every denominator)")
		for _, c := range census.NotAttempted {
			out.outf("  %-28s %6d  %s", sanitizeCell(c.Class), c.Count, sanitizeCell(c.Label))
		}
		out.outf("")
	}

	renderDeployDelivery(out, census.Delivery, siteLimit)

	rows := census.Sites
	if siteLimit > 0 && len(rows) > siteLimit {
		rows = rows[:siteLimit]
	}
	if len(rows) > 0 {
		out.outf("sites (by volume)")
		for _, s := range rows {
			top := "—"
			if s.TopClass != nil && strings.TrimSpace(*s.TopClass) != "" {
				top = sanitizeCell(*s.TopClass)
			}
			out.outf("  %-38s %6d attempted  %9s live  %6d failed  %6d deferred  %-7s %-9s %s",
				sanitizeCell(s.SiteID), s.Volume, deployCensusSiteLive(s), s.Failed, s.Deferred,
				deployCensusShare(s.FailureRate), deployCensusSiteTerminal(s), top)
		}
		if n := len(census.Sites) - len(rows); n > 0 {
			out.outf("  … and %d more (raise the display clamp with --sites 0)", n)
		}
		if line := deployCensusSiteTruncationLine(census); line != "" {
			out.outf("%s", line)
		}
		if line := deployCensusSiteLiveNote(rows); line != "" {
			out.outf("%s", line)
		}
		for _, line := range deployCensusSiteNotes(rows, boundaries, from, to, census.MinSample) {
			out.outf("%s", line)
		}
	} else {
		out.outf("no site had a deploy row in this window — widen it with --days.")
	}
}

// deployCensusHeadline builds THE line: the rate, its volume, and the
// denominator it was taken against, all together, never apart.
//
// LIVE-PER-ATTEMPT LEADS IT, AND THE FAILURE RATE IS A LABELLED SIBLING. A
// headline that leads with the failure rate answers "how bad is it" and never
// answers "did anything ship" — on 2026-08-07 that number read 1.1% on a day
// where 72% of attempts produced nothing at all. The live term is rendered by
// deployCensusLiveTerm in BOTH branches below (the ok-rate branch AND the
// refused branch): a prepend on the ok branch only silently drops the live rate
// exactly when the failure rate is refused, which is the case an operator most
// needs it, and it passes a guard vacuously because the refused branch never
// renders the term at all.
//
// It renders BOTH D34 conventions when the control plane sends both (the
// attempted-row rate the ledger has always had, and the dr-w8-s1
// terminal_failure_rate), and exactly one — SAYING which denominator it is —
// against today's payload, which carries neither `live` nor
// `terminal_failure_rate`. A refusing rate node prints its refusal here, in the
// headline's own place, so a reader cannot miss it.
//
// Everything rides ONE line on purpose: the live rate on a line of its own
// would also be a second line carrying "of N attempted", and a reader (human or
// test) that reaches for the headline by that phrase would find whichever came
// first.
func deployCensusHeadline(census cloudclient.DeployCensus) string {
	cohorts := []string{fmt.Sprintf("%d failed", census.Failed)}
	if d := deployCensusDeferredTotal(census); d > 0 {
		cohorts = append(cohorts, fmt.Sprintf("%d deferred", d))
	}
	if census.Live != nil {
		cohorts = append(cohorts, fmt.Sprintf("%d live", *census.Live))
	}
	cohorts = append(cohorts, deployCensusEndStates(census)...)
	breakdown := " (" + strings.Join(cohorts, " · ") + ")"

	live := deployCensusLiveTerm(census)
	var head string
	if pct, okRate := deployCensusPct(census.FailureRate); okRate {
		head = fmt.Sprintf("%s · failure %s of %d attempted%s", live, pct, census.FailureRate.Sample, breakdown)
	} else {
		head = fmt.Sprintf("%s · failure NO RATE — %s · %d attempted%s",
			live, deployCensusRefusal(census.FailureRate, census.MinSample), census.FailureRate.Sample, breakdown)
	}

	if census.TerminalFailureRate == nil {
		// Today's payload. Say which denominator the ONE rate is on, and say what
		// it is missing — never imply this is the only convention that exists.
		return head + " · denominator = ATTEMPTED rows, deferrals included (this control plane sends no terminal-row rate)"
	}
	if pct, okRate := deployCensusPct(*census.TerminalFailureRate); okRate {
		return head + fmt.Sprintf(" · %s of %d terminal", pct, census.TerminalFailureRate.Sample)
	}
	return head + fmt.Sprintf(" · terminal rate: NO RATE — %s (%d terminal)",
		deployCensusRefusal(*census.TerminalFailureRate, census.MinSample), census.TerminalFailureRate.Sample)
}

// deployCensusLiveTerm renders the live-per-attempt node — the headline's
// leading term. It is a rate node like any other, so it has the same three
// endings, and NONE of them is a zero:
//
//   - the control plane does not send `live_rate` at all (every control plane
//     older than dr-w16-s2): it says so. Silence there would read as a fleet
//     that ships nothing, which is a different and much worse claim;
//   - the node REFUSES (below min_sample): it prints the refusal, with no
//     percentage, exactly as the failure rate does;
//   - it has a percentage: the rate WITH the sample it was taken over.
func deployCensusLiveTerm(census cloudclient.DeployCensus) string {
	if census.LivePerAttempt == nil {
		return "live per attempt: NOT SENT — this control plane does not compute it (nothing here says whether this population ships)"
	}
	rate := *census.LivePerAttempt
	if pct, okRate := deployCensusPct(rate); okRate {
		return fmt.Sprintf("live %s of %d attempted", pct, rate.Sample)
	}
	return "live per attempt: NO RATE — " + deployCensusRefusal(rate, census.MinSample)
}

// deployCensusEndStates renders the dr-w16-s2 cohorts that make success stop
// being the unnamed remainder of Volume: in-flight rows, cancelled rows, and
// the RESIDUAL — attempted rows whose status the census does not name.
//
// in_flight and cancelled print only when the control plane sent them AND they
// are non-zero (a zero cohort is noise in a headline). The residual prints
// whenever it was sent, INCLUDING zero: "0 residual" is the census asserting it
// named every row, and a residual that starts rising is the signal this field
// exists for — hiding it at zero would hide the day it stops being zero.
//
// `cancelled` HAS NEVER EXISTED ON PROD: 0 of 31,137 deployment rows all-time
// (both spellings, since 2026-07-14); the lifetime status vocabulary is exactly
// failed / live / deferred. Two producers exist and neither has ever fired. So
// this branch is proved on a hand-made envelope in the test beside it, and a
// prod render of it is unobtainable — any acceptance that implies one is
// vacuous.
func deployCensusEndStates(census cloudclient.DeployCensus) []string {
	var out []string
	if census.InFlight != nil && *census.InFlight > 0 {
		out = append(out, fmt.Sprintf("%d in flight", *census.InFlight))
	}
	if census.Cancelled != nil && *census.Cancelled > 0 {
		out = append(out, fmt.Sprintf("%d cancelled", *census.Cancelled))
	}
	if census.Residual != nil {
		out = append(out, fmt.Sprintf("%d residual (attempted rows this census does not name)", *census.Residual))
	}
	return out
}

// deployCensusBasis names the DENOMINATOR every rate above it was taken over,
// corrects the one word the control plane's own basis gets wrong, and then says
// HOW BIG the correction is FOR THIS WINDOW — measured, or refused, never
// frozen.
//
// The census calls its denominator "attempted rows". It is rows, and it is NOT
// attempts: the (site_id, environment) active index refuses a second concurrent
// production build, so an attempt that coalesces onto an in-flight build
// completes having minted NO deployment row. Measured on cloud-db-1, auto-deploy
// worker jobs against `trigger='content-auto'` rows: 2026-08-05 excluded 171,
// 2026-08-06 excluded 1,584 against 2,182 counted rows, 2026-08-07 excluded 106.
// Every excluded attempt is non-live, so including them can only LOWER the live
// rate — which makes live-per-attempt as computed here a CEILING, in the
// flattering direction.
//
// THE FROZEN SENTENCE IS GONE, AND WHY IT HAD TO GO. The three figures above are
// provenance for the PHENOMENON; they are not, and were not, a report on the
// window a reader asked for. This line used to append one of them — "(measured
// 2026-08-06: 3,766 auto-deploy worker jobs against 2,182 rows — 1,584 attempts
// excluded)" — to EVERY render regardless of the window. That literal is not
// WRONG for its own day; it is WINDOW-INDEPENDENT, which on any other window is
// a different failure: on a `--days 1` screen whose own counter reads low double
// digits it asserts an exclusion mass of 72.6% while the instrument measuring
// exactly that quantity for the rendered window says something else entirely.
// The comment that justified the hardcode ("coalesced_attempts now lands on the
// row but is not in this envelope") was itself refuted: it IS in the envelope,
// and as of dr-w23-s4 it is decoded — see deployCensusCoalescedTerm, which
// renders the window's OWN number or the producer's own refusal.
//
// It prints on EVERY render, including the payload that sends no basis at all,
// and it carries no percentage — the basis line must be safe to print beside a
// rate that refused one.
func deployCensusBasis(census cloudclient.DeployCensus) string {
	const correction = "denominator = deployment ROWS, not attempts. An attempt that coalesces onto an in-flight build completes without minting a row, so it is never counted here. " +
		"Every excluded attempt is non-live, so the live rate above is a CEILING."
	line := correction + " " + deployCensusCoalescedTerm(census.CoalescedAttempts)
	if b := strings.TrimSpace(census.FailureRate.Basis); b != "" {
		return sanitizeCell(b) + " — " + line
	}
	return line
}

// deployCensusCoalescedTerm renders the coalesced-attempt gauge — how many
// attempts THIS window excluded from the denominator above — and it has three
// endings, none of which is a bare zero:
//
//   - the control plane sends no `coalesced_attempts` node at all: NOT MEASURED.
//     Silence here reads as "nothing was excluded", which is the flattering
//     reading of an absence and the exact claim nobody made;
//   - the node REFUSES: it prints the producer's own reason and NO number. The
//     refusal is a COVERAGE floor, not a sample floor — the counter column
//     landed in migration 20260807150000 and every earlier row carries a
//     materialised 0 rather than a NULL, so a SUM over an earlier window returns
//     a confident 0 for a day whose true coalesced volume was ~1,563. A renderer
//     that printed that 0 would manufacture precisely the confidence the
//     producer refused to manufacture;
//   - it has a value: the count, said to be THIS window's, with the producer's
//     own basis for what it counts. Zero prints as zero HERE and only here —
//     because here it is a measurement ("this window excluded none"), which is a
//     different sentence from a decoder's zero.
//
// This follows the `delivery — NOT MEASURED` precedent above: an honest absence
// is rendered, never omitted, because a reader cannot notice a line that is not
// there.
func deployCensusCoalescedTerm(c *cloudclient.DeployCoalescedAttempts) string {
	if c == nil {
		return "Coalesced attempts NOT MEASURED: this control plane sends no coalesced-attempt counter, so how many attempts this window excluded is UNKNOWN — it is not zero."
	}
	if c.Refused || c.Value == nil {
		reason := strings.TrimSpace(c.Reason)
		if reason == "" {
			reason = "the control plane refused a count for this window and sent no reason"
		}
		return "Coalesced attempts NOT MEASURED for this window: " + sanitizeCell(reason) + "."
	}
	term := fmt.Sprintf("Coalesced attempts measured over THIS window: %d", *c.Value)
	if basis := strings.TrimSpace(c.Basis); basis != "" {
		term += " (" + sanitizeCell(basis) + ")"
	}
	return term + "."
}

// deployCensusCapacityLine is the ONE cross-reference line: box capacity is a
// single physical cause that this census reports through TWO cohorts, and no
// line on the rendered screen has ever connected them.
//
// A capacity 409 that settles `failed` routes through the FAILED arm and lands
// in the failure numerator as ABANDONED_AT_CAPACITY (which is NOT BOX_BUSY_409 —
// that is the separate, non-abandoned refusal class); rows of the SAME cause
// that were re-queued sit in the deferral cohort as BOX_AT_CAPACITY_DEFERRED,
// deliberately outside the numerator. Measured live over 2026-08-07T00:00-06:00Z
// the two read 6 and 719, five columns apart on the same screen, with nothing
// saying they are the same box being full.
//
// IT DOES NOT RE-CLASSIFY ANYTHING. Whether an abandoned publish belongs in the
// failure numerator is a JUDGMENT — the content genuinely never shipped — and
// this reader deliberately does not make it. The line names the split and gives
// both counts; the cohorts are exactly as the control plane sent them.
//
// It returns "" when BOTH counts are zero: a cross-reference to two absent
// cohorts is noise, and printing "0 and 0" would assert a split that this window
// did not have.
func deployCensusCapacityLine(census cloudclient.DeployCensus) string {
	abandoned := deployCensusClassCount(census.Classes, "ABANDONED_AT_CAPACITY")
	deferred := deployCensusClassCount(census.Deferred, "BOX_AT_CAPACITY_DEFERRED")
	if abandoned == 0 && deferred == 0 {
		return ""
	}
	return fmt.Sprintf("box capacity is ONE cause reported through TWO cohorts: ABANDONED_AT_CAPACITY %d (in the failure classes, INSIDE the failure numerator) and BOX_AT_CAPACITY_DEFERRED %d (in the deferrals, OUTSIDE it). "+
		"Same full box, two cohorts. This reader does not move either row: whether an abandoned publish belongs in the failure numerator is a judgment, not a rendering.",
		abandoned, deferred)
}

// deployCensusClassCount reads ONE named class count out of a cohort, or 0 when
// this window carried no such class. It matches the class name exactly — a
// prefix or contains match would fold BOX_AT_CAPACITY_DEFERRED and a future
// BOX_AT_CAPACITY_* sibling into one number.
func deployCensusClassCount(rows []cloudclient.DeployCensusClass, class string) int {
	for _, r := range rows {
		if r.Class == class {
			return r.Count
		}
	}
	return 0
}

// deployCensusDeferredTotal is the deferral cohort's size — the third cohort,
// inside the volume and outside the failure numerator, which is why a reader
// that prints only failed/attempted makes a relocated 409 mass look deleted.
//
// THE SERVER'S OWN COUNT WINS (dr-w12-s8). Summing Deferred's class rows here is
// a SECOND definition of the number living on the far side of the wire, and it
// is the definition that can be wrong without saying so: a control plane that
// truncated, filtered or simply did not send the class rows makes this loop
// answer a confident 0 for a fleet that deferred thousands. `deferred_total` is
// the emitter's own arithmetic over the rows it actually folded, so it is
// preferred whenever it is sent; the sum stays as the fallback for a control
// plane that predates the key, because refusing to render anything there would
// be a regression for every older CP.
func deployCensusDeferredTotal(census cloudclient.DeployCensus) int {
	if census.DeferredTotal != nil {
		return *census.DeferredTotal
	}
	total := 0
	for _, c := range census.Deferred {
		total += c.Count
	}
	return total
}

// deployCensusSiteTerminal renders a site's TERMINAL failure rate — the same
// numerator as the column beside it, over failed+live instead of over every
// attempted row. The two columns differ by exactly this site's deferral mass,
// which is the point: the site whose 409s became deferrals is the site whose
// attempted-basis rate fell without one outcome changing, and reading only the
// first column is how that site reads as a site that got healthy.
//
// A control plane that does not send it renders "t —", never a percentage and
// never a blank: a blank column reads as 0% to a scanning eye.
func deployCensusSiteTerminal(s cloudclient.DeployCensusSite) string {
	if s.TerminalFailureRate == nil {
		return "t —"
	}
	return "t " + deployCensusShare(*s.TerminalFailureRate)
}

// deployCensusAbandonment renders the ABSOLUTE COUNT of publishes given up on,
// and — separately — how much of the population the count could not be taken
// over. Three endings, and none of them is a bare zero:
//
//   - `abandoned` absent: this control plane does not count abandonments at all.
//     Printing "0 abandoned" there would be a measurement nobody took;
//   - present, with `abandoned_unreadable` non-zero: the number is a LOWER
//     BOUND, and it says so with the size of the blind spot beside it. The
//     abandonment marker is prose in `failure_reason` and those rows recorded
//     none, so the predicate did not answer "no" — it did not run;
//   - present and fully legible: the count, flat.
//
// It is a COUNT and never a rate on purpose (charter D174/D142): a rate over a
// bucket the fleet can relabel is a number the fleet can improve without one
// publish succeeding, and an abandoned publish is permanently lost either way.
func deployCensusAbandonment(census cloudclient.DeployCensus) string {
	if census.Abandoned == nil {
		return "abandoned publishes: NOT COUNTED — this control plane does not measure them (absence, not zero)"
	}
	if census.AbandonedUnreadable != nil && *census.AbandonedUnreadable > 0 {
		return fmt.Sprintf(
			"abandoned publishes: %d or more — %d failed row(s) recorded no reason, so the abandonment marker could not be read on them (LOWER BOUND)",
			*census.Abandoned, *census.AbandonedUnreadable)
	}
	return fmt.Sprintf("abandoned publishes: %d", *census.Abandoned)
}

// deployCensusPct renders a rate node as a percentage, or reports that it has
// none. A REFUSED node, and a node whose pct is absent, both answer false — the
// caller must then render a refusal, because there is no honest number here.
//
// dr-w8-s4 followup: the number rendered is the control plane's own `pct`,
// VERBATIM — never recomputed from numerator/sample. The old path re-derived
// it through pctOf's one-decimal format, so the census whose contract pct was
// 37.55 printed 37.5% and a reader comparing the CLI against a raw curl of the
// census route had to work out which figure was authoritative. The envelope is
// the single definition of the number; this renderer repeats it. (pctOf keeps
// its other callers — they render shares this client computes itself, where a
// display format is the only definition there is.) Headline, class shares and
// site shares all route through here, so one page renders one precision rule.
func deployCensusPct(r cloudclient.DeployRate) (string, bool) {
	if r.Refused || r.Pct == nil {
		return "", false
	}
	return strconv.FormatFloat(*r.Pct, 'f', -1, 64) + "%", true
}

// deployCensusClassRow is ONE class/deferral table row: class, count, share,
// who it accuses, label. The agency cell is the dr-w31 addition
// (dr-w31-fu-agency-reaches-the-cli): DeployLedger emits `agency` on every
// class row (box / site / ambiguous, frozen in its own @agency map) and until
// this cell the value was decoded by nobody — the operator could not see who a
// failure class accuses. An older control plane that never sent the key
// renders "not sent": an absent attribution is stated, never invented.
func deployCensusClassRow(c cloudclient.DeployCensusClass) string {
	agency := strings.TrimSpace(c.Agency)
	if agency == "" {
		agency = "not sent"
	}
	return fmt.Sprintf("  %-28s %6d  %-7s accuses: %-9s %s",
		sanitizeCell(c.Class), c.Count, deployCensusShare(c.Share), sanitizeCell(agency), sanitizeCell(c.Label))
}

// deployCensusCompletenessLine renders census/3's SECOND independent count —
// the census auditing itself (dr-w31-fu-agency-reaches-the-cli: decoded
// already, rendered by nobody, so the self-audit rode the wire into silence).
// Three endings, none of them silence-as-health:
//
//   - the control plane sent no node: it has not audited anything, and that is
//     said — never rendered as a balanced census;
//   - balanced: every audited row is accounted for by a named cohort, with the
//     method string that names the audit's own blind spot;
//   - NOT balanced: N rows are in NO named cohort — the census's own numbers
//     do not sum, which is the loudest thing this line can say.
func deployCensusCompletenessLine(c *cloudclient.DeployCensusCompleteness) string {
	if c == nil {
		return "completeness: NOT AUDITED — this control plane does not run the census's second count, so nothing here certifies the cohorts sum to the volume"
	}
	if c.Balanced {
		return fmt.Sprintf("completeness: BALANCED — %d rows audited, every one accounted for by a named cohort (method: %s)",
			c.Audited, sanitizeCell(c.Method))
	}
	reason := ""
	if c.Reason != nil && strings.TrimSpace(*c.Reason) != "" {
		reason = " · reason: " + sanitizeCell(*c.Reason)
	}
	return fmt.Sprintf("completeness: NOT BALANCED — %d of %d audited rows are in NO named cohort: the census's own numbers do not sum (accounted %d; method: %s%s)",
		c.Unaccounted, c.Audited, c.Accounted, sanitizeCell(c.Method), reason)
}

// deployCensusRefusal is the in-band refusal in words: the control plane's own
// reason where it sent one, else the sample-versus-min_sample sentence built
// from the node itself. It never contains a percentage.
func deployCensusRefusal(r cloudclient.DeployRate, censusMin int) string {
	if reason := strings.TrimSpace(r.Reason); reason != "" {
		return "the control plane refused a percentage: " + sanitizeCell(reason)
	}
	min := r.MinSample
	if min <= 0 {
		min = censusMin
	}
	if min > 0 {
		return fmt.Sprintf("the control plane refused a percentage: sample %d below min_sample %d", r.Sample, min)
	}
	return fmt.Sprintf("the control plane sent no percentage for a sample of %d", r.Sample)
}

// deployCensusHeadlineRemedy gives the HEADLINE failure_rate refusal the same
// envelope-read window remedy the share refusals carry
// (dr-w30-followup-headline-refusal-names-the-window). dr-w30-s5 cured the
// CLASS and DEFERRAL share refusals; the headline — the first refusal an
// operator reads, and the only one on a census with no class rows at all —
// still printed the straddle reason with no remedy, so the operator was told
// the window straddles a boundary and not that `--from <instant>` answers it.
//
// It REUSES deployCensusShareRemedy — one owner of the boundary logic, exactly
// as deployCensusSiteRemedy does — and renders nothing when the headline
// carries a real percentage: a remedy under an answered rate would read as
// doubt the answer never expressed.
//
// PER-SITE CELLS, DECIDED (this row's second criterion): they already carry
// their remedy — deployCensusSiteRemedy renders under the site table for every
// refused per-site rate, routed through the same shared helper when the reason
// names a boundary — so nothing more is owed there and no second copy exists.
func deployCensusHeadlineRemedy(census cloudclient.DeployCensus, boundaries []deployCensusBoundary, from, to time.Time) string {
	if _, okRate := deployCensusPct(census.FailureRate); okRate {
		return ""
	}
	reason := deployCensusRefusal(census.FailureRate, census.MinSample)
	return "  " + deployCensusShareRemedy(reason, boundaries, from, to, census.MinSample)
}

// deployCensusShare renders a class/site share cell, or an em-dash where the
// share was refused — never a 0.0% standing in for "we would not say".
func deployCensusShare(r cloudclient.DeployRate) string {
	if pct, okRate := deployCensusPct(r); okRate {
		return pct
	}
	return "—"
}

// ─── THE SITE ROWS OWE THE SAME THREE ANSWERS THE HEADLINE OWES ──────────────
//
// The headline was cured of this exact disease and the site rows were not. A
// line that leads with a failure rate answers "how bad is it" and never answers
// "did anything ship", which is why deployCensusLiveTerm exists. Under it, every
// site row rendered attempted/failed/deferred and a share cell, and success was
// the unnamed remainder — per site.
//
// MEASURED, NOT SUPPOSED. The real 200 quoted on cloudclient.DeployCensusSite —
// {"volume":435,"failed":1,"deferred":325,"live":109} — rendered as "435
// attempted, 1 failed, 325 deferred, 0.2%". A reader takes that for a healthy
// site. 109 of the 435 shipped, and the wire SAID SO: `live` has been on the
// payload since #10519 and on this struct since dr-w19-s7, and this renderer
// decoded it and dropped it. The reader could not recover it either, because
// `attempted − failed − deferred` is the FORBIDDEN subtraction (site_row/2's own
// comment): it folds in-flight, cancelled and residual rows into live.
//
// AND THE SHARE CELL'S EM-DASH IS A REFUSAL NOBODY NAMED. Class shares and
// deferral shares each get deployCensusShareNotes beneath their rows; the site
// section got nothing, so `—` conflated "refused below min_sample" with "no
// failures" with "this control plane sent no rate". Per-site rates are the ones
// that refuse most: site_row/2 denominates each one on that SITE's own volume,
// so the floor is min_sample per site, not across the fleet.

// deployCensusSiteLive renders one site's shipped count — the same three endings
// as the fleet's live term, and none of them is a zero. A control plane older
// than #10519 sends no per-site `live` at all, and that must render UNMETERED:
// a zero-live site is the most alarming reading of an absence there is.
func deployCensusSiteLive(s cloudclient.DeployCensusSite) string {
	if s.Live == nil {
		return "UNMETERED"
	}
	return strconv.Itoa(*s.Live)
}

// deployCensusSiteLiveNote explains the UNMETERED cells once, beneath the rows,
// and forecloses the subtraction a reader would otherwise reach for. It prints
// only when a row actually went unmetered — this is a note about an absence, not
// a caption.
func deployCensusSiteLiveNote(rows []cloudclient.DeployCensusSite) string {
	unmetered := 0
	for _, s := range rows {
		if s.Live == nil {
			unmetered++
		}
	}
	if unmetered == 0 {
		return ""
	}
	return fmt.Sprintf("  PER-SITE LIVE UNMETERED on %d of %d rows above — this control plane sends no per-site `live`, "+
		"so nothing here says how many of those attempts SHIPPED. `attempted − failed − deferred` is NOT the answer: "+
		"it folds in-flight, cancelled and residual rows into live.", unmetered, len(rows))
}

// deployCensusSiteTruncationLine says whether the site rows above are the whole
// population — the SERVER's claim, never one derived from this process's own
// display clamp. The "… and N more" line beside it is about what this render
// chose not to print; this line is about what the control plane never sent.
// Three endings, and none of them is silence-as-completeness:
//
//   - Truncated == nil: the control plane predates the marker (dr-w18-s2). It
//     did not say whether the list is complete, and this line says exactly
//     that, because an unstated population is how the top 50 of a large fleet
//     reads as a complete 50-site fleet.
//   - *Truncated == true: the SERVER cut the list. No --sites flag can restore
//     rows that never rode the wire, and the line says so; TotalSites names
//     the real population when it was sent.
//   - *Truncated == false: the server AFFIRMED completeness — the one case
//     where "these are all the sites" is a claim someone actually made.
func deployCensusSiteTruncationLine(census cloudclient.DeployCensus) string {
	if census.Truncated == nil {
		return "  population NOT STATED — this control plane sends no truncated/total_sites marker, so whether these rows are the whole population or the top of a larger one is unknown."
	}
	if *census.Truncated {
		if census.TotalSites != nil {
			return fmt.Sprintf("  SERVER-TRUNCATED: the control plane sent %d of %d site(s) — the rows above are the TOP of the population, and no --sites value can restore rows that never rode the wire.",
				len(census.Sites), *census.TotalSites)
		}
		return "  SERVER-TRUNCATED: the control plane cut this list and did not say at what population — the rows above are the top of a larger one."
	}
	if census.TotalSites != nil {
		return fmt.Sprintf("  complete: the control plane sent all %d site(s) in this window (before any display clamp).", *census.TotalSites)
	}
	return "  complete: the control plane affirmed no site row was cut (before any display clamp)."
}

// deployCensusSiteNotes is deployCensusShareNotes' counterpart for the site
// section: the refusal behind every em-dash, named, with the remedy that fits.
//
// GROUPED BY REMEDY, AND THE DENOMINATOR TRAVELS AS A RANGE. Every site rate is
// denominated on that site's OWN volume, so grouping by reason (which carries
// the sample) would emit one note pair per row and grouping by reason alone
// would print one row's n over a count that includes rows never taken over it —
// the precise error deployCensusShareNotes splits its groups to avoid. Reporting
// the observed span of samples states only what the rows themselves state.
func deployCensusSiteNotes(rows []cloudclient.DeployCensusSite, boundaries []deployCensusBoundary, from, to time.Time, minSample int) []string {
	type group struct {
		remedy string
		floor  int
		rows   int
		lo, hi int
	}
	var groups []group
	for _, s := range rows {
		r := s.FailureRate
		if !r.Refused && r.Pct != nil {
			continue
		}
		reason := deployCensusRefusal(r, minSample)
		remedy := deployCensusSiteRemedy(reason, boundaries, from, to, minSample)
		floor := r.MinSample
		if floor <= 0 {
			floor = minSample
		}
		found := false
		for i := range groups {
			if groups[i].remedy != remedy || groups[i].floor != floor {
				continue
			}
			groups[i].rows++
			if r.Sample < groups[i].lo {
				groups[i].lo = r.Sample
			}
			if r.Sample > groups[i].hi {
				groups[i].hi = r.Sample
			}
			found = true
			break
		}
		if !found {
			groups = append(groups, group{remedy: remedy, floor: floor, rows: 1, lo: r.Sample, hi: r.Sample})
		}
	}
	if len(groups) == 0 {
		return nil
	}

	lines := make([]string, 0, 2*len(groups))
	for _, g := range groups {
		span := fmt.Sprintf("n=%d", g.lo)
		if g.hi != g.lo {
			span = fmt.Sprintf("n=%d–%d", g.lo, g.hi)
		}
		floor := ""
		if g.floor > 0 {
			floor = fmt.Sprintf(", min_sample %d", g.floor)
		}
		lines = append(lines,
			fmt.Sprintf("  NO PER-SITE RATE for %d of %d rows above — that em-dash is a REFUSAL, never a zero "+
				"(each row denominated on its OWN volume: %s%s).", g.rows, len(rows), span, floor))
		lines = append(lines, "  "+g.remedy)
	}
	return lines
}

// deployCensusSiteRemedy is the actionable half for a site refusal.
//
// A per-site refusal is a SAMPLE floor, not a vocabulary straddle — site_row/2
// builds the node with rate_basis(failed, volume) and nothing else — so the
// honest remedy is that the sample has to grow, and no window can be trimmed to
// produce one. That truth does NOT depend on the envelope naming a boundary,
// which is why it is not routed through deployCensusShareRemedy's third arm
// ("this control plane named no vocabulary boundary") — a sentence about
// vocabulary would answer a question nobody asked here.
//
// Where the control plane DOES name a boundary inside its own reason, the
// shared remedy still owns the render: that instant is read, never invented, and
// forking a second copy of the boundary logic is how the two drift.
func deployCensusSiteRemedy(reason string, boundaries []deployCensusBoundary, from, to time.Time, minSample int) string {
	if _, ok := deployCensusReasonBoundary(reason); ok {
		return deployCensusShareRemedy(reason, boundaries, from, to, minSample)
	}
	return "NO --from CAN UN-REFUSE THESE: a narrower window can only SHRINK each site's own sample. " +
		"A per-site rate needs MORE deploys per site — a wider --from, or more time. The headline above is " +
		"the rate this population CAN support; it is not a per-site claim."
}

// ─── A REFUSED SHARE SAYS WHICH WINDOW WOULD UN-REFUSE IT ────────────────────
//
// A share cell that refuses prints an em-dash (deployCensusShare) — honest, and
// a DEAD END: the operator learns that no percentage is available and nothing
// about how to obtain one. Measured on the live control plane: over the 7-day
// default window EVERY one of the fourteen failure-class shares refuses, while
// the same instrument over a window starting AT the deferred-settle boundary
// answers all fourteen (5,919 attempted, failure rate 17.7%). Same data, same
// classifier; only the window moved, and no render said so.
//
// NO INSTANT IS WRITTEN DOWN HERE, deliberately. The boundary is a fact about
// the DATA, not about this code: it moved once already (a second schema-commit
// boundary now rides the same list), and a constant baked into a renderer is
// stale the moment the ledger's vocabulary changes again.
//
// So each SECTION of shares that refused prints, once, beneath its rows: the
// control plane's own refusal reason, and — where the envelope supports one —
// the window that could answer instead.
//
// EVERY FACT IN THAT SUGGESTION IS READ, NEVER INVENTED. The boundary instant
// comes out of the refusal reason the control plane wrote ("… boundary at
// <instant> …") or out of the envelope's own `boundaries` list; a boundary this
// reader could not read is rendered as "the control plane named no boundary",
// because a fabricated --from is worse than none — it sends an operator to a
// window that answers nothing and looks like the tool's promise.
//
// AND IT PROMISES NOTHING IT CANNOT KNOW. Trimming a window to start at the
// boundary removes the straddle; whether the SMALLER population it leaves still
// clears min_sample is a fact only the re-run can report, and this line says so
// rather than implying an answer.
//
// THE CREDENTIAL REFUSAL IS NOT REACHED FROM HERE. A 403 never produces a
// census body, so it renders through deployCensusMessage's own arm and keeps its
// own wording: no window suggestion is attached to a refusal no window can fix.

// deployCensusBoundary is ONE row of the census envelope's `boundaries` list —
// the typed cloudclient shape, aliased under the name every render helper in
// this file already carries. dr-w24: the raw side-channel decode that used to
// live here is retired; cloudclient.DeployCensus models `boundaries` now, so
// this render reads the SAME field every other consumer of the struct does.
type deployCensusBoundary = cloudclient.DeployCensusBoundary

// deployCensusBoundaries filters the envelope's boundary list. A row whose
// instant does not parse is DROPPED: a boundary this reader cannot place on the
// timeline cannot support a `--from`, and half a boundary is not evidence.
func deployCensusBoundaries(rows []cloudclient.DeployCensusBoundary) []deployCensusBoundary {
	kept := make([]deployCensusBoundary, 0, len(rows))
	for _, b := range rows {
		if _, ok := deployCensusInstant(b.Instant); ok {
			kept = append(kept, b)
		}
	}
	return kept
}

// deployCensusInstant parses an instant the control plane sent, in the one
// format it sends (RFC3339, UTC).
func deployCensusInstant(raw string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(raw))
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}

// deployCensusShareNotes renders the lines a section of refused shares owes its
// reader: one pair per DISTINCT refusal reason (the control plane's words, then
// the window that could answer). A section where nothing refused prints nothing
// — this is a note about refusals, not a caption.
//
// The sample the shares were denominated on travels on the reason line, so this
// block can never be read as a claim about some other population.
func deployCensusShareNotes(rows []cloudclient.DeployCensusClass, boundaries []deployCensusBoundary, from, to time.Time, minSample int) []string {
	type group struct {
		reason string
		sample int
		rows   int
	}
	var groups []group
	refused := 0
	for _, r := range rows {
		if !r.Share.Refused && r.Share.Pct != nil {
			continue
		}
		refused++
		reason := deployCensusRefusal(r.Share, minSample)
		// Grouped by (reason, SAMPLE), never by reason alone. The reason the
		// control plane writes for a straddle does not carry the denominator,
		// so two rows can share a reason and have been denominated over
		// different populations — and printing the first row's n beside a
		// count that includes the second would state a denominator no row was
		// actually taken over. Splitting the group is the honest render.
		found := false
		for i := range groups {
			if groups[i].reason == reason && groups[i].sample == r.Share.Sample {
				groups[i].rows++
				found = true
				break
			}
		}
		if !found {
			groups = append(groups, group{reason: reason, sample: r.Share.Sample, rows: 1})
		}
	}
	if refused == 0 {
		return nil
	}

	lines := make([]string, 0, 2*len(groups))
	for _, g := range groups {
		lines = append(lines,
			fmt.Sprintf("  NO SHARE for %d of %d rows above (share denominator n=%d) — %s",
				g.rows, len(rows), g.sample, g.reason))
		lines = append(lines, "  "+deployCensusShareRemedy(g.reason, boundaries, from, to, minSample))
	}
	return lines
}

// deployCensusShareRemedy is the actionable half: the window that could answer
// where the envelope supports naming one, and an explicit refusal to guess
// where it does not.
//
// TWO REFUSALS, TWO DIFFERENT REMEDIES, and confusing them would send the
// operator in a circle:
//
//   - the window STRADDLES a vocabulary boundary — the control plane names the
//     instant inside its own reason, and a window that STARTS at that instant
//     is the narrowest trim that keeps one vocabulary. That is a real `--from`;
//   - the sample is below min_sample — a NARROWER window can only shrink the
//     sample further, so no `--from` un-refuses this one and this line says so
//     rather than offering a trim that would make it worse.
func deployCensusShareRemedy(reason string, boundaries []deployCensusBoundary, from, to time.Time, minSample int) string {
	if inst, ok := deployCensusReasonBoundary(reason); ok {
		caveat := ""
		if minSample > 0 {
			caveat = fmt.Sprintf(" Whether the smaller population that leaves still clears min_sample %d only the re-run can report — this line does not predict it.", minSample)
		}
		return fmt.Sprintf("A WINDOW THAT COULD ANSWER: `bp cloud deployments --from %s --to %s`%s — starting AT the boundary is the narrowest trim that keeps the window inside one vocabulary.%s",
			inst.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339),
			deployCensusBoundaryProvenance(boundaries, inst), caveat)
	}
	if b, rel, ok := deployCensusNearestBoundary(boundaries, from, to); ok {
		inst, _ := deployCensusInstant(b.Instant)
		return fmt.Sprintf("NO --from CAN UN-REFUSE THIS: a narrower window can only SHRINK the sample, and this window already sits %s the %s boundary at %s (method: %s, source: %s). The sample has to GROW — a wider --from, or more time.",
			rel, sanitizeCell(b.Subject), inst.UTC().Format(time.RFC3339), sanitizeCell(b.Method), sanitizeCell(b.Source))
	}
	return "NO WINDOW SUGGESTION: this control plane named no vocabulary boundary in its envelope, so nothing here can say which --from would answer. Nothing was invented in its place."
}

// deployCensusReasonBoundary extracts the instant the control plane NAMED in
// its own refusal reason ("… boundary at <RFC3339 instant> (method: …)").
// It returns false unless that instant parses: a suggestion is only ever built
// on an instant this reader actually read.
func deployCensusReasonBoundary(reason string) (time.Time, bool) {
	const marker = "boundary at "
	i := strings.Index(reason, marker)
	if i < 0 {
		return time.Time{}, false
	}
	rest := reason[i+len(marker):]
	fields := strings.FieldsFunc(rest, func(r rune) bool {
		return r == ' ' || r == '(' || r == ',' || r == '\n'
	})
	if len(fields) == 0 {
		return time.Time{}, false
	}
	return deployCensusInstant(strings.TrimRight(fields[0], ".,;"))
}

// deployCensusBoundaryProvenance names the derivation behind a suggested
// `--from` when the envelope's boundary list carries that instant, and says
// plainly when it does not — a suggestion whose provenance is unstated is still
// usable, but it must not LOOK corroborated.
func deployCensusBoundaryProvenance(boundaries []deployCensusBoundary, inst time.Time) string {
	for _, b := range boundaries {
		if t, ok := deployCensusInstant(b.Instant); ok && t.Equal(inst) {
			return fmt.Sprintf(" (the %s boundary — method: %s, source: %s)",
				sanitizeCell(b.Subject), sanitizeCell(b.Method), sanitizeCell(b.Source))
		}
	}
	return " (the control plane named this instant in its refusal; its `boundaries` list does not carry it)"
}

// deployCensusNearestBoundary picks the boundary a window sits NEXT TO, with
// the word for where it sits: the latest boundary at or before the window's
// start, else the earliest one after its end. A boundary strictly inside the
// window is reported as such — it should have produced a straddle refusal, and
// saying "inside" is better than silently calling it "after".
func deployCensusNearestBoundary(boundaries []deployCensusBoundary, from, to time.Time) (deployCensusBoundary, string, bool) {
	var before, inside, after *deployCensusBoundary
	var beforeAt, insideAt, afterAt time.Time
	for i := range boundaries {
		t, ok := deployCensusInstant(boundaries[i].Instant)
		if !ok {
			continue
		}
		switch {
		case t.After(from) && t.Before(to):
			if inside == nil || t.After(insideAt) {
				inside, insideAt = &boundaries[i], t
			}
		case !t.After(from):
			if before == nil || t.After(beforeAt) {
				before, beforeAt = &boundaries[i], t
			}
		default:
			if after == nil || t.Before(afterAt) {
				after, afterAt = &boundaries[i], t
			}
		}
	}
	switch {
	case inside != nil:
		return *inside, "ACROSS", true
	case before != nil:
		return *before, "wholly after", true
	case after != nil:
		return *after, "wholly before", true
	}
	return deployCensusBoundary{}, "", false
}

// deployCensusWindowPhrase renders the window as the two RFC3339 UTC instants
// the route was actually asked for, plus its width — the population, stated.
func deployCensusWindowPhrase(from, to time.Time) string {
	width := to.Sub(from)
	return fmt.Sprintf("%s → %s (%s)",
		from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339), deployCensusWidth(width))
}

// deployCensusWidth renders a window width in the largest honest unit.
func deployCensusWidth(d time.Duration) string {
	switch {
	case d >= 48*time.Hour:
		return fmt.Sprintf("%.0f days", d.Hours()/24)
	case d >= 2*time.Hour:
		return fmt.Sprintf("%.0f hours", d.Hours())
	default:
		return fmt.Sprintf("%.0f minutes", d.Minutes())
	}
}

// renderDeployDelivery prints the DELIVERY census: how long content waited to
// reach the web, every percentile beside the window width and the sample that
// produced it, and the still-waiting cohort named.
//
// THE THREE WAYS THIS SECTION REFUSES, and none of them is a zero:
//
//   - the control plane sends no `delivery` node at all (today's payload) — the
//     section says NOT MEASURED rather than printing nothing, because a missing
//     latency line reads as an absent problem;
//   - a percentile REFUSED (below min_sample, or more of the sample is still
//     waiting than the quantile has headroom for, or the row at the quantile is
//     itself still waiting) — it prints NO NUMBER and the control plane's own
//     reason, never a percentile;
//   - rows the clock could not reach at all — printed as their own UNMETERED
//     count, so the denominator can be audited.
//
// The still-waiting cohort NEVER prints as a bare count. It prints
// "STILL WAITING >= <bound>" beside the instant it was taken, because the same
// pinned window answered 3 → 2 → 0 in five minutes: a bare number there is
// reporting the measurement's own latency as a fact about the fleet.
func renderDeployDelivery(out *writer, d *cloudclient.DeployDelivery, siteLimit int) {
	if d == nil {
		out.outf("delivery — how long content waited to reach the web")
		out.outf("  NOT MEASURED — this control plane sends no delivery census. Nothing was read: this is NOT a population that delivers instantly.")
		out.outf("")
		return
	}

	scope := strings.TrimSpace(d.Environment)
	if scope == "" {
		scope = "unscoped"
	}
	out.outf("delivery — how long content waited to reach the web (%s · %s only)",
		deployCensusWidth(time.Duration(d.Window.WidthSeconds)*time.Second), sanitizeCell(scope))
	if clock := strings.TrimSpace(d.Clock); clock != "" {
		out.outf("  clock: %s", sanitizeCell(clock))
	}
	for _, q := range []cloudclient.DeployDeliveryQuantile{d.P50, d.P95, d.Max} {
		label := strings.TrimSpace(q.Label)
		if label == "" {
			label = fmt.Sprintf("q%.2f", q.Quantile)
		}
		out.outf("  %-4s %s", sanitizeCell(label), deployDeliveryValue(q))
	}
	out.outf("  %s", deployDeliveryWaiting(d.Censored))
	if d.Unmetered > 0 {
		out.outf("  %d row(s) the clock could not reach (live, with no became_live_at) — counted here, never dropped from the denominator", d.Unmetered)
	}

	waiting := make([]cloudclient.DeployDeliverySite, 0, len(d.Sites))
	for _, s := range d.Sites {
		if s.StillWaiting {
			waiting = append(waiting, s)
		}
	}
	if len(waiting) > 0 {
		shown := waiting
		if siteLimit > 0 && len(shown) > siteLimit {
			shown = shown[:siteLimit]
		}
		out.outf("  sites still waiting (who is waiting, and since when)")
		for _, s := range shown {
			out.outf("    %-38s %s  · %d measured · %d still waiting · %d delivered",
				sanitizeCell(s.SiteID), deployDeliverySiteWaiting(s), s.Sample, s.Censored, s.Delivered)
		}
		if n := len(waiting) - len(shown); n > 0 {
			out.outf("    … and %d more site(s) still waiting (raise the display clamp with --sites 0)", n)
		}
	}
	out.outf("")
}

// deployDeliveryValue renders ONE percentile INSEPARABLY: the value (or the
// refusal) always followed by the sample, the still-waiting share and the window
// width that produced it. There is no branch of this function that prints a bare
// number.
func deployDeliveryValue(q cloudclient.DeployDeliveryQuantile) string {
	population := fmt.Sprintf("(n=%d · %d still waiting · window %s)",
		q.Sample, q.Censored, deployCensusWidth(time.Duration(q.WindowSeconds)*time.Second))

	if q.Refused || q.Seconds == nil {
		reason := strings.TrimSpace(q.Reason)
		if reason == "" {
			reason = fmt.Sprintf("the control plane sent no value for a sample of %d", q.Sample)
		}
		return "NO NUMBER — " + sanitizeCell(reason) + " " + population
	}
	return deployDeliveryDuration(*q.Seconds) + " " + population
}

// deployDeliveryWaiting renders the fleet still-waiting cohort. A zero count is
// stated as a reading taken at an instant, never as the standing fact "nobody is
// waiting" — and a non-zero one is always a LOWER BOUND with its as-of.
func deployDeliveryWaiting(c cloudclient.DeployDeliveryCensored) string {
	asOf := deployDeliveryAsOf(c.AsOf)
	if c.Count == 0 {
		return "nothing was still waiting " + asOf + " — a reading taken at that instant, not a standing fact"
	}
	bound := "an unstated bound"
	if c.StillWaitingAtLeastSeconds != nil {
		bound = deployDeliveryDuration(*c.StillWaitingAtLeastSeconds)
	}
	return fmt.Sprintf("STILL WAITING >= %s · %d row(s) not delivered %s", bound, c.Count, asOf)
}

// deployDeliverySiteWaiting is one site's still-waiting line — the same
// "STILL WAITING >= X (as of …)" shape as the fleet cohort, so a site row can
// never be read as a bare zero either.
func deployDeliverySiteWaiting(s cloudclient.DeployDeliverySite) string {
	bound := "an unstated bound"
	if s.OldestWaitingSeconds != nil {
		bound = deployDeliveryDuration(*s.OldestWaitingSeconds)
	}
	return "STILL WAITING >= " + bound + " " + deployDeliveryAsOf(s.AsOf)
}

// deployDeliveryAsOf renders the instant a still-waiting reading was taken,
// normalised to RFC3339 UTC where it parses and passed through verbatim where it
// does not — an unparseable stamp is still evidence and is never dropped.
func deployDeliveryAsOf(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "(as of an instant the control plane did not name)"
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return "(as of " + t.UTC().Format(time.RFC3339) + ")"
	}
	return "(as of " + sanitizeCell(s) + ")"
}

// deployDeliveryDuration renders a wait in the largest honest unit, at
// second resolution — 22638s reads as 6h17m18s, which is the sentence this
// epic needed and could not say.
func deployDeliveryDuration(seconds float64) string {
	if seconds < 0 {
		seconds = 0
	}
	d := (time.Duration(seconds * float64(time.Second))).Round(time.Second)
	if d < time.Second {
		return fmt.Sprintf("%.1fs", seconds)
	}
	return d.String()
}

// renderDeployDeferralWait prints the DEFERRAL WAIT census: the clock behind the
// sentence "a deferral is re-queued, not lost". Until this section existed the
// `deferrals` block above was a COUNT WITH NO CLOCK — a fleet that improved its
// failure rate by relabelling every 409 `deferred` read as a fleet getting
// better even when the rebuild landed six hours later.
//
// It refuses the same three ways renderDeployDelivery does, and none of them is
// a zero:
//
//   - no `deferral_wait` node at all (every control plane older than #11207) —
//     the section says NOT MEASURED, because a missing wait reads as no wait;
//   - a quantile REFUSED (below min_sample, or the unresolved mass exceeds the
//     1-q headroom it needs) — it prints NO NUMBER and the control plane's own
//     reason, VERBATIM, never a percentile;
//   - the unresolved mass itself, printed in max's place as a censored LOWER
//     BOUND — and when that mass is entirely UNREADABLE there is no bound to
//     state, so the UNREADABLE count prints with the control plane's own label
//     rather than as an empty cell.
//
// UnresolvedFraction and Headroom print BESIDE the reason on every line, never
// inside it. The server's `cond` tests `n < min_sample` FIRST, so a small window
// reports only "sample 23 below min_sample 200" while the very same node carries
// unresolved_fraction 0.2581 against p95's 0.05 headroom — 5.2x over, and
// invisible to a renderer that prints Reason alone.
func renderDeployDeferralWait(out *writer, w *cloudclient.DeployDeferralWait) {
	if w == nil {
		out.outf("deferral wait — how long a deferred deploy waited to be re-queued")
		out.outf("  NOT MEASURED — this control plane sends no deferral-wait census. Nothing was read: the deferrals above are a COUNT WITH NO CLOCK, and this is NOT a population that re-queues instantly.")
		out.outf("")
		return
	}

	out.outf("deferral wait — how long a deferred deploy waited to be re-queued")
	if clock := strings.TrimSpace(w.Clock); clock != "" {
		out.outf("  clock: %s", sanitizeCell(clock))
	}
	if basis := strings.TrimSpace(w.Basis); basis != "" {
		out.outf("  basis: %s", sanitizeCell(basis))
	}
	for _, q := range []cloudclient.DeployDeferralWaitQuantile{w.P50, w.P95, w.Max} {
		label := strings.TrimSpace(q.Label)
		if label == "" {
			label = fmt.Sprintf("q%.2f", q.Quantile)
		}
		line := "  " + fmt.Sprintf("%-4s", sanitizeCell(label)) + " " + deployDeferralWaitValue(w, q)
		if q.Quantile >= 1.0 {
			line += " · " + deployDeferralWaitBound(w)
		}
		out.outf("%s", line)
	}
	if len(w.Outcomes) > 0 {
		out.outf("  outcomes (the control plane's own words — COVERED means the site has since rebuilt, never that your edit shipped)")
		for _, o := range w.Outcomes {
			out.outf("    %-12s %6d  %s", sanitizeCell(o.Outcome), o.Count, sanitizeCell(o.Label))
		}
	}
	out.outf("")
}

// deployDeferralWaitValue renders ONE deferral-wait quantile INSEPARABLY: the
// value (or the refusal, with the control plane's reason verbatim) always
// followed by the identifiability facts and by the population it was taken over.
// There is no branch of this function that prints a bare number, and none that
// prints an empty cell: a zero counter still prints its denominator and its
// as-of.
func deployDeferralWaitValue(w *cloudclient.DeployDeferralWait, q cloudclient.DeployDeferralWaitQuantile) string {
	p := w.Population
	population := fmt.Sprintf("(n=%d · covered %d / pending %d / unreadable %d of %d deferred · %s)",
		q.Sample, p.Covered, p.Pending, p.Unreadable, p.Deferred, deployDeferralWaitAsOf(w.AsOf))
	identifiability := fmt.Sprintf("unresolved %d = %.2f%% vs headroom %.2f%%",
		q.Unresolved, q.UnresolvedFraction*100, q.Headroom*100)

	if q.Refused || q.Seconds == nil {
		reason := strings.TrimSpace(q.Reason)
		if reason == "" {
			reason = fmt.Sprintf("the control plane sent no value for a sample of %d", q.Sample)
		}
		return "NO NUMBER — " + sanitizeCell(reason) + " · " + identifiability + " " + population
	}
	return deployDeliveryDuration(*q.Seconds) + " · " + identifiability + " " + population
}

// deployDeferralWaitBound renders, in max's place, what is known about the waits
// that are STILL RUNNING. A pending row is a wait whose end has not happened
// yet, so its elapsed time is a LOWER BOUND, never a measurement.
//
// THE HOLE THIS CLOSES: when the unresolved mass is entirely UNREADABLE —
// pending 0, unreadable > 0 — max refuses AND OldestPendingSeconds is nil, so a
// naive "if refused, print the bound" renderer emits an EMPTY CELL: a new silent
// mis-report inside the section built to end them. That branch prints the
// UNREADABLE count with the control plane's own label for it.
func deployDeferralWaitBound(w *cloudclient.DeployDeferralWait) string {
	p := w.Population
	asOf := deployDeliveryAsOf(w.AsOf)

	if w.OldestPendingSeconds != nil {
		return fmt.Sprintf("STILL WAITING >= %s · %d row(s) not covered %s",
			deployDeliveryDuration(*w.OldestPendingSeconds), p.Pending, asOf)
	}
	if p.Pending > 0 {
		return fmt.Sprintf("STILL WAITING >= an unstated bound · %d row(s) not covered %s", p.Pending, asOf)
	}
	if p.Unreadable > 0 {
		return fmt.Sprintf("NO BOUND — nothing is pending, yet %d row(s) are UNREADABLE (%s) %s",
			p.Unreadable, deployDeferralWaitOutcomeLabel(w, "unreadable"), asOf)
	}
	return fmt.Sprintf("nothing was unresolved %s — %d of %d deferred row(s) unreadable, a reading taken at that instant, not a standing fact",
		asOf, p.Unreadable, p.Deferred)
}

// renderDeployCoverageCohorts prints the COVERAGE PARTITION over both never-live
// cohorts: the same later-live clock the deferral wait uses, applied to the
// `deferred` rows AND to the rows that terminated `failed`.
//
// WHY IT IS A SECOND SECTION AND NOT A COLUMN ON THE FIRST: the deferral wait's
// population is `status == "deferred"` and nothing else, so a reader who took it
// as the coverage gauge was reading a number that structurally could not see the
// failed tail — a third of the never-live chains on the corpus that motivated
// this key. The two cohorts print side by side and are never summed: a failed
// row is not a deferral.
//
// It refuses the same way its neighbour does, and none of the refusals is a
// zero: no node at all prints NOT MEASURED (an absent key is not an empty
// backlog), a cohort with no rows prints "no rows" and never a percentage, and
// the counts that are neither covered nor never-covered — too young to judge,
// unreadable — print by name so a silence can never pass for health.
//
// COVERED is the control plane's word, rendered with the control plane's meaning
// attached: the SITE has since rebuilt. Not "your edit shipped".
func renderDeployCoverageCohorts(out *writer, c *cloudclient.DeployCoverageCohorts, pinnedWindow bool) {
	out.outf("coverage — did the site ever rebuild after a row that never went live")
	if c == nil {
		out.outf("  NOT MEASURED — this control plane sends no coverage census. Nothing was read: the rows that never reached live are UNCOUNTED here, and that is NOT the same as none.")
		out.outf("")
		return
	}

	if clock := strings.TrimSpace(c.Clock); clock != "" {
		out.outf("  clock: %s", sanitizeCell(clock))
	}
	if basis := strings.TrimSpace(c.Basis); basis != "" {
		out.outf("  basis: %s", sanitizeCell(basis))
	}
	// THE ONE INFERENCE THE SHARED VOCABULARY CANNOT STOP ON ITS OWN (review,
	// wave 32). "A deferral was covered" reads as "the re-queue worked", which is
	// true. "A FAILED row was covered" reads as "that failure turned out fine",
	// which is NOT what was measured: the clock only ever says the SITE rebuilt
	// afterwards. The basis line above states what COVERED means; this one states
	// what it does not, because the failed cohort is new here and the wrong
	// reading of it is the comforting one.
	out.outf("  and NOT: a COVERED row in the failed cohort means the site is not stuck — never that the failure was repaired or its content shipped")
	out.outf("  fence: a row is only counted NEVER COVERED once it is older than %s %s",
		deployDeliveryDuration(float64(c.MaturitySeconds)), deployDeliveryAsOf(c.AsOf))
	out.outf("%s", deployCoverageBoundLine(c.CoveringBound))
	out.outf("%s", deployCoverageWindowLine(pinnedWindow))

	if len(c.Cohorts) == 0 {
		out.outf("  NOT MEASURED — the control plane named no cohorts at all, which is not the same as no uncovered rows.")
		out.outf("")
		return
	}

	for _, cohort := range c.Cohorts {
		out.outf("  %-10s %s", sanitizeCell(cohort.Cohort), deployCoverageCohortLine(cohort))
		for _, env := range cohort.NeverCoveredByEnvironment {
			out.outf("             never covered in %s: %d", sanitizeCell(env.Environment), env.NeverCovered)
		}
	}
	renderDeployCoverageSites(out, c)
	out.outf("")
}

// deployCoverageBoundLine states the covering query's bound. The control plane
// sends it as one token; an absent token is NOT a claim that both edges were
// bounded, so it says which it is.
func deployCoverageBoundLine(bound string) string {
	switch strings.TrimSpace(bound) {
	case "left_only":
		return "  covering bound: LEFT ONLY — a live build minted AFTER this window's end still counts as coverage, so this reading answers \"is the site stuck NOW\" and is never a retrospective of the window."
	case "":
		return "  covering bound: NOT STATED — this control plane does not say whether the covering query was bounded on the right. Which of the two questions the counts below answer is UNKNOWN, and that is not the same as both edges being pinned."
	default:
		return "  covering bound: " + sanitizeCell(bound) + " — a bound this reader does not know; read it as stated, not as \"left only\"."
	}
}

// deployCoverageWindowLine discloses what the WINDOW does to these counts. It
// is not a refusal — the numbers are real — it is the sentence that stops the
// same fleet's 0 at --days 7 and 5 at --days 27 from reading as a change.
func deployCoverageWindowLine(pinned bool) string {
	if pinned {
		return "  window: BOTH edges pinned by --from/--to, so this population does not move when you run it again."
	}
	return "  window: LEFT-TRUNCATED — a --days window (7 by default) has its right edge at NOW and its left edge sliding with the clock, so rows older than the width are not in this population AT ALL. A wider --days finds more never-covered rows without one row of the population changing; only --from/--to pins both edges."
}

// renderDeployCoverageSites NAMES the never-covered tail. A count that cannot
// say which site is dark sends an operator looking through the whole fleet, and
// that anonymity is the defect this whole section exists to end.
//
// Three states, kept apart: no key at all (an older control plane MEASURED
// nothing), an empty list with a zero total (nothing is dark — a real answer),
// and a list that was CUT, which prints its own unbounded total so a top-20 can
// never be read as the whole tail.
func renderDeployCoverageSites(out *writer, c *cloudclient.DeployCoverageCohorts) {
	if c.NeverCoveredSites == nil && c.NeverCoveredSitesTotal == 0 && !c.NeverCoveredSitesTruncated {
		out.outf("  sites: NOT NAMED — this control plane sends no per-site breakdown. The counts above are real; WHICH sites they belong to was not read, and that is not the same as none.")
		return
	}
	if len(c.NeverCoveredSites) == 0 {
		out.outf("  sites: none — no {site, environment} pair is never-covered in this window.")
		return
	}

	// The header counts {site, environment} PAIRS, not distinct sites, because
	// that is what the total beside it counts — one site dark in both production
	// and preview is TWO rows here and TWO in the total. Saying "sites" would
	// make "7" mean one thing in the header and another in the cut marker below,
	// which is the exact ambiguity this section exists to end.
	out.outf("  never-covered {site, environment} pairs (%d of %d)", len(c.NeverCoveredSites), c.NeverCoveredSitesTotal)
	for _, s := range c.NeverCoveredSites {
		out.outf("    %-28s %-12s %d row(s) never covered", deployCoverageSiteName(s), sanitizeCell(s.Environment), s.NeverCovered)
	}
	if c.NeverCoveredSitesTruncated {
		out.outf("    … the list is CUT: %d {site, environment} pair(s) are never-covered and %d are printed. The counts above are over ALL of them.",
			c.NeverCoveredSitesTotal, len(c.NeverCoveredSites))
	}
}

// deployCoverageSiteName is the site's most useful identifier that actually
// arrived. A deleted site row resolves to no name and no slug, and the id is
// then the only true thing there is to print — never a blank cell, which reads
// as a site with no name rather than as a site that is gone.
func deployCoverageSiteName(s cloudclient.DeployCoverageSite) string {
	if slug := strings.TrimSpace(s.Slug); slug != "" {
		return sanitizeCell(slug)
	}
	if name := strings.TrimSpace(s.Name); name != "" {
		return sanitizeCell(name)
	}
	if id := strings.TrimSpace(s.SiteID); id != "" {
		return sanitizeCell(id) + " (no site row)"
	}
	return "(unidentified)"
}

// deployCoverageCohortLine renders ONE cohort INSEPARABLY: the covered count
// never travels without the population it came from, nor without the rows that
// are neither covered nor overdue.
func deployCoverageCohortLine(c cloudclient.DeployCoverageCohort) string {
	if c.Population == 0 {
		return "no rows in this window — nothing to cover, which is not the same as full coverage"
	}

	line := fmt.Sprintf("%d of %d covered (the site has since rebuilt) · %d NEVER COVERED · %d too young to judge · %d unreadable",
		c.Covered, c.Population, c.NeverCovered, c.TooYoung, c.Unreadable)
	if c.OldestPendingSeconds != nil {
		line += fmt.Sprintf(" · oldest still uncovered >= %s", deployDeliveryDuration(*c.OldestPendingSeconds))
	}
	return line
}

// deployDeferralWaitAsOf is deployDeliveryAsOf's wording without the enclosing
// parentheses, for the cells that already sit inside a parenthetical. An instant
// the control plane did not name is still stated, never blanked.
func deployDeferralWaitAsOf(raw string) string {
	return strings.TrimSuffix(strings.TrimPrefix(deployDeliveryAsOf(raw), "("), ")")
}

// deployDeferralWaitOutcomeLabel returns the control plane's own wording for one
// outcome, VERBATIM. A reader that invents a gloss here is the mis-report:
// COVERED means "the site has since rebuilt", never "your edit shipped".
func deployDeferralWaitOutcomeLabel(w *cloudclient.DeployDeferralWait, outcome string) string {
	for _, o := range w.Outcomes {
		if strings.EqualFold(strings.TrimSpace(o.Outcome), outcome) {
			if label := strings.TrimSpace(o.Label); label != "" {
				return sanitizeCell(label)
			}
		}
	}
	return "the control plane named no label for " + sanitizeCell(outcome)
}

// printCloudDeploymentsHelp writes `bp cloud deployments` usage.
func printCloudDeploymentsHelp(out *writer) {
	const help = `bp cloud deployments — the FLEET deploy rate, with the denominator it was taken over.

USAGE
  bp cloud deployments [--days N | --from <date> --to <date>] [--sites N]

WHAT IT PRINTS
  One line carrying BOTH rates, the volume and the denominator together — the
  live-per-attempt rate first, the failure rate as its labelled sibling:

    live 26.7% of 2216 attempted · failure 37.5% of 2216 attempted (832 failed · 793 deferred · 591 live) · 58.5% of 1423 terminal

  then the basis line, which names the denominator: it is deployment ROWS, not
  attempts — an attempt that coalesces onto an in-flight build mints no row, so
  the live rate is a CEILING.

  Then the failure classes, the deferrals (counted in the volume, never in the
  failure numerator), the DEFERRAL WAIT census (how long a deferred deploy
  waited to be re-queued — the clock the deferral COUNT never had, each
  percentile beside covered / pending / unreadable out of the deferred total),
  the DELIVERY census (how long content waited to reach the web, each percentile
  beside the sample and window width that produced it) and the sites,
  worst-volume first.

  The parenthetical names every state an attempt ended in, so success is never
  the unnamed remainder: it also carries "N in flight", "N cancelled" and
  "N residual" when the control plane sends them.

  A percentile that cannot be identified prints NO NUMBER and the reason — on a
  fleet where 40% of rows are still waiting, no p95 exists to report. The
  still-waiting cohort prints as "STILL WAITING >= <bound> (as of <instant>)",
  never as a bare count. On the deferral wait, the unresolved fraction and the
  headroom print BESIDE the reason, so a min_sample refusal cannot mask an
  identifiability problem — and when the unresolved mass is entirely UNREADABLE
  there is no bound to state, so the UNREADABLE count prints in its place.

FLAGS
  --days N            window width ending now (default 7)
  --from <date>       pin the window start (ISO date or instant); needs --to
  --to <date>         pin the window end; needs --from
  --sites N           how many site rows to print (default 10, 0 = all)
  -o json             the control plane's census envelope, verbatim

THE WINDOW IS ALWAYS PINNED AND ALWAYS PRINTED. The route has no default window
on purpose: daily deploy volume moved by a factor of eight in six days, so an
unpinned window compares two different populations and reports a volume collapse
as a repair.

THE POPULATION IS ALWAYS NAMED. Under the window every render prints a scope
line — "team <slug> · N sites registered to this team and in scope". A control
plane that sends no scope node prints "population NOT NAMED" instead: a rate
whose population is unstated says so, rather than looking fleet-wide.

IT REFUSES OUT LOUD. A census this command could not read NEVER renders as a
fleet with zero failures — a 401, a 403 (your token lacks ability "read"), a 422
no_team (this credential belongs to no team), a 422 invalid_window (bad window)
and the control plane's own below-min_sample refusal each print as a named
refusal instead of a number.

A REFUSED SHARE SAYS WHICH WINDOW WOULD ANSWER. Where the class or deferral
shares refuse, the section prints the control plane's own reason with the
denominator it was taken over, and — when the envelope names a vocabulary
boundary — the --from that would keep the window inside ONE vocabulary. Where
the envelope names no boundary, it says exactly that rather than inventing a
window: a suggested window that answers nothing is worse than none.

NEEDS 'bp login' and a credential carrying ability "read" on a team. It reads
GET /v1/deploy-ledger/census — the team-scoped census — so no operator grant is
involved and PLATFORM_ADMIN_EMAILS has no bearing on whether you can look.`
	out.outf("%s", help)
}
