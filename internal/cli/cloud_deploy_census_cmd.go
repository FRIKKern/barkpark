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
	renderDeployCensus(out, from, to, census, sites)
	return exitOK
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
func renderDeployCensus(out *writer, from, to time.Time, census cloudclient.DeployCensus, siteLimit int) {
	out.outf("deploy census · %s", deployCensusWindowPhrase(from, to))
	out.outf("  the window is pinned by this command, not defaulted by the server — every number below is about THIS population.")
	out.outf("%s", deployCensusScopeLine(census.Scope))
	out.outf("")
	out.outf("%s", deployCensusHeadline(census))
	out.outf("  basis: %s", deployCensusBasis(census.FailureRate.Basis))
	out.outf("")

	if len(census.Classes) > 0 {
		out.outf("failure classes (share of the %d failed)", census.Failed)
		for _, c := range census.Classes {
			out.outf("  %-28s %6d  %-7s %s", sanitizeCell(c.Class), c.Count, deployCensusShare(c.Share), sanitizeCell(c.Label))
		}
		out.outf("")
	}
	if len(census.Deferred) > 0 {
		out.outf("deferrals (in the volume, never in the failure numerator)")
		for _, c := range census.Deferred {
			out.outf("  %-28s %6d  %-7s %s", sanitizeCell(c.Class), c.Count, deployCensusShare(c.Share), sanitizeCell(c.Label))
		}
		out.outf("")
	}
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
			out.outf("  %-38s %6d attempted  %6d failed  %6d deferred  %-7s %s",
				sanitizeCell(s.SiteID), s.Volume, s.Failed, s.Deferred, deployCensusShare(s.FailureRate), top)
		}
		if n := len(census.Sites) - len(rows); n > 0 {
			out.outf("  … and %d more (raise the display clamp with --sites 0)", n)
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
		return "live per attempt: NOT SENT — this control plane does not compute it (nothing here says whether the fleet ships)"
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
// and corrects the one word the control plane's own basis gets wrong.
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
// It prints on EVERY render, including the payload that sends no basis at all,
// and it carries no percentage — the basis line must be safe to print beside a
// rate that refused one.
func deployCensusBasis(sent string) string {
	const correction = "denominator = deployment ROWS, not attempts. An attempt that coalesces onto an in-flight build completes without minting a row, so it is never counted here " +
		"(measured 2026-08-06: 3,766 auto-deploy worker jobs against 2,182 rows — 1,584 attempts excluded). Every excluded attempt is non-live, so the live rate above is a CEILING."
	if b := strings.TrimSpace(sent); b != "" {
		return sanitizeCell(b) + " — " + correction
	}
	return correction
}

// deployCensusDeferredTotal sums the deferral class counts — the third cohort,
// inside the volume and outside the failure numerator, which is why a reader
// that prints only failed/attempted makes a relocated 409 mass look deleted.
func deployCensusDeferredTotal(census cloudclient.DeployCensus) int {
	total := 0
	for _, c := range census.Deferred {
		total += c.Count
	}
	return total
}

// deployCensusPct renders a rate node as a percentage, or reports that it has
// none. A REFUSED node, and a node whose pct is absent, both answer false — the
// caller must then render a refusal, because there is no honest number here.
func deployCensusPct(r cloudclient.DeployRate) (string, bool) {
	if r.Refused || r.Pct == nil {
		return "", false
	}
	return pctOf(float64(r.Numerator), float64(r.Sample)), true
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

// deployCensusShare renders a class/site share cell, or an em-dash where the
// share was refused — never a 0.0% standing in for "we would not say".
func deployCensusShare(r cloudclient.DeployRate) string {
	if pct, okRate := deployCensusPct(r); okRate {
		return pct
	}
	return "—"
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
		out.outf("  NOT MEASURED — this control plane sends no delivery census. Nothing was read: this is NOT a fleet that delivers instantly.")
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
  failure numerator), the DELIVERY census (how long content waited to reach the
  web, each percentile beside the sample and window width that produced it) and
  the sites, worst-volume first.

  The parenthetical names every state an attempt ended in, so success is never
  the unnamed remainder: it also carries "N in flight", "N cancelled" and
  "N residual" when the control plane sends them.

  A percentile that cannot be identified prints NO NUMBER and the reason — on a
  fleet where 40% of rows are still waiting, no p95 exists to report. The
  still-waiting cohort prints as "STILL WAITING >= <bound> (as of <instant>)",
  never as a bare count.

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

NEEDS 'bp login' and a credential carrying ability "read" on a team. It reads
GET /v1/deploy-ledger/census — the team-scoped census — so no operator grant is
involved and PLATFORM_ADMIN_EMAILS has no bearing on whether you can look.`
	out.outf("%s", help)
}
