package cli

// cloud_instance_top_cmd.go is `bp cloud instance top <instance>` — a one-shot
// vitals snapshot for a managed box (azure-hetzner hosting charter, S12). It asks
// the control plane for the on-box agent's rolled beat window (GET
// /v1/barkparks/:id/metrics), authenticated with the CLOUD session token, and
// renders CPU / memory / disk / load + service health.
//
// Monitoring truth is the AGENT BEAT, not a provider metrics API — so the same
// envelope works identically on both clouds and on adopted/self-hosted boxes. The
// CLI is a pure CONSUMER (the domain-status/verify idiom): it never computes a
// window and never reshapes the contract —
//   - `-o json` emits the CP envelope BYTES verbatim (the envelope IS the
//     contract), so `bp cloud instance top prod -o json | jq` reads the same
//     shape the console renders;
//   - the terminal view ADAPTS that same envelope into pdrender stat-grid + chart
//     blocks via a small Attrs adapter (metricsBlocks) — no second definition of
//     the vitals shape lives here.
//
// Honest states, deliberately:
//   - beat.status "absent" (no beat ever) → an honest "no vitals yet" line, NEVER
//     a zeroed chart;
//   - "stale" (the beat went quiet) → the last-known window with a STALE banner;
//   - a null sample is a GAP — dropped from the terminal sparkline, never a
//     fabricated zero (the console renders the true gap).
//
// ONE-SHOT by design: no --watch, no ticker (the data cadence is the ~60s beat).
// A repeat read is a fresh invocation — matching every other `bp cloud` verb.

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"golang.org/x/term"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// metricTopUnit is how one vitals series formats its headline number.
type metricTopUnit int

const (
	unitPlain metricTopUnit = iota // a bare number (load average)
	unitPct                        // a whole-number percent
	unitBytes                      // a human byte size (the BEAM footprint)
)

// metricTopSpec is the render order + display shape for one vitals series.
//
// THIS LIST IS THE RENDER CONTRACT, and it is not self-enforcing:
// cloudclient.MetricsResult.Series is a DYNAMICALLY keyed map, so a series the
// control plane emits and this list omits is dropped with zero red — an
// invisible number behind a fully green build. It must move with
// BarkparkCloud.Metrics's @vitals; TestMetricTopSpecsCoverTheControlPlaneVitals
// is the tripwire.
//
// `chart` excludes the byte-scale series from the shared line chart: one axis
// carrying both a 0-100 percent and a 1.2e9 byte count flattens every percent
// line to the floor, so bytes keep their stat cell + inline sparkline (each
// normalised to its OWN swing) and stay out of the mixed plot.
type metricTopSpec struct {
	key   string
	label string
	unit  metricTopUnit
	chart bool
}

var metricTopSpecs = []metricTopSpec{
	{key: "cpu", label: "CPU", unit: unitPct, chart: true},
	{key: "mem", label: "Memory", unit: unitPct, chart: true},
	{key: "disk", label: "Disk", unit: unitPct, chart: true},
	{key: "load", label: "Load", unit: unitPlain, chart: true},
	// Swap is the vital Memory HIDES: MemAvailable clears the floor precisely
	// BECAUSE the BEAM was paged out, so a box at 99% swap reports a comfortable
	// 58% memory. Its headline is overridden by the three-state swap cell below
	// (the percent alone cannot say "none configured").
	{key: "swap", label: "Swap", unit: unitPct, chart: true},
	{key: "beam_pss", label: "BEAM", unit: unitBytes, chart: false},
	{key: "beam_swap", label: "BEAM swapped", unit: unitBytes, chart: false},
}

// runCloudInstanceTop is `bp cloud instance top <instance>`: resolve the instance
// (name or id, the forms bp cloud verify/domain accept), fetch the vitals
// roll-up, and render it. Requires `bp login`.
func runCloudInstanceTop(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudInstanceTopHelp(out)
			return exitOK
		}
	}
	if g.help {
		printCloudInstanceTopHelp(out)
		return exitOK
	}

	const usage = "bp cloud instance top <instance> [--points <n>]"
	a, err := parseHzArgs(args, []string{"points"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want 1 argument (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	points := 0
	if p := strings.TrimSpace(a.val("points")); p != "" {
		n, perr := strconv.Atoi(p)
		if perr != nil || n < 0 {
			return useError(out, "usage", fmt.Sprintf("--points must be a non-negative integer, got %q", p), exitUsage)
		}
		points = n
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to read metrics, or set BARKPARK_CLOUD_TOKEN for a CI job", exitAuth)
	}

	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	res, merr := cfg.CloudClient().Metrics(cloudCtx(), id, points)
	if merr != nil {
		return cloudFail(out, "instance top", merr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitMetricsRaw(out, res)
		return exitOK
	}
	renderInstanceTop(out, ref, res)
	return exitOK
}

// emitMetricsRaw writes the envelope for a machine consumer: json is the exact
// control-plane bytes — verbatim, key order and all, so the CLI never becomes a
// second, drifting definition of the vitals contract (the emitDomainStatusRaw
// idiom); yaml is a faithful re-encode.
func emitMetricsRaw(out *writer, res cloudclient.MetricsResult) {
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

// renderInstanceTop prints the human view: a header (which box, when collected),
// the honest beat line, then — unless the beat is absent — the pdrender stat-grid
// + chart adapted from the envelope, and a service-health rollup.
func renderInstanceTop(out *writer, ref string, res cloudclient.MetricsResult) {
	head := "Vitals for " + sanitizeCell(ref)
	if host := sanitizeCell(res.Instance.Host); host != "" && !strings.EqualFold(host, ref) {
		head += "  ·  " + host
	}
	if prov := sanitizeCell(res.Instance.Provider); prov != "" {
		head += "  ·  " + prov
	}
	out.outf("%s", head)
	out.outf("%s", metricsBeatLine(res.Beat))

	// Absent beat → nothing real to plot; say so, never a zeroed chart.
	if strings.EqualFold(strings.TrimSpace(res.Beat.Status), "absent") {
		out.outf("")
		out.outf("No vitals yet — the on-box agent hasn't reported a beat. Metrics appear here once the first beat lands.")
		return
	}

	blocks := metricsBlocks(res)
	if len(blocks) == 0 {
		out.outf("")
		out.outf("No numeric samples in the current window yet.")
	} else {
		out.outf("")
		out.outf("%s", renderMetricsBlocks(out, blocks))
	}

	// What is taking up space — the newest beat's database size and its named
	// biggest consumers. Absent on a box whose agent does not report them.
	if head, storage := storageLines(res.Latest); head != "" {
		out.outf("")
		out.outf("%s", head)
		if len(storage) > 0 {
			out.outf("%s", renderMetricsBlocks(out, storage))
		}
	}

	// What is on the DISK, from the box's own space report. Unlike the storage
	// section above this ALWAYS prints: not having a space report is the common
	// case today, and which absence it is decides what an operator should do
	// about it (upgrade the agent, or simply wait a cadence).
	if space, siteBars := spaceLines(res); len(space) > 0 {
		out.outf("")
		for _, line := range space {
			out.outf("%s", line)
		}
		if len(siteBars) > 0 {
			out.outf("%s", renderMetricsBlocks(out, siteBars))
		}
	}

	if line := metricsHealthLine(res.ServiceHealth); line != "" {
		out.outf("")
		out.outf("%s", line)
	}
}

// metricsBeatLine is the honest one-line beat state above the plot.
func metricsBeatLine(b cloudclient.MetricsBeat) string {
	switch strings.ToLower(strings.TrimSpace(b.Status)) {
	case "live":
		return "beat: live" + metricsAgeSuffix(b)
	case "stale":
		return "beat: STALE — showing the last known readings" + metricsAgeSuffix(b)
	case "absent":
		return "beat: none yet"
	default:
		return "beat: " + statusDash(b.Status)
	}
}

// metricsAgeSuffix renders " (last seen 3m ago)" from the server-computed age; a
// non-positive/absent age yields "" (the CLI never fabricates a time).
func metricsAgeSuffix(b cloudclient.MetricsBeat) string {
	if age := metricsAgeText(b.AgeSeconds); age != "" {
		return " (last seen " + age + " ago)"
	}
	return ""
}

// metricsAgeText is the Go twin of the SPA's metricsAgeText — an honest human age
// from the server's age_seconds (never recomputed here). Negative/zero/garbage →
// "".
func metricsAgeText(ageSeconds float64) string {
	if ageSeconds <= 0 || math.IsNaN(ageSeconds) || math.IsInf(ageSeconds, 0) {
		return ""
	}
	s := int(ageSeconds)
	if s < 60 {
		return fmt.Sprintf("%ds", s)
	}
	m := s / 60
	if m < 60 {
		return fmt.Sprintf("%dm", m)
	}
	h := m / 60
	if h < 24 {
		return fmt.Sprintf("%dh", h)
	}
	return fmt.Sprintf("%dd", h/24)
}

// metricsHealthLine rolls the service-check summary into one line. Absent counts
// (total <= 0) → "" (never "0/0").
func metricsHealthLine(h cloudclient.ServiceHealth) string {
	if h.Total <= 0 {
		return fmt.Sprintf("service health: %s", statusDash(""))
	}
	line := fmt.Sprintf("service health: %d/%d passing", h.Pass, h.Total)
	if len(h.Failing) > 0 {
		safe := make([]string, 0, len(h.Failing))
		for _, f := range h.Failing {
			safe = append(safe, sanitizeCell(f))
		}
		line += " — failing: " + strings.Join(safe, ", ")
	}
	return line
}

// metricsBlocks is the Attrs ADAPTER: it maps the metrics envelope onto pdrender
// blocks — a stat-grid of current vitals (each with an inline eighth-block
// sparkline) plus a chart plotting the series. NO gauge block (stat/chart is the
// vocabulary). A NULL sample is a gap: it is dropped from the terminal series
// (the pdrender chart connects points, it has no gap primitive) so a hole never
// stamps a fake zero; the console renders the true gap. A metric whose whole
// window is holes keeps its stat cell (an honest em-dash) but contributes no
// chart series.
func metricsBlocks(res cloudclient.MetricsResult) []pdrender.Block {
	items := make([]any, 0, len(metricTopSpecs))
	chartSeries := make([]any, 0, len(metricTopSpecs))
	anySample := false
	for _, spec := range metricTopSpecs {
		pts := res.Series[spec.key]
		vals := make([]any, 0, len(pts))
		var current *float64
		for _, p := range pts {
			if p.Value != nil {
				vals = append(vals, *p.Value)
				current = p.Value
			}
		}
		item := map[string]any{"label": spec.label}
		// The swap headline is a THIRD state the series alone cannot express (a
		// swapless box's 0% is not a reading, it is "there is no swap"), so it
		// overrides the numeric formatting when the latest beat can answer it.
		if headline := swapStatValue(spec.key, res.Latest.Swap); headline != "" {
			item["value"] = headline
		} else {
			switch {
			case current == nil:
				item["value"] = "—"
			case spec.unit == unitPct:
				item["value"] = fmt.Sprintf("%d%%", int(math.Round(*current)))
			case spec.unit == unitBytes:
				item["value"] = humanBytes(*current)
			default:
				item["value"] = strconv.FormatFloat(math.Round(*current*100)/100, 'f', -1, 64)
			}
		}
		// A swapless box has no swap to trend: its window of honest 0s would draw a
		// flat line implying a meter that exists. "none configured" is the whole
		// answer — never a percent, never a plot.
		if len(vals) > 0 && !swapNoneConfigured(spec.key, res.Latest.Swap) {
			item["spark"] = vals
			if spec.chart {
				chartSeries = append(chartSeries, map[string]any{"label": spec.label, "points": vals})
			}
			anySample = true
		}
		items = append(items, item)
	}
	if !anySample {
		return nil // no numeric samples anywhere → the caller prints an honest line
	}
	blocks := []pdrender.Block{
		{Type: "stat-grid", Attrs: map[string]any{"items": items}},
	}
	if len(chartSeries) > 0 {
		blocks = append(blocks, pdrender.Block{
			Type:  "chart",
			Attrs: map[string]any{"series": chartSeries, "kind": "line"},
		})
	}
	return blocks
}

// swapNoneConfigured reports whether the newest beat MEASURED swap and found
// none: the agent sends the percent and its total as a pair precisely so this
// case is distinguishable, and total == 0 is the swapless box. A nil total is
// NOT this state — that is "we could not measure", which falls through to the
// existing gap arms.
func swapNoneConfigured(key string, s cloudclient.MetricsSwap) bool {
	return key == "swap" && s.TotalBytes != nil && *s.TotalBytes == 0
}

// swapStatValue is the swap headline's THREE honest states, and it mints no new
// vocabulary — the disambiguation rides in the DATA the agent already sends:
//
//   - total == 0  → "none configured" (neutral: the box has no swap; the answer
//     is not a percent and must never be dressed as one — five of six boxes in
//     the fleet are swapless, so this is the majority case);
//   - total > 0   → "<pct>% of <total>" (the percent is only interpretable
//     against the size it is a percent OF);
//   - anything else (a nil total, a nil percent, the agent's -1 sentinel the
//     control plane already nils) → "" so the caller falls through to the
//     existing unmeasured arm (the honest em dash).
//
// It returns "" for every non-swap series, so the caller can ask unconditionally.
func swapStatValue(key string, s cloudclient.MetricsSwap) string {
	if key != "swap" {
		return ""
	}
	if swapNoneConfigured(key, s) {
		return "none configured"
	}
	if s.TotalBytes != nil && *s.TotalBytes > 0 && s.UsedPct != nil {
		return fmt.Sprintf("%d%% of %s", int(math.Round(*s.UsedPct)), humanBytes(*s.TotalBytes))
	}
	return ""
}

// storageLines answers "what is taking up space" for the drill-in view: the
// database total from the newest beat, then its biggest NAMED consumers as a
// bar-chart whose bars are shares of that total (a bar length IS the share, so
// the diagnosis reads without arithmetic). Three honest states, never merged:
//
//   - the beat carries no db size AND no relation list (a pre-upgrade agent, or
//     a failed probe) → nothing is printed rather than a zeroed section;
//   - the list is nil (unmeasured) → the size still prints, with an honest note
//     that the breakdown was not reported;
//   - the list is EMPTY (measured, nothing to report) → says so — a different
//     fact from "we did not look".
func storageLines(l cloudclient.MetricsLatest) (string, []pdrender.Block) {
	if l.DBSize == nil && l.TopRelations == nil {
		return "", nil
	}
	head := "database: —"
	if l.DBSize != nil {
		head = "database: " + humanBytes(*l.DBSize)
	}
	switch {
	case l.TopRelations == nil:
		return head + "  ·  top relations not reported by this beat", nil
	case len(l.TopRelations) == 0:
		return head + "  ·  no relations reported", nil
	}

	max := 0.0
	if l.DBSize != nil {
		max = *l.DBSize
	}
	bars := make([]any, 0, len(l.TopRelations))
	named := 0.0
	for _, rel := range l.TopRelations {
		named += rel.Bytes
		bars = append(bars, map[string]any{
			"label": sanitizeCell(rel.Name) + " " + humanBytes(rel.Bytes),
			"value": rel.Bytes,
		})
	}
	if l.DBSize != nil && *l.DBSize > 0 {
		head += fmt.Sprintf("  ·  top %d = %s of it", len(l.TopRelations), pctOf(named, *l.DBSize))
	}
	return head, []pdrender.Block{
		{Type: "bar-chart", Attrs: map[string]any{"bars": bars, "max": max}},
	}
}

// spaceLines answers "what is on this box's disk" for the drill-in view,
// following storageLines' three-honest-states discipline one level up: a fact
// that was not measured never renders as a fact that measured zero.
//
// THE ABSENT STATE IS THE COMMON ONE, so unlike storageLines it SPEAKS rather
// than printing nothing — and it says WHICH absence, because the two have
// different remedies and sending an operator to the wrong one is worse than
// saying nothing:
//
//   - no space report AND no readable core count → the agent binary predates
//     the space probe. Upgrading the agent is the fix; waiting will never help.
//     `cpu_cores` and the space probe entered the agent in ONE commit (see
//     cloudclient.MetricsLatest.Cores), so a box that cannot report its cores
//     cannot report its space either. This is the same inference, on the same
//     field, that cloud_status_cmd.go's `unmeteredMarker` already ships.
//   - no space report but a readable core count → the agent CAN report space
//     and simply has not yet. Waiting one cadence is the fix; upgrading is not.
//
// A note on why the beat status is not consulted here: the caller returns early
// on an absent beat, so a box reaching this function is one we have heard from.
func spaceLines(res cloudclient.MetricsResult) ([]string, []pdrender.Block) {
	if res.Space == nil {
		if res.Latest.Cores == nil {
			return []string{"host space: not reported — this agent predates the space probe (it cannot report a core count either; both landed in the same agent build, so upgrading the agent is what fixes this)"}, nil
		}
		return []string{"host space: no report yet — this agent CAN report it (its core count reads), and space rides its own 15-minute cadence separate from the beat"}, nil
	}

	sp := res.Space
	lines := []string{spaceRootLine(sp)}

	if sp.JournalBytes != nil {
		lines = append(lines, "  journal: "+humanBytes(*sp.JournalBytes))
	}
	if sp.DBSize != nil {
		lines = append(lines, "  database: "+humanBytes(*sp.DBSize))
	}

	lines = append(lines, spaceSitesLine(sp))
	lines = append(lines, spaceConsumerLines(sp)...)
	lines = append(lines, spaceResidualLine(sp))

	// The bar chart is the sites breakdown, and it is drawn ONLY when there is a
	// measured list with rows in it. nil and empty are both worded on the sites
	// line above instead, because a chart with no bars reads as "nothing is using
	// space" rather than "we did not look".
	if len(sp.Sites.Top) == 0 {
		return lines, nil
	}
	max := 0.0
	if sp.Sites.Bytes != nil {
		max = *sp.Sites.Bytes
	}
	bars := make([]any, 0, len(sp.Sites.Top))
	for _, site := range sp.Sites.Top {
		if site.Bytes > max {
			max = site.Bytes
		}
		bars = append(bars, map[string]any{
			"label": sanitizeCell(site.Name) + " " + humanBytes(site.Bytes),
			"value": site.Bytes,
		})
	}
	return lines, []pdrender.Block{
		{Type: "bar-chart", Attrs: map[string]any{"bars": bars, "max": max}},
	}
}

// spaceRootLine renders the root filesystem pair. A used figure without a total
// is reported as the bare number it is — a percentage needs both, and inventing
// the denominator is how a 30%-full box and a 97%-full box come to read alike.
func spaceRootLine(sp *cloudclient.MetricsSpace) string {
	head := "host space:"
	if sp.ReportedAt != nil && strings.TrimSpace(*sp.ReportedAt) != "" {
		head = "host space (reported " + sanitizeCell(strings.TrimSpace(*sp.ReportedAt)) + "):"
	}
	switch {
	case sp.Root.UsedBytes == nil && sp.Root.TotalBytes == nil:
		return head + " root filesystem not reported by this agent"
	case sp.Root.TotalBytes == nil:
		return head + " root " + humanBytes(*sp.Root.UsedBytes) + " used, capacity not reported (no share can be computed)"
	case sp.Root.UsedBytes == nil:
		return head + " root capacity " + humanBytes(*sp.Root.TotalBytes) + ", used not reported"
	}
	return head + " root " + humanBytes(*sp.Root.UsedBytes) + " of " + humanBytes(*sp.Root.TotalBytes) +
		" used (" + pctOf(*sp.Root.UsedBytes, *sp.Root.TotalBytes) + ")"
}

// spaceSitesLine words the deployed-sites directory. Count carries three states
// and all three are said out loud: a -1 is a walk that RAN AND FAILED, and
// letting it render as "0 sites" would turn a failed probe into the measured
// claim that this box serves nothing.
func spaceSitesLine(sp *cloudclient.MetricsSpace) string {
	line := "  sites"
	if sp.Sites.Dir != nil && strings.TrimSpace(*sp.Sites.Dir) != "" {
		line += " (" + sanitizeCell(strings.TrimSpace(*sp.Sites.Dir)) + ")"
	}
	line += ": "
	switch {
	case sp.Sites.Bytes == nil:
		line += "size not reported"
	case *sp.Sites.Bytes < 0:
		// The -1 sentinel, worded. It was reaching the terminal as the literal
		// string "-1 B" — a NEGATIVE byte figure presented as a size, on the
		// live build-plane box, whose sites walk fails on every cadence. The
		// count beside it already words its own -1 correctly; the bytes did
		// not, and the two halves of the same measurement disagreed on screen.
		line += "size UNKNOWN: the walk failed (this is not a size of zero)"
	default:
		line += humanBytes(*sp.Sites.Bytes)
	}

	switch {
	case sp.Sites.Count == nil:
		line += "  ·  site count not reported by this agent"
	case *sp.Sites.Count < 0:
		line += "  ·  site count UNKNOWN: the walk failed (this is not a count of zero)"
	default:
		line += fmt.Sprintf("  ·  %d sites", int(*sp.Sites.Count))
	}

	switch {
	case sp.Sites.Top == nil:
		line += "  ·  biggest consumers not reported"
	case len(sp.Sites.Top) == 0:
		line += "  ·  no sites reported"
	}
	return line
}

// spaceConsumerLines names the roots this box was told to look at, one line
// each, with WHAT WAS FOUND INSIDE them.
//
// Until this existed `bp` had no reader for consumer_roots at all. The agent
// has posted the rows since #13000 and the only surface that rendered them was
// the browser console, so an operator holding a terminal still had to ssh to
// the box to learn what was eating its disk — with the answer already sitting
// in the control plane's database. The whole point of the space payload was to
// stop that being an ssh question.
//
// Every root gets a line even when it holds nothing, and ESPECIALLY when it is
// absent: a row that vanishes is indistinguishable from a root that is empty,
// and that confusion is how a probe pointed at /opt/barkpark/sites reported
// good news about a box that was 100% full.
func spaceConsumerLines(sp *cloudclient.MetricsSpace) []string {
	if sp.ConsumerRoots == nil {
		return []string{"  consumers on this box: not reported — this agent predates the consumer-root list " +
			"(it looks only at the sites tree, which does not exist on a build box at all)"}
	}
	if len(sp.ConsumerRoots) == 0 {
		return []string{"  consumers on this box: none configured — this agent was told to look nowhere, " +
			"which is not the same as looking and finding nothing"}
	}

	lines := make([]string, 0, len(sp.ConsumerRoots)+1)
	lines = append(lines, "  consumers on this box:")
	for _, r := range sp.ConsumerRoots {
		lines = append(lines, "    "+spaceConsumerLine(r))
	}
	return lines
}

func spaceConsumerLine(r cloudclient.MetricsSpaceConsumerRoot) string {
	line := sanitizeCell(strings.TrimSpace(r.Path)) + ": "
	status := ""
	if r.Status != nil {
		status = *r.Status
	}

	switch status {
	case "absent":
		// The state this whole axis exists for. It is a MEASUREMENT — "we
		// looked; there is no such directory" — and it must never render as a
		// size, least of all as zero.
		return line + "not on this box (this is a measurement, not a size of zero)"
	case "unmeasured", "":
		return line + "could not be read (this is not a size of zero)"
	}

	if r.Bytes == nil || *r.Bytes < 0 {
		return line + "size not reported"
	}
	line += humanBytes(*r.Bytes)
	if status == "degraded" {
		// The number is a FLOOR, not a size: measured on a real box, 212K
		// reported against a true 712K, a 70% shortfall. Word it as "or more"
		// or the reader takes a floor for an answer.
		line += " OR MORE"
		if r.DegradedCount != nil && *r.DegradedCount > 0 {
			line += fmt.Sprintf(" (du could not descend into %d subtree(s)", int(*r.DegradedCount))
			if len(r.Degraded) > 0 {
				line += ": " + sanitizeCell(strings.Join(r.Degraded, ", "))
			}
			line += ")"
		}
	}

	// The biggest child, by name. An operator acts on
	// io.containerd.snapshotter.v1.overlayfs, never on "/var/lib/containerd".
	if len(r.Top) > 0 {
		line += "  ·  biggest: " + sanitizeCell(r.Top[0].Name) + " " + humanBytes(r.Top[0].Bytes)
		if r.Count != nil && int(*r.Count) > len(r.Top) {
			line += fmt.Sprintf(" (top %d of %d)", len(r.Top), int(*r.Count))
		}
	}

	// And WHY it was held out of the residual, if it was. This is on the same
	// line as the bytes on purpose: the reading is real and the exclusion is
	// about the SUBTRACTION, and splitting them invites reading one without the
	// other.
	if r.ExcludedReason != nil && strings.TrimSpace(*r.ExcludedReason) != "" {
		line += "  ·  " + wordExclusion(strings.TrimSpace(*r.ExcludedReason))
	}
	return line
}

// wordExclusion turns the payload's machine-readable slug into the sentence for
// this surface. The slug is the contract; every surface words it for its own
// reader, and none of them parses prose back into a decision.
func wordExclusion(reason string) string {
	switch {
	case reason == "cross-mount":
		return "NOT subtracted: on a different filesystem than /, so these bytes are not in this box's root-filesystem total"
	case reason == "device-unverified":
		return "NOT subtracted: this agent could not tell which filesystem it is on, and unknown is not the same as same"
	case strings.HasPrefix(reason, "under:"):
		return "NOT subtracted: already counted inside " + sanitizeCell(strings.TrimPrefix(reason, "under:"))
	}
	return "NOT subtracted: " + sanitizeCell(reason)
}

// spaceResidualLine is the line this whole axis was missing: what the reading
// did NOT measure.
//
// COVERAGE IS ALWAYS THIS BOX'S, NEVER THE FLEET'S, and the wording says so in
// as many words. That is not pedantry — coverage is ANTI-CORRELATED with
// trouble: the same two roots cover 81.66% of the box at 96% disk and 34.86% of
// another, a 47-point spread, so a fleet-wide average is highest exactly where
// it is least true. There is no such thing as "the fleet's coverage" on this
// axis, only one box's at a time.
func spaceResidualLine(sp *cloudclient.MetricsSpace) string {
	const head = "  unaccounted: "
	r := sp.Residual
	if r == nil {
		return head + "not reported — this agent predates the residual, so the roots above are a " +
			"SUBSET of this box's disk and nothing says how large a subset"
	}

	status := ""
	if r.Status != nil {
		status = *r.Status
	}

	switch status {
	case "undefined":
		// The clamp, worded. A negative figure never reaches here, and neither
		// does a zero: "0 B unaccounted" is the strongest claim this axis can
		// make and it must not be reachable by arithmetic going wrong.
		line := head + "NOT COMPUTABLE"
		if r.MeasuredBytes != nil && r.OfBytes != nil {
			line += fmt.Sprintf(" — the measured roots total %s against this box's %s used",
				humanBytes(*r.MeasuredBytes), humanBytes(*r.OfBytes))
		}
		return line + ". Disjoint trees on one filesystem cannot exceed its used total, so the " +
			"roots overlap or cross a mount. No figure is reported rather than a negative one"
	case "unmeasured":
		reason := ""
		if r.Reason != nil {
			reason = *r.Reason
		}
		switch reason {
		case "root-used-unmeasured":
			return head + "not computed — this box reported no root-filesystem used total, and there is " +
				"nothing to subtract from (df's capacity percent is a share of a different whole and is not a substitute)"
		case "root-device-unverified":
			return head + "not computed — this agent could not verify which filesystem its roots are on, " +
				"and roots that cannot be placed cannot be subtracted"
		}
		return head + "not computed"
	case "computed":
	default:
		return head + "not reported"
	}

	if r.Bytes == nil || r.OfBytes == nil || *r.Bytes < 0 {
		return head + "not reported"
	}

	// The value, its share, AND the denominator that produced the share — all
	// three, so nothing here can be quoted as a percentage nobody can check.
	line := head + humanBytes(*r.Bytes) + " (" + pctOf(*r.Bytes, *r.OfBytes) +
		" of this box's " + humanBytes(*r.OfBytes) + " used)"

	if r.CountedRoots != nil {
		total := int(*r.CountedRoots)
		if r.ExcludedRoots != nil {
			total += int(*r.ExcludedRoots)
		}
		line += fmt.Sprintf("  ·  measured %d of %d root(s) on this box", int(*r.CountedRoots), total)
		if r.ExcludedRoots != nil && *r.ExcludedRoots > 0 {
			line += " (the rest are named above with the reason they were not subtracted)"
		}
	}

	// Postgres is the one consumer this payload can measure twice, so which
	// measurement was used is stated rather than assumed.
	if r.PGSource != nil {
		switch *r.PGSource {
		case "du-root":
			line += "  ·  postgres counted once, via its du root"
		case "pg-size-bytes":
			line += "  ·  postgres counted once, via pg_database_size"
		}
	}
	return line
}

// pctOf renders a share as a one-decimal percent. A non-positive denominator
// yields "—" (never a divide-by-zero, never an invented share).
func pctOf(part, whole float64) string {
	if whole <= 0 {
		return "—"
	}
	return fmt.Sprintf("%.1f%%", part/whole*100)
}

// renderMetricsBlocks renders the adapted blocks through the shared pdrender
// registry at the writer's resolved width + colour. It keys off the WRITER (not
// os.Stdout directly) so a non-tty / --no-color render is deterministic plain
// text — the same discipline that makes the golden tests offline.
func renderMetricsBlocks(out *writer, blocks []pdrender.Block) string {
	width := 80
	if out.isTTY {
		if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 0 {
			width = w
		}
	}
	profile := pdrender.NoColor
	if out.color && out.isTTY {
		profile = pdrender.ANSI256
	}
	cfg, _ := LoadConfig()
	theme := paperResolveTheme("auto", ResolveThemeID(cfg))
	// Bind lipgloss's global colour profile so the resolved profile is
	// authoritative over auto-detection (the paper_cmd bridge; one-shot + safe —
	// the CLI renders once and exits).
	lipgloss.SetColorProfile(paperTermenvProfile(profile))
	rctx := pdrender.RenderCtx{Width: width, Theme: theme, Profile: profile}
	return pdrender.DefaultRegistry(theme).RenderDoc(blocks, rctx)
}

// printCloudInstanceTopHelp writes `bp cloud instance top` usage.
func printCloudInstanceTopHelp(out *writer) {
	const help = `bp cloud instance top — a one-shot vitals snapshot for a managed instance.

USAGE
  bp cloud instance top <instance> [--points <n>] [-o json|yaml]

WHAT IT DOES
  Reads the on-box agent's rolled beat window through the control plane and
  renders CPU / memory / disk / load / swap / the BEAM's own footprint over the
  window, then the database size with its biggest NAMED relations, then a
  service-health rollup — the SAME truth on every provider and on
  adopted/self-hosted boxes (monitoring keys off the agent beat, never a
  provider metrics API).

  SWAP has three honest states, because a percent alone cannot carry them: a
  box with no swap configured reads "none configured" (never 0%), a box with
  swap reads "<pct>% of <total>", and a box whose probe could not measure reads
  an em dash. Swap is the vital MEMORY HIDES — a box paging its BEAM out can
  still report comfortable memory.

  <instance> is a fleet name or id (the forms bp cloud status shows); needs
  'bp login'. --points requests how many samples to roll (default: the server's
  window). A box that hasn't reported yet shows an honest "no vitals yet" line;
  a box whose agent went quiet shows the last-known window with a STALE banner —
  both are normal results, never a CLI error.

ONE-SHOT
  A single snapshot — there is no --watch. Re-run to refresh (the data cadence is
  the ~60s agent beat).

OUTPUT
  a header, the beat state, a stat grid + trend chart, the storage breakdown,
  and the health rollup.
  -o json    the metrics envelope verbatim: {ok, collected_at, instance, beat,
             points, series, latest, service_health}`
	out.outf("%s", help)
}
