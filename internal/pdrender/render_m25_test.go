package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// renderM25Fixture renders the M25 dashboard fixture with NoColor pinned so the
// goldens are byte-stable (same discipline as the other milestone fixtures).
func renderM25Fixture(t *testing.T, name string, width int) string {
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

// TestGoldenM25 is the TUI creative slate W3 composition capstone: the dashboard
// container. The fixture is a 2-tab /usage-style cockpit (Overview: chart +
// heatmap + stat-grid-with-denom + gauge-list; Agents: a stat), active tab 0. At
// wide widths the four Overview blocks compose into a two-track grid; at narrow
// widths they stack and the height budget truncates with a dim marker.
// Regenerate with -update.
func TestGoldenM25(t *testing.T) {
	const fx = "sample_m25.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM25Fixture(t, fx, w)
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
				t.Errorf("M25 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestM25CompositionFitsGolden proves the charter's 22×80 composition budget: the
// w80 render of the /usage cockpit is at most 22 rows tall and at most 80 columns
// wide — the "≤22 rows × 80 cols golden" acceptance bar.
func TestM25CompositionFitsGolden(t *testing.T) {
	got := renderM25Fixture(t, "sample_m25.json", 80)
	lines := strings.Split(got, "\n")
	if len(lines) > 22 {
		t.Errorf("w80 dashboard composition is %d rows, want ≤22:\n%s", len(lines), got)
	}
	for i, ln := range lines {
		if w := ansi.StringWidth(ln); w > 80 {
			t.Errorf("w80 dashboard line %d is %d cols wide, want ≤80: %q", i, w, ln)
		}
	}
}

// TestM25StripComplete holds the dashboard to the detail-ceiling strip law at all
// three profiles and every golden width: stripping colour from the ANSI256 /
// TrueColor renders must leave exactly the NoColor render — the datum (labels,
// the heavy ━ rail, the composed child geometry) lives in glyphs, colour only
// reinforces.
func TestM25StripComplete(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m25.json"))
	if err != nil {
		t.Fatalf("read sample_m25: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode sample_m25: %v", err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "dashboard_sample_m25", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})
}

// TestM25ActiveRailRune is the PROTECTIVE test the charter demands: the heavy ━
// rail rune MUST appear in the NoColor render under the active tab, so the active
// selection is geometry — not a bold-only styling that strips away and passes
// assertStripComplete vacuously. It also asserts the inactive-tab rail uses the
// dim ─ rune (the rail is a real rule, not a bare heavy run).
func TestM25ActiveRailRune(t *testing.T) {
	got := renderM25Fixture(t, "sample_m25.json", 80)
	lines := strings.Split(got, "\n")
	if len(lines) < 2 {
		t.Fatalf("dashboard render too short:\n%s", got)
	}
	rail := lines[1] // labels row, then the rail row
	if !strings.ContainsRune(rail, '━') {
		t.Errorf("active rail row has no heavy ━ rune — selection is not geometry:\n%q", rail)
	}
	if !strings.ContainsRune(rail, '─') {
		t.Errorf("rail row has no dim ─ rune — the rule is not full-width:\n%q", rail)
	}
	// The active tab ("Overview", 8 cols) is first, so the heavy run starts at
	// column 0: the rail must LEAD with ━.
	if !strings.HasPrefix(rail, "━") {
		t.Errorf("active tab is first but rail does not lead with ━:\n%q", rail)
	}
}

// TestM25HeightBudget proves the renderer owns its own height: a dashboard whose
// active tab overflows a tight `rows` budget is capped to `rows` lines with a dim
// "… N more rows" truncation marker on the last line.
func TestM25HeightBudget(t *testing.T) {
	// Eight note rows stacked into a narrow (stack-path) surface, capped at rows:8.
	// The strip+rhythm is 3 rows, leaving 5 for the body → truncation. (note reads a
	// plain `text` attr, so each row renders a visible line without inline content.)
	tallBlocks := make([]any, 0, 8)
	for i := 0; i < 8; i++ {
		tallBlocks = append(tallBlocks, map[string]any{
			"type": "note",
			"text": "Row " + itoa(i) + " of a tall child block that eats the height budget.",
		})
	}
	block := Block{Type: "dashboard", Attrs: map[string]any{
		"rows":   8.0,
		"active": 0.0,
		"tabs": []any{
			map[string]any{"label": "Tall", "blocks": tallBlocks},
		},
	}}
	reg := DefaultRegistry(DarkTheme())
	// Width 30 keeps the two-track cell below MinWidth so the body stacks tall.
	out := reg.Render(block, RenderCtx{Width: 30, Theme: DarkTheme(), Profile: NoColor})
	if len(out) > 8 {
		t.Errorf("dashboard exceeded rows:8 budget — got %d lines:\n%s", len(out), strings.Join(out, "\n"))
	}
	last := ansi.Strip(out[len(out)-1])
	if !strings.Contains(last, "more rows") {
		t.Errorf("over-budget dashboard has no truncation marker; last line = %q", last)
	}
}

// TestM25ManyTabsClampToWidth proves the labels row never overflows the surface:
// a tab strip wider than the terminal is clamped to width with the house …
// ellipsis (the rail row already clamps; without this the labels row would be the
// one over-wide line a dashboard could emit).
func TestM25ManyTabsClampToWidth(t *testing.T) {
	tabs := make([]any, 0, 8)
	for i := 0; i < 8; i++ {
		tabs = append(tabs, map[string]any{
			"label":  "A very long tab label " + itoa(i),
			"blocks": []any{map[string]any{"type": "note", "text": "body"}},
		})
	}
	block := Block{Type: "dashboard", Attrs: map[string]any{"tabs": tabs, "active": 7.0}}
	reg := DefaultRegistry(DarkTheme())
	const w = 40
	out := reg.Render(block, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor})
	for i, ln := range out {
		if lw := ansi.StringWidth(ln); lw > w {
			t.Errorf("dashboard line %d is %d cols wide, want ≤%d: %q", i, lw, w, ln)
		}
	}
	if !strings.Contains(ansi.Strip(out[0]), "…") {
		t.Errorf("over-wide labels row should clamp with the house … ellipsis, got %q", out[0])
	}
}

// TestM25EmptyTabs proves the empty-state degrade: a dashboard with no tabs
// renders one blank line, never panics.
func TestM25EmptyTabs(t *testing.T) {
	reg := DefaultRegistry(DarkTheme())
	out := reg.Render(Block{Type: "dashboard", Attrs: map[string]any{}}, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})
	if len(out) != 1 || strings.TrimSpace(out[0]) != "" {
		t.Errorf("empty dashboard should render one blank line, got %q", out)
	}
}
