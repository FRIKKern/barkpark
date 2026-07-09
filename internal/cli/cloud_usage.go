package cli

// cloud_usage.go is `bp cloud usage` — the CLI twin of the console's Usage
// surfaces (epic charter C10/OC8/OC18, decision D36/D48). With NO argument it
// paints the FLEET summary (the terminal twin of the Overview meter strip: the
// team's instances count + one cached-sample row per instance, GET
// /v1/usage/summary — never a live fan-out); with an <instance> argument it
// renders the SAME per-instance usage envelope the dashboard's meter wall draws
// — GET /v1/barkparks/:id/usage,
// authenticated with the CLOUD session token — as an aligned, statusRole-painted
// meter table. The envelope is live TODAY (all-unmetered until C11 lights up the
// instance-sourced counts), so this ships and works now; the renderer is generic
// and quota-aware (OC2/OC7), so C11's real counts and a later plan-limit slice
// light up here with ZERO CLI change.
//
// Honest states, deliberately (D48/D51):
//   - a metered meter shows its real number + a green "live" state;
//   - an "unmetered" meter is NOT a fake zero — it renders a dim state with its
//     source label still named, so the operator sees which pipe went quiet;
//   - `measured_at` becomes an "as of <stamp>" freshness note (nil = a live read);
//   - a quota, when present, rides as an ANSI fraction (none in v1 — no fake
//     ceilings);
//   - `-o json` emits the usage envelope BYTES verbatim (D4 — the envelope IS
//     the contract), and a 404 maps to the no-existence-leak sentence.
//
// The meter-name vocabulary (names + order + labels) is the shared fixture
// cloud/priv/static/__fixtures__/usage_meters.json, asserted from this file's
// test — the SAME two-runtime tripwire the verify twin uses: if the SPA later
// asserts the same file, the two surfaces can never drift.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/mattn/go-runewidth"
)

// usageMeterOrder is the meter render order the committed fixture pins;
// usageMeterLabels carries each meter's human table label.
// TestUsageMeterVocabularyMatchesFixture holds BOTH to usage_meters.json, so a
// meter rename/reorder/relabel reds this runtime — the CLI can never drift from
// the envelope it renders.
var usageMeterOrder = []string{
	"documents", "datasets", "webhooks", "db_size", "disk", "seats",
	"api_requests", "bandwidth", "instances",
}

var usageMeterLabels = map[string]string{
	"documents":    "Documents",
	"datasets":     "Datasets",
	"webhooks":     "Webhooks",
	"db_size":      "DB size",
	"disk":         "Disk",
	"seats":        "Seats",
	"api_requests": "API requests",
	"bandwidth":    "Bandwidth",
	"instances":    "Instances",
}

// unmeteredValue is the honest "no truth here" sentinel the envelope carries in
// a meter's `value` (a string, never a number) — never a fake zero (D48).
const unmeteredValue = "unmetered"

// runCloudUsage is `bp cloud usage <instance>`: resolve the instance (name or
// id, the same forms the sibling cloud verbs accept), fetch its meters, and
// paint the meter table. Requires `bp login`.
func runCloudUsage(out *writer, g globals, args []string) int {
	// -h/--help anywhere in the tail prints help (the cloud-webhook/verify
	// convention; no positional can legitimately start with "-").
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudUsageHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudUsageHelp(out)
		return exitOK
	}

	const usage = "bp cloud usage [instance]"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 1 {
		return useError(out, "usage", fmt.Sprintf("want 0 or 1 arguments (usage: %s)", usage), exitUsage)
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to read usage", exitAuth)
	}

	// No positional → the FLEET summary (the D36 terminal twin of the Overview
	// meter strip): cached samples across every instance, never a live fan-out.
	if len(a.pos) == 0 {
		return runCloudFleetUsage(out, cfg)
	}

	// One positional → the per-instance meter wall (behaviour byte-unchanged).
	ref := a.pos[0]
	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	res, uerr := cfg.CloudClient().Usage(cloudCtx(), id)
	if uerr != nil {
		return usageFail(out, ref, uerr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitUsageRaw(out, res)
		return exitOK
	}
	renderUsageResult(out, ref, res)
	return exitOK
}

// fleetHeadlineMeters is the per-instance subset the fleet table paints (a full
// 9×N grid is unreadably wide): the two inventory counts most operators watch,
// the box's storage/health telemetry, and the team's seats. The STATE cell rolls
// the WORST usageStateToken across exactly these meters, so a headline meter over
// its quota reddens the whole row at a glance.
var fleetHeadlineMeters = []string{"documents", "db_size", "disk", "seats"}

// runCloudFleetUsage is `bp cloud usage` (no positional): the fleet summary — one
// row per instance from the sampler's CACHED snapshots (OC16), never a live
// fan-out. Requires `bp login`.
func runCloudFleetUsage(out *writer, cfg *Config) int {
	res, err := cfg.CloudClient().UsageSummary(cloudCtx())
	if err != nil {
		return cloudFail(out, "read fleet usage", err)
	}
	if out.output == "json" || out.output == "yaml" {
		emitUsageSummaryRaw(out, res)
		return exitOK
	}
	renderFleetUsage(out, res)
	return exitOK
}

// emitUsageSummaryRaw writes the fleet envelope for a machine consumer: json is
// the exact control-plane bytes (the emitUsageRaw idiom — the envelope IS the
// contract, D4); yaml is a faithful re-encode.
func emitUsageSummaryRaw(out *writer, res cloudclient.UsageSummaryResult) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(res.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// renderFleetUsage prints the fleet view: a header line naming the team's
// instances count (against its quota when a plan limit is present, painted
// through the shared statusRole seam), then the per-instance table. An empty
// fleet is an honest empty state, never a bare table skeleton.
func renderFleetUsage(out *writer, res cloudclient.UsageSummaryResult) {
	out.outf("%s", fleetInstancesHeader(out, res.TeamInstances, res.TeamPresent))
	out.outf("")
	if len(res.Instances) == 0 {
		out.outf("No instances yet — `bp cloud launch` to provision one.")
		return
	}
	renderFleetTable(out, res.Instances)
}

// fleetInstancesHeader renders the team-level instances line: "Instances X of Y"
// when the team carries a plan quota (painted via usageStateToken so an at/over
// limit fleet reads danger, exactly like the dashboard's headline meter), or a
// plain "Instances X" when the count is unlimited (quota nil — no fake ceiling).
// An absent/unmetered team meter dashes out honestly.
func fleetInstancesHeader(out *writer, m cloudclient.UsageMeter, present bool) string {
	if !present || !usageIsMetered(m) {
		return "Instances —"
	}
	n, _ := usageNumber(m.Value)
	if m.Quota == nil {
		return fmt.Sprintf("Instances %s", trimFloat(n))
	}
	line := fmt.Sprintf("Instances %s of %s", trimFloat(n), trimFloat(*m.Quota))
	return out.paintCell(line, usageStateToken(m, present))
}

// renderFleetTable paints the aligned per-instance table: INSTANCE (name, with
// slug/host/id fallbacks) · DOCS · DB · DISK · SEATS (the headline meter values,
// each formatted by its unit, an em dash when that meter is unmetered/absent) ·
// AS OF (the row's cached-sample age, or "no sample yet" when the sampler has
// never captured it — never a fake-fresh reading) · STATE (the WORST
// usageStateToken across the row's headline meters, painted through the shared
// statusRole seam). Widths are measured on BARE strings so painting the STATE
// cell never shifts a column; piped/--no-color output is byte-identical.
func renderFleetTable(out *writer, rows []cloudclient.UsageInstanceRow) {
	headers := []string{"INSTANCE", "DOCS", "DB", "DISK", "SEATS", "AS OF", "STATE"}
	cells := make([][]string, 0, len(rows))
	stateTokens := make([]string, 0, len(rows))
	for _, row := range rows {
		token := fleetRowState(row.Meters)
		cells = append(cells, []string{
			fleetInstanceName(row),
			fleetMeterCell("documents", row.Meters),
			fleetMeterCell("db_size", row.Meters),
			fleetMeterCell("disk", row.Meters),
			fleetMeterCell("seats", row.Meters),
			fleetAsOfCell(row.MeasuredAt),
			token,
		})
		stateTokens = append(stateTokens, token)
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
	const stateCol = 6 // the STATE column index — the one painted cell
	for r, row := range cells {
		parts := make([]string, len(row))
		for i, c := range row {
			padded := runewidth.FillRight(c, widths[i])
			if i == stateCol {
				padded = out.paintCell(padded, stateTokens[r])
			}
			parts[i] = padded
		}
		out.outf("%s", strings.TrimRight(strings.Join(parts, "  "), " "))
	}
}

// fleetInstanceName resolves an instance's display name, preferring the friendly
// name and falling back through slug → host → id so a partially-populated row is
// never blank. Scrubbed of control bytes like every server-authored cell.
func fleetInstanceName(row cloudclient.UsageInstanceRow) string {
	for _, cand := range []string{row.Name, row.Slug, row.Host, row.ID} {
		if strings.TrimSpace(cand) != "" {
			return sanitizeCell(cand)
		}
	}
	return "—"
}

// fleetMeterCell renders one headline meter's value for a fleet row, reusing the
// per-instance usageValueCell (unit formatting + the honest em dash on an
// unmetered/absent meter) so the two surfaces format identically.
func fleetMeterCell(name string, meters map[string]cloudclient.UsageMeter) string {
	m, present := meters[name]
	return usageValueCell(name, m, present)
}

// fleetRowState rolls the row's STATE: the WORST usageStateToken across the
// headline meters, by severity over_limit > near_limit > unmetered > live. An
// over/near-limit headline meter reddens/ambers the row; a row missing any
// metered reading (a quiet or never-sampled box) reads "unmetered" (dim) rather
// than a false "live" green — honesty over a fake-healthy glow (D48/D51).
func fleetRowState(meters map[string]cloudclient.UsageMeter) string {
	worst := "live"
	for _, name := range fleetHeadlineMeters {
		m, present := meters[name]
		token := usageStateToken(m, present)
		if usageStateSeverity(token) > usageStateSeverity(worst) {
			worst = token
		}
	}
	return worst
}

// usageStateSeverity ranks a usageStateToken for the fleet row roll-up: a tripped
// quota outranks everything, an unmetered (blind) meter outranks a plain live one
// so a partially-dark row never poses as fully healthy, and "live" is the floor.
func usageStateSeverity(token string) int {
	switch token {
	case "over_limit":
		return 3
	case "near_limit":
		return 2
	case "unmetered":
		return 1
	default: // "live"
		return 0
	}
}

// fleetAsOfCell renders a fleet row's freshness from its cached-sample time: a
// relative age ("3m ago", "2h ago") when a sample exists, or an honest
// "no sample yet" when the sampler has never captured this box (measured_at nil).
// A never-sampled row NEVER claims a fresh reading — the same no-fake-freshness
// honesty the per-instance usageAsOfCell carries.
func fleetAsOfCell(measuredAt *string) string {
	if measuredAt == nil || strings.TrimSpace(*measuredAt) == "" {
		return "no sample yet"
	}
	return relativeAge(*measuredAt)
}

// relativeAge parses an RFC3339 stamp and renders its age relative to now:
// "just now" under 5s, then "Ns/Nm/Nh/Nd ago" up the buckets. An unparseable
// stamp falls back to the sanitized literal (honest, never a crash); a
// future-skewed stamp reads "just now".
func relativeAge(stamp string) string {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(stamp))
	if err != nil {
		return sanitizeCell(stamp)
	}
	d := time.Since(t)
	switch {
	case d < 5*time.Second:
		return "just now"
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// usageFail maps a refused usage read onto the unified `bp:` error seam. The
// only contract refusal is the team-scoped 404 (no existence leak); anything
// else (an expired session, a gateway page) routes through cloudFail so auth
// handling stays identical to every other cloud verb.
func usageFail(out *writer, ref string, err error) int {
	var re *cloudclient.CloudRouteError
	if errors.As(err, &re) && re.Code == "not_found" {
		return useError(out, "not_found",
			fmt.Sprintf("no such instance %q (or it is not in your team)", ref),
			exitNotFound)
	}
	return cloudFail(out, "read usage", err)
}

// emitUsageRaw writes the envelope for a machine consumer: json is the exact
// control-plane bytes — verbatim, key order and all, so the CLI never becomes a
// second, drifting definition of the contract (the emitVerifyRaw idiom); yaml is
// a faithful re-encode (yaml consumers do not depend on key order).
func emitUsageRaw(out *writer, res cloudclient.UsageResult) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(res.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// renderUsageResult prints the human view: a one-line header naming the
// instance, the meter table (fixed fixture order), and a pending-invitations
// footnote when the seats meter carries one.
func renderUsageResult(out *writer, ref string, res cloudclient.UsageResult) {
	out.outf("Usage for %s", sanitizeCell(ref))
	out.outf("")
	renderUsageMeters(out, res.Meters)

	// The seats meter rides a cheap `pending_invitations` detail — surface it as
	// a footnote (never a second meter) so the operator sees pending seats without
	// leaving the usage view. `bp cloud members` is the full roster.
	if seats, ok := res.Meters["seats"]; ok && seats.PendingInvitations != nil && *seats.PendingInvitations > 0 {
		out.outf("")
		out.outf("%d pending invitation(s) — see `bp cloud members`", *seats.PendingInvitations)
	}
}

// renderUsageMeters prints the aligned meter table: METER (human label) · VALUE
// (the real number, or an em dash on an unmetered meter) · LIMIT (the quota
// fraction when present — none in v1) · STATE (painted through the shared
// statusRole seam: metered → "live"/green, unmetered → neutral/dim, the D12
// one-vocabulary guarantee) · AS OF (measured_at as "as of …", or "live" for a
// nil/current read) · SOURCE (always names where the number does/would come
// from). Widths are measured on BARE strings and painting wraps the padded cell,
// so piped/--no-color output is byte-identical to an uncolored build.
func renderUsageMeters(out *writer, meters map[string]cloudclient.UsageMeter) {
	headers := []string{"METER", "VALUE", "LIMIT", "STATE", "AS OF", "SOURCE"}
	cells := make([][]string, 0, len(usageMeterOrder))
	// stateTokens holds each row's bare STATE token so the join loop can paint it
	// through the shared seam without re-deriving it (it is also the STATE cell's
	// text, so the token is computed once per row).
	stateTokens := make([]string, 0, len(usageMeterOrder))
	for _, name := range usageMeterOrder {
		m, present := meters[name]
		token := usageStateToken(m, present)
		cells = append(cells, []string{
			usageMeterLabel(name),
			usageValueCell(name, m, present),
			usageLimitCell(m),
			token,
			usageAsOfCell(m, present),
			usageSourceCell(m, present),
		})
		stateTokens = append(stateTokens, token)
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
	const stateCol = 3 // the STATE column index — the one painted cell
	for r, row := range cells {
		parts := make([]string, len(row))
		for i, c := range row {
			padded := runewidth.FillRight(c, widths[i])
			if i == stateCol {
				// Paint STATE through the shared seam: the bare token drives the
				// role (statusRole), the padded string is coloured, so column
				// widths — measured on bare strings above — are untouched.
				padded = out.paintCell(padded, stateTokens[r])
			}
			parts[i] = padded
		}
		out.outf("%s", strings.TrimRight(strings.Join(parts, "  "), " "))
	}
}

// usageMeterLabel resolves a meter name to its human label. An unknown (future)
// meter passes through — honest, never dropped — but scrubbed of control bytes
// like every other server-authored cell.
func usageMeterLabel(name string) string {
	if l, ok := usageMeterLabels[name]; ok {
		return l
	}
	return sanitizeCell(name)
}

// usageStateToken maps a meter onto a statusRole token so the STATE cell colours
// identically to a dashboard dot, and the token IS the cell text (painted through
// the shared seam, never a direct-role bypass):
//
//   - a metered meter at/past its plan quota → "over_limit" (danger/red; the
//     comparison is INCLUSIVE — value >= quota — matching the create-time guard
//     that rejects value == quota, so a meter sitting exactly on the ceiling is
//     over, not merely near);
//   - a metered meter at/past its warn line but under the ceiling → "near_limit"
//     (warn/amber);
//   - any other metered meter → "live" (green — the pipe is reporting, no limit
//     tripped or no limit present, the v1 all-unmetered shape);
//   - an unmetered/absent meter → "unmetered" (neutral/dim — no truth here,
//     never a fake zero, so a quiet pipe can never read as over/near-limit).
//
// The quota states light up ONLY when the envelope carries the limit; an
// unlimited meter (quota/warn_at nil) stays "live", so no fake ceiling is
// implied. near_limit/over_limit are the deliberate cross-surface vocabulary
// extension in semrole.For (warn/danger).
func usageStateToken(m cloudclient.UsageMeter, present bool) string {
	if !present || !usageIsMetered(m) {
		return "unmetered"
	}
	n, _ := usageNumber(m.Value) // ok — usageIsMetered guaranteed a number
	if m.Quota != nil && n >= *m.Quota {
		return "over_limit"
	}
	if m.WarnAt != nil && n >= *m.WarnAt {
		return "near_limit"
	}
	return "live"
}

// usageValueCell renders a meter's value for the VALUE column: the formatted
// real number for a metered meter, an em dash for an unmetered one (the STATE +
// SOURCE columns carry the "unmetered — <source>" story, so the value stays a
// clean dash rather than a fake zero).
func usageValueCell(name string, m cloudclient.UsageMeter, present bool) string {
	if !present || !usageIsMetered(m) {
		return "—"
	}
	n, ok := usageNumber(m.Value)
	if !ok {
		return "—"
	}
	return formatMeterValue(name, n)
}

// usageLimitCell renders the quota as a "value / quota" fraction when a limit is
// present (OC7 — quota-aware NOW), or an em dash when unlimited. When a plan
// limit rides the envelope the fraction shows here; the near/over-limit TONE
// rides the STATE cell (usageStateToken), not this column, so an unlimited meter
// draws no coloured bar "to nowhere" — exactly the dishonesty the wish forbids.
func usageLimitCell(m cloudclient.UsageMeter) string {
	if m.Quota == nil {
		return "—"
	}
	n, ok := usageNumber(m.Value)
	if !ok {
		return "—"
	}
	return fmt.Sprintf("%s / %s", trimFloat(n), trimFloat(*m.Quota))
}

// usageAsOfCell renders a meter's freshness: "as of <stamp>" when the envelope
// carried a measured_at snapshot time, or "live" for a nil (current) read. An
// unmetered meter has no reading, so it has no freshness — it dashes out (a
// quiet pipe never claims a "live" read, matching its dashed VALUE cell).
func usageAsOfCell(m cloudclient.UsageMeter, present bool) string {
	if !present || !usageIsMetered(m) {
		return "—"
	}
	if m.MeasuredAt == nil || strings.TrimSpace(*m.MeasuredAt) == "" {
		return "live"
	}
	return "as of " + sanitizeCell(*m.MeasuredAt)
}

// usageSourceCell renders the meter's source label — always named, even on a
// degraded meter, so the operator sees which pipe went quiet. An absent meter
// (not in the envelope) has no source to name.
func usageSourceCell(m cloudclient.UsageMeter, present bool) string {
	if !present || strings.TrimSpace(m.Source) == "" {
		return "—"
	}
	return sanitizeCell(m.Source)
}

// usageIsMetered reports whether a meter carries a real number — i.e. its value
// is NOT the "unmetered" sentinel (and is numeric). A string value ("unmetered",
// or any future sentinel) is not metered.
func usageIsMetered(m cloudclient.UsageMeter) bool {
	_, ok := usageNumber(m.Value)
	return ok
}

// usageNumber extracts a float64 from a meter value, reporting ok=false for the
// "unmetered" sentinel (a string) or any non-numeric shape. JSON numbers decode
// to float64 through the `any` field.
func usageNumber(v any) (float64, bool) {
	switch t := v.(type) {
	case float64:
		return t, true
	case json.Number:
		f, err := t.Float64()
		return f, err == nil
	default:
		return 0, false
	}
}

// formatMeterValue formats a metered number by the meter's unit, inferred from
// its name: db_size is bytes (human units), disk is a percent, everything else
// is a plain count.
func formatMeterValue(name string, n float64) string {
	switch name {
	case "db_size":
		return humanBytes(n)
	case "disk":
		return trimFloat(n) + "%"
	default:
		return trimFloat(n)
	}
}

// humanBytes renders a byte count in binary units (the pg_size / disk idiom),
// one decimal above the base unit.
func humanBytes(n float64) string {
	const unit = 1024.0
	if n < unit {
		return fmt.Sprintf("%d B", int64(n))
	}
	units := []string{"KB", "MB", "GB", "TB", "PB", "EB"}
	val := n
	i := 0
	for val >= unit && i < len(units)-1 {
		val /= unit
		i++
	}
	return fmt.Sprintf("%.1f %s", val, units[i-1])
}

// trimFloat renders a float without a trailing ".0" — a whole number prints as
// an integer, a fractional one keeps its significant digits.
func trimFloat(n float64) string {
	if n == float64(int64(n)) {
		return strconv.FormatInt(int64(n), 10)
	}
	return strconv.FormatFloat(n, 'g', -1, 64)
}

// printCloudUsageHelp writes `bp cloud usage` usage.
func printCloudUsageHelp(out *writer) {
	const help = `bp cloud usage — fleet or per-instance usage meters, the console's Usage view in the terminal.

USAGE
  bp cloud usage            [-o json|yaml]   the fleet summary (all instances)
  bp cloud usage <instance> [-o json|yaml]   one instance's meter wall

THE FLEET SUMMARY (no argument)
  the D36 terminal twin of the console's Overview strip: a header line with your
  team's instances count (against its plan limit when one applies) and one row
  per instance from the sampler's CACHED snapshots — INSTANCE · DOCS · DB · DISK
  · SEATS · AS OF · STATE. AS OF is the sample's age ("3m ago") or an honest
  "no sample yet"; STATE rolls the worst meter across the row. This is a cached
  read — never a live fan-out — so it answers instantly even when a box is down.

ONE INSTANCE
  the same meter wall the dashboard draws — one row per meter:

    documents · datasets · webhooks    instance-sourced inventory counts
    db_size · disk                     the agent's health-beat telemetry
    seats · instances                  your team's members + provisioned boxes
    api_requests · bandwidth           flow meters (not yet metered)

  Every meter is a real number or an honest "unmetered" with its source named —
  never a fake zero. A meter with a snapshot time shows "as of …"; a live read
  shows "live". Quotas ride as a fraction when a plan limit is present, and the
  STATE cell warns "near_limit" / "over_limit" as a metered value nears or
  crosses that ceiling.

  <instance> is a fleet name or id (the forms bp cloud status shows); needs
  'bp login'. Instance-sourced counts are "unmetered" until the backend lands
  them — the row is honest about which pipe is quiet.

OUTPUT
  a painted meter table (green "live" / dim "unmetered").
  -o json    the usage envelope verbatim: {usage:{meters:{…}}}`
	out.outf("%s", help)
}
