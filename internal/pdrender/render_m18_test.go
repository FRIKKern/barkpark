package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// renderM18Fixture renders the M18 gauge-list fixture (count mode by worker +
// share mode) with NoColor pinned so the golden is byte-stable in CI. The meter
// tint is an ANSI style, so ansi.Strip drops it — the golden asserts the DATUM
// that survives: the label column, the ▓/░ bar LENGTH, and the right-aligned
// count/percent digits (the detail-ceiling doctrine — geometry carries the
// datum, colour only reinforces).
func renderM18Fixture(t *testing.T, name string, width int) string {
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
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	out := reg.RenderDoc(blocks, ctx)
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM18 renders the gauge-list fixture at every golden width and diffs it
// against the checked-in golden (regenerate with -update).
func TestGoldenM18(t *testing.T) {
	const fx = "sample_m18.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM18Fixture(t, fx, w)
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
				t.Errorf("M18 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestGaugeListProfileStripEquality is the acceptance proof that a gauge-list is a
// COMPLETE artifact at all three profiles: via the shared assertStripComplete
// helper, the ANSI-stripped render is BYTE-IDENTICAL under NoColor, ANSI256, and
// TrueColor at every golden width. The meter never uses a profile-only glyph
// (statBar's ▓/░ is universal), so colour is pure reinforcement — strip it and the
// label + bar length + digits still carry the whole datum.
func TestGaugeListProfileStripEquality(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m18.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "gauge_list_sample_m18", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})
}

// gaugeRender is a small helper: render one gauge-list block at NoColor and strip.
func gaugeRender(attrs map[string]any, width int) string {
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	defer lipgloss.SetColorProfile(old)
	b := Block{Type: "gauge-list", Attrs: attrs}
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	return ansi.Strip(strings.Join(gaugeListRenderer{}.Render(b, ctx), "\n"))
}

// TestGaugeListCountBuckets pins count mode: buckets by the groupBy field, sorts
// DESC by count then label ASC, and folds a missing field into the "(none)"
// bucket rather than dropping the row. The datum (the count digit) is present.
func TestGaugeListCountBuckets(t *testing.T) {
	out := gaugeRender(map[string]any{
		"mode":    "count",
		"groupBy": "worker",
		"snapshot": []any{
			map[string]any{"worker": "ada"},
			map[string]any{"worker": "ada"},
			map[string]any{"worker": "grace"},
			map[string]any{"status": "ready"}, // no worker → (none)
		},
	}, 60)

	// ada leads (2), then grace (1) and (none) (1) tie → label asc puts "(none)"
	// before "grace".
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected 3 gauge rows, got %d:\n%s", len(lines), out)
	}
	if !strings.HasPrefix(lines[0], "ada") {
		t.Errorf("row 0: expected ada first (highest count), got %q", lines[0])
	}
	if !strings.Contains(lines[0], "2") {
		t.Errorf("row 0: expected count digit 2, got %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], "(none)") {
		t.Errorf("row 1: expected (none) bucket second (tie, label asc), got %q", lines[1])
	}
	if !strings.HasPrefix(lines[2], "grace") {
		t.Errorf("row 2: expected grace last, got %q", lines[2])
	}
	// The full meter (▓) belongs to the leader; a strip keeps the bar geometry.
	if !strings.Contains(lines[0], "▓") {
		t.Errorf("row 0: expected a filled ▓ meter, got %q", lines[0])
	}
}

// TestGaugeListSharePercent pins share mode: meter = value/Σ (no `max`), the
// readout digit is the meter's own percent, and author order is preserved.
func TestGaugeListSharePercent(t *testing.T) {
	out := gaugeRender(map[string]any{
		"mode": "share",
		"rows": []any{
			map[string]any{"label": "media", "value": 71.0, "note": "images"},
			map[string]any{"label": "papers", "value": 32.0},
			map[string]any{"label": "tasks", "value": 15.0},
		},
	}, 80)
	// 71/118 ≈ 60%. The percent digit is the exact reading of the bar.
	if !strings.Contains(out, "60%") {
		t.Errorf("expected media at 60%% (71/118), got:\n%s", out)
	}
	if !strings.Contains(out, "images") {
		t.Errorf("expected the trailing note 'images', got:\n%s", out)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if !strings.HasPrefix(lines[0], "media") {
		t.Errorf("share preserves author order: expected media first, got %q", lines[0])
	}
}

// TestGaugeListPreservesLongLabelsAndNotes locks the reader doctrine for data
// visualisations: width pressure may add rows, but it must not replace authored
// label or note text with renderer ellipses.
func TestGaugeListPreservesLongLabelsAndNotes(t *testing.T) {
	label := "S-tier blocks locked OUT (equation incl.)"
	note := "the deliberately long explanatory door note"
	out := gaugeRender(map[string]any{
		"mode": "share",
		"max":  75,
		"rows": []any{
			map[string]any{"label": label, "value": 12.0, "note": note},
			map[string]any{"label": "reachable from the insert palette", "value": 33.0},
		},
	}, 40)

	if strings.Contains(out, "…") {
		t.Fatalf("gauge-list introduced an ellipsis:\n%s", out)
	}
	compact := semanticCompact(out)
	for _, authored := range []string{label, note} {
		for _, word := range strings.Fields(authored) {
			word = semanticCompact(word)
			if len(word) <= 10 && !strings.Contains(compact, word) {
				t.Errorf("missing authored word %q from %q:\n%s", word, authored, out)
			}
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if ansi.StringWidth(line) > 40 {
			t.Errorf("line width %d exceeds 40: %q", ansi.StringWidth(line), line)
		}
	}
}

// TestGaugeListDegrades pins the honest degrade paths: an absent data key →
// `[gauge-list — unresolved]`; groupBy "epic" → a dim resolver note (NEVER faked
// from a parent); and `query` is never read as data.
func TestGaugeListDegrades(t *testing.T) {
	// Count mode, snapshot absent (only a query) → unresolved placeholder.
	if out := gaugeRender(map[string]any{
		"mode":  "count",
		"query": "SELECT ...",
	}, 60); !strings.Contains(out, "gauge-list — unresolved") {
		t.Errorf("absent snapshot: expected unresolved placeholder, got %q", out)
	}
	// Share mode, rows absent → unresolved placeholder.
	if out := gaugeRender(map[string]any{"mode": "share"}, 60); !strings.Contains(out, "gauge-list — unresolved") {
		t.Errorf("absent rows: expected unresolved placeholder, got %q", out)
	}
	// groupBy epic → the honest resolver note, even WITH a snapshot present (it
	// must never fake the grouping from parent rows).
	if out := gaugeRender(map[string]any{
		"mode":     "count",
		"groupBy":  "epic",
		"snapshot": []any{map[string]any{"worker": "ada"}},
	}, 60); !strings.Contains(out, "epic grouping needs the resolver") {
		t.Errorf("groupBy epic: expected the dim resolver note, got %q", out)
	}
}
