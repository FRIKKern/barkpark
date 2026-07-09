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

// metricTopSpec is the render order + display shape for one vitals series. `pct`
// metrics render their headline as a whole-number percent; load carries no unit.
type metricTopSpec struct {
	key   string
	label string
	pct   bool
}

var metricTopSpecs = []metricTopSpec{
	{key: "cpu", label: "CPU", pct: true},
	{key: "mem", label: "Memory", pct: true},
	{key: "disk", label: "Disk", pct: true},
	{key: "load", label: "Load", pct: false},
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
		return useError(out, "auth", "not logged in — run `bp login` to read metrics", exitAuth)
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
		return
	}
	out.outf("")
	out.outf("%s", renderMetricsBlocks(out, blocks))

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
		switch {
		case current == nil:
			item["value"] = "—"
		case spec.pct:
			item["value"] = fmt.Sprintf("%d%%", int(math.Round(*current)))
		default:
			item["value"] = strconv.FormatFloat(math.Round(*current*100)/100, 'f', -1, 64)
		}
		if len(vals) > 0 {
			item["spark"] = vals
			chartSeries = append(chartSeries, map[string]any{"label": spec.label, "points": vals})
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
  renders CPU / memory / disk / load over the window plus a service-health
  rollup — the SAME truth on every provider and on adopted/self-hosted boxes
  (monitoring keys off the agent beat, never a provider metrics API).

  <instance> is a fleet name or id (the forms bp cloud status shows); needs
  'bp login'. --points requests how many samples to roll (default: the server's
  window). A box that hasn't reported yet shows an honest "no vitals yet" line;
  a box whose agent went quiet shows the last-known window with a STALE banner —
  both are normal results, never a CLI error.

ONE-SHOT
  A single snapshot — there is no --watch. Re-run to refresh (the data cadence is
  the ~60s agent beat).

OUTPUT
  a header, the beat state, a stat grid + trend chart, and the health rollup.
  -o json    the metrics envelope verbatim: {ok, collected_at, instance, beat,
             points, series, service_health}`
	out.outf("%s", help)
}
