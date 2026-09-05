package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ── M26: the 53-week calendar proven at wide widths ──────────────────────────
//
// The heat-family closure (pbp-slate2-heat-closure). heatRenderCalendar is
// already width+data-driven (heatmap.go): weeks = the widest day-row, and the
// weeks that FIT = (clampWidth-heatCalGutter)/heatCalCellW. The wave-1 m17
// fixture only carried 38 weeks — exactly the 80-col budget — so nothing ever
// exercised the wider-than-80 path. sample_m26 carries a FULL 53-week year (53
// week-cols × 7 day-rows, with 53 per-week month colLabels so the month header
// is complete, not silently truncated), proving:
//
//   - w120: fit = (120-4)/2 = 58 ≥ 53, so every one of the 53 week-columns
//     renders in full — the newest "Dec" AND the oldest "Jan" are both present.
//   - narrower widths drop the OLDEST (leftmost) whole weeks (heatmap.go's
//     documented, tested behavior — never a squash): at w40 fit = 18, so the
//     start slides to week 35 and "Jan" is gone while "Dec" stays.
//
// The goldens are the NoColor artifact at four widths; TestM26StripComplete
// holds the detail-ceiling strip law across all three profiles via the shared
// assertStripComplete helper. Regenerate the goldens with -update.

// renderM26Fixture renders the M26 fixture with NoColor pinned so the goldens
// are byte-stable in CI (same discipline as every milestone fixture).
func renderM26Fixture(t *testing.T, name string, width int) string {
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
	stripped := ansi.Strip(reg.RenderDoc(blocks, ctx))
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM26 byte-locks the 53-week calendar render at every golden width
// (40/60/80/120). Regenerate with -update.
func TestGoldenM26(t *testing.T) {
	const fx = "sample_m26.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM26Fixture(t, fx, w)
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
				t.Errorf("M26 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestM26StripComplete holds the detail-ceiling strip law on the 53-week
// calendar at all three colour profiles via the shared assertStripComplete
// helper: the quantile shade glyphs live in geometry, so the ANSI-stripped
// ANSI256 and TrueColor renders are byte-identical to NoColor.
func TestM26StripComplete(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m26.json"))
	if err != nil {
		t.Fatal(err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "calendar_53week_sample_m26", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})
}

// TestM26WideCalendarWeekCount is the non-vacuous width proof: at the widest
// golden width every one of the 53 week-columns survives (the newest AND the
// oldest month labels are both present), while at the narrowest width the
// drop-oldest logic slides the window forward — the oldest month falls off and
// the newest stays. Without this the golden could pass while silently rendering
// a truncated 38-week window.
func TestM26WideCalendarWeekCount(t *testing.T) {
	// w120: fit = (120-4)/2 = 58 ≥ 53 → all 53 weeks render; Jan (week 0) and
	// Dec (week 49) are both stamped in the month header.
	wide := renderM26Fixture(t, "sample_m26.json", 120)
	for _, m := range []string{"Jan", "Dec"} {
		if !strings.Contains(wide, m) {
			t.Errorf("w120: expected all 53 weeks (month %q present in header), got:\n%s", m, wide)
		}
	}
	// The widest day-row must carry 53 two-col cells (106 cols) after its 4-col
	// gutter — assert one grid line is at least gutter+53*2 = 110 wide.
	widest := 0
	for _, ln := range strings.Split(wide, "\n") {
		if w := len([]rune(ln)); w > widest {
			widest = w
		}
	}
	if widest < heatCalGutter+53*heatCalCellW {
		t.Errorf("w120: widest calendar line %d cols, expected ≥ %d (all 53 weeks)", widest, heatCalGutter+53*heatCalCellW)
	}

	// w40: fit = (40-4)/2 = 18 → the window slides to week 35, dropping the
	// oldest months. Jan is gone; Dec (a late month) survives.
	narrow := renderM26Fixture(t, "sample_m26.json", 40)
	if strings.Contains(narrow, "Jan") {
		t.Errorf("w40: expected the oldest weeks dropped (Jan absent), got:\n%s", narrow)
	}
	if !strings.Contains(narrow, "Dec") {
		t.Errorf("w40: expected the newest weeks kept (Dec present), got:\n%s", narrow)
	}
}
