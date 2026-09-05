package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── M15: data-viz live-data end-to-end proof ─────────────────────────────────
//
// This is the pdrender-side capstone of the data-viz live-data arc. #1510 shipped
// the Elixir half — Tasks.Query.agg_for_query/2 (count rollup) → TaskResolver.
// shape/2 (tally → the ratified series/cells/value Attrs) → papers.ex
// resolve_tasks_in_blocks/2 (every reader surface funnels through it) — with unit
// tests byte-asserting the shape a query-bearing chart/heatmap/stat block becomes
// AFTER resolution. What #1510 does NOT cover is the render end of the pipe: that
// the Go renderers consume that resolved shape and draw LIVE data, and that an
// UNRESOLVED block (only a `query` reached the renderer — an offline / wasm render,
// or agg turned off) degrades to the honest dim placeholder.
//
// M15 proves both. The golden fixture (sample_m15.json) carries the resolved Attrs
// EXACTLY as shape/2 stamps them:
//
//	chart   → series:[{label, points:[n…]}]        (one series per groupBy value,
//	                                                  points per `over` bucket)
//	heatmap → cells:[[n…]], max, rowLabels, colLabels
//	stat    → value:n, spark:[n…]
//
// so the golden IS the shape/2 → renderer contract, byte-locked at four widths.
//
// MAX-2-SERIES CAP (pbp-slate2-chart-units): the fixture's chart still carries the
// THREE status series shape/2 resolves (open/ready/done) — that is the honest
// resolver output — but the renderer now caps a chart at the first two series
// (chart.go maxChartSeries), so the golden shows open+ready only and the "done"
// curve+swatch are dropped. That makes this fixture double as the live-data proof
// that the cap holds on real resolved data, not just a synthetic 3-series unit
// test. The goldens were regenerated once for this cap; nothing else moved (the
// compact-unit tick change is a no-op below 10000, and every m15 value is small).
// TestM15ResolvedVsQueryOnly is the non-vacuous companion: a block WITH the
// resolved shape renders its live content, the SAME block type carrying only a
// `query` renders the placeholder — the resolve→render transparency and the
// offline fallback proven in one, without a golden that could pass vacuously.

// renderM15Fixture renders the M15 data-viz fixture with NoColor pinned so the
// goldens are byte-stable (same discipline as the other milestone fixtures).
func renderM15Fixture(t *testing.T, name string, width int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	reg := testRegistry() // pins lipgloss to Ascii (NoColor)
	ctx := RenderCtx{
		Width:   width,
		Theme:   DarkTheme(),
		Profile: NoColor,
	}
	out := reg.RenderDoc(blocks, ctx)
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM15 byte-locks the LIVE data-viz render: the resolved chart (braille
// step-line + per-series legend), heatmap (shade grid + row/col labels + legend),
// and stat (big number + caption + sparkline) as they render from the resolved
// Attrs shape/2 produces. Regenerate with -update.
func TestGoldenM15(t *testing.T) {
	const fx = "sample_m15.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM15Fixture(t, fx, w)
			goldenPath := filepath.Join("testdata", "golden", name+"_w"+itoa(w)+".txt")
			if *update {
				if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden (run with -update to create): %v", err)
			}
			if got != string(want) {
				t.Errorf("M15 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// resolvedTestCtx is a NoColor render context for the structural assertions.
func resolvedTestCtx() RenderCtx {
	testRegistry() // pin lipgloss profile to Ascii
	return RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
}

// renderOne renders a single block through its renderer and returns the
// ANSI-stripped, newline-joined output.
func renderOne(r Renderer, b Block, ctx RenderCtx) string {
	return ansi.Strip(strings.Join(r.Render(b, ctx), "\n"))
}

// TestM15ResolvedVsQueryOnly is the non-vacuous transparency proof: for each
// data-viz block type, a block carrying the RESOLVED shape (what shape/2 stamps
// after a query is rolled up) renders LIVE content, while the SAME block type
// carrying ONLY a `query` (unresolved — an offline / wasm render, or agg off,
// exactly the case resolve_block leaves untouched) renders the dim placeholder.
// This proves the resolve→render transparency AND the offline fallback in one,
// so TestGoldenM15 can never pass vacuously.
func TestM15ResolvedVsQueryOnly(t *testing.T) {
	ctx := resolvedTestCtx()

	// A `query`-only block is what reaches the renderer when the resolver did NOT
	// run (offline/wasm) or returned {:error, _} — resolve_block leaves it as-is.
	queryOnly := func(typ string) Block {
		return Block{Type: typ, Attrs: map[string]any{
			"type":  typ,
			"query": map[string]any{"source": "tasks", "groupBy": "status"},
		}}
	}

	cases := []struct {
		name        string
		renderer    Renderer
		resolved    Block
		liveMarkers []string // substrings that prove live data rendered
		placeholder string
	}{
		{
			name:     "chart",
			renderer: chartRenderer{},
			// shape/2 chart: one series per groupBy value, points per `over` bucket.
			resolved: Block{Type: "chart", Attrs: map[string]any{
				"type": "chart",
				"series": []any{
					map[string]any{"label": "open", "points": []any{3.0, 4.0, 2.0, 5.0}},
					map[string]any{"label": "done", "points": []any{0.0, 1.0, 3.0, 6.0}},
				},
			}},
			liveMarkers: []string{"open", "done"}, // per-series legend labels
			placeholder: "[chart — unresolved]",
		},
		{
			name:     "heatmap",
			renderer: heatmapRenderer{},
			// shape/2 heatmap: cells/max/rowLabels/colLabels.
			resolved: Block{Type: "heatmap", Attrs: map[string]any{
				"type":      "heatmap",
				"cells":     []any{[]any{0.0, 1.0}, []any{2.0, 3.0}},
				"max":       3.0,
				"rowLabels": []any{"open", "done"},
				"colLabels": []any{"Mon", "Tue"},
			}},
			liveMarkers: []string{"open", "done", "less", "more"}, // row labels + legend key
			placeholder: "[heatmap — unresolved]",
		},
		{
			name:     "stat",
			renderer: statRenderer{},
			// shape/2 stat: a scalar count value + an `over` spark.
			resolved: Block{Type: "stat", Attrs: map[string]any{
				"type":  "stat",
				"value": 14.0, // shape/2 stamps an integer count; toStr → "14"
				"label": "open tasks",
				"spark": []any{3.0, 4.0, 2.0, 5.0},
			}},
			liveMarkers: []string{"14", "open tasks"}, // the count + caption
			placeholder: "[stat — unresolved]",
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			live := renderOne(tc.renderer, tc.resolved, ctx)
			if strings.Contains(live, "unresolved") {
				t.Fatalf("%s: resolved block rendered the placeholder, not live data:\n%s", tc.name, live)
			}
			for _, m := range tc.liveMarkers {
				if !strings.Contains(live, m) {
					t.Errorf("%s: resolved render missing live marker %q\n%s", tc.name, m, live)
				}
			}

			placeholder := renderOne(tc.renderer, queryOnly(tc.name), ctx)
			if placeholder != tc.placeholder {
				t.Errorf("%s: query-only block should degrade to %q, got %q",
					tc.name, tc.placeholder, placeholder)
			}
		})
	}
}
