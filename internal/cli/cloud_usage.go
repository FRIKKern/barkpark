package cli

// cloud_usage.go is `bp cloud usage <instance>` — the CLI twin of the console's
// Usage sub-tab (epic charter C10/OC8, decision D48). It renders the SAME usage
// envelope the dashboard's meter wall draws — GET /v1/barkparks/:id/usage,
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
	"api_requests", "bandwidth",
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

	const usage = "bp cloud usage <instance>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want 1 argument (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to read an instance's usage", exitAuth)
	}

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
	// paintRole holds the role for each row's STATE cell so the join loop can
	// paint through the shared seam without re-deriving it.
	stateTokens := make([]string, 0, len(usageMeterOrder))
	for _, name := range usageMeterOrder {
		m, present := meters[name]
		cells = append(cells, []string{
			usageMeterLabel(name),
			usageValueCell(name, m, present),
			usageLimitCell(m),
			usageStateToken(m, present),
			usageAsOfCell(m),
			usageSourceCell(m, present),
		})
		stateTokens = append(stateTokens, usageStateToken(m, present))
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
// identically to a dashboard dot: a metered meter is "live" (green — the pipe is
// reporting), an unmetered one is "unmetered" (neutral/dim — no truth here,
// never a fake zero). A meter absent from the envelope is honestly "unmetered"
// too. The tokens route through the shared statusRole seam ("live" → ok, an
// unrecognised "unmetered" → neutral), so no new vocabulary is added.
func usageStateToken(m cloudclient.UsageMeter, present bool) string {
	if present && usageIsMetered(m) {
		return "live"
	}
	return "unmetered"
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
// present (OC7 — quota-aware NOW), or an em dash when unlimited. v1 emits no
// quotas, so this is always a dash today; a later Elixir-only slice sources real
// plan limits and the fraction appears here with zero CLI change. Painting the
// over/near-limit tone is deferred with the data (drawing a coloured bar "to
// nowhere" for an unlimited meter is exactly the dishonesty the wish forbids).
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
// carried a measured_at snapshot time, or "live" for a nil (current) read.
func usageAsOfCell(m cloudclient.UsageMeter) string {
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
	const help = `bp cloud usage — an instance's usage meters, the console's Usage tab in the terminal.

USAGE
  bp cloud usage <instance> [-o json|yaml]

WHAT IT SHOWS
  the same meter wall the dashboard draws — one row per meter:

    documents · datasets · webhooks    instance-sourced inventory counts
    db_size · disk                     the agent's health-beat telemetry
    seats                              your team's members (+ pending invites)
    api_requests · bandwidth           flow meters (not yet metered)

  Every meter is a real number or an honest "unmetered" with its source named —
  never a fake zero. A meter with a snapshot time shows "as of …"; a live read
  shows "live". Quotas ride as a fraction when a plan limit is present.

  <instance> is a fleet name or id (the forms bp cloud status shows); needs
  'bp login'. Instance-sourced counts are "unmetered" until the backend lands
  them — the row is honest about which pipe is quiet.

OUTPUT
  a painted meter table (green "live" / dim "unmetered").
  -o json    the usage envelope verbatim: {usage:{meters:{…}}}`
	out.outf("%s", help)
}
