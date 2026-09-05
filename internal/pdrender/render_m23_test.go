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

// renderM23Fixture renders the M23 task-list layout:{mode:"tree"} fixture with
// NoColor pinned so the golden is byte-stable. The rails (├─ └─ │) and the
// worker/priority meta grid are pure GEOMETRY — the status glyph tint is an ANSI
// style ansi.Strip drops — so the golden asserts the datum that survives: the
// tree shape and the aligned meta columns (the detail-ceiling doctrine).
func renderM23Fixture(t *testing.T, name string, width int) string {
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

// TestGoldenM23 renders the tree fixture at every golden width and diffs it
// against the checked-in golden (regenerate with -update).
func TestGoldenM23(t *testing.T) {
	const fx = "sample_m23.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM23Fixture(t, fx, w)
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
				t.Errorf("M23 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestTaskTreeProfileStripEquality is the acceptance proof that a tree-layout
// task-list is a COMPLETE artifact at all three profiles: the ANSI-stripped
// render is byte-identical under NoColor, ANSI256, and TrueColor at every golden
// width. The rails and the meta grid never use a profile-only glyph, so colour is
// pure reinforcement — strip it and the tree + columns still carry the datum.
func TestTaskTreeProfileStripEquality(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m23.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "task_tree_sample_m23", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})
}

// treeRender is a small helper: render one task-list tree block at NoColor and
// strip, returning the body lines (title + momentum + bar stripped off) so the
// rails are easy to assert.
func treeRender(attrs map[string]any, width int) []string {
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	defer lipgloss.SetColorProfile(old)
	b := Block{Type: "task-list", Attrs: attrs}
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(strings.Join(taskListRenderer{}.Render(b, ctx), "\n"))
	return strings.Split(out, "\n")
}

// TestTaskTreeRailsFromDepth pins the rail derivation: rails come PURELY from the
// consecutive depth sequence — └─ for a last child, ├─ for an earlier sibling,
// │ for an ancestor that still has a later sibling — with no parent_id on the
// wire. The three-level shape has a last child at every level.
func TestTaskTreeRailsFromDepth(t *testing.T) {
	lines := treeRender(map[string]any{
		"layout": map[string]any{"mode": "tree"},
		"snapshot": []any{
			map[string]any{"title": "root", "status": "in_progress", "depth": 0.0},
			map[string]any{"title": "a", "status": "ready", "depth": 1.0},
			map[string]any{"title": "a1", "status": "done", "depth": 2.0},
			map[string]any{"title": "a2", "status": "done", "depth": 2.0}, // last under a
			map[string]any{"title": "b", "status": "ready", "depth": 1.0}, // last under root
			map[string]any{"title": "b1", "status": "done", "depth": 2.0}, // last under b
		},
	}, 80)

	// The momentum line + bar occupy the first two lines; the tree follows. A
	// status glyph sits between the rail prefix and the title, so match the row
	// by its title and assert the rail PREFIX it begins with (glyph-agnostic).
	body := strings.Join(lines, "\n")
	assertRail := func(prefix, title string) {
		for _, ln := range lines {
			if strings.HasSuffix(strings.TrimRight(ln, " "), title) && strings.HasPrefix(ln, prefix) {
				return
			}
		}
		t.Errorf("row %q missing rail prefix %q in:\n%s", title, prefix, body)
	}
	assertRail("", "root")     // depth-0 root has no rail prefix (forest root)
	assertRail("├─ ", "a")     // a is an earlier sibling of b
	assertRail("│  ├─ ", "a1") // a1 under a (a still open) with a later sibling a2
	assertRail("│  └─ ", "a2") // a2 last under a, but a still has sibling b → │
	assertRail("└─ ", "b")     // b is the last child of root
	assertRail("   └─ ", "b1") // b1 last under b, and b is last → blank ancestor col

	// Rails must be present as literal box-drawing (a stripped, complete artifact).
	for _, g := range []string{"├─", "└─", "│"} {
		if !strings.Contains(body, g) {
			t.Errorf("expected rail glyph %q in tree render:\n%s", g, body)
		}
	}
}

// TestTaskTreeMetaGridAligns pins the right-aligned worker/priority meta grid:
// the worker column is padded to a shared width across rows, so the priority
// P-cells line up flush at the surface edge.
func TestTaskTreeMetaGridAligns(t *testing.T) {
	const w = 60
	lines := treeRender(map[string]any{
		"layout": map[string]any{"mode": "tree"},
		"snapshot": []any{
			map[string]any{"title": "one", "status": "ready", "worker": "ada", "priority": "1", "depth": 0.0},
			map[string]any{"title": "two", "status": "ready", "worker": "grace", "priority": "2", "depth": 0.0},
		},
	}, w)
	// Find the two task rows (skip momentum line + bar).
	var rows []string
	for _, ln := range lines {
		if strings.Contains(ln, "P1") || strings.Contains(ln, "P2") {
			rows = append(rows, ln)
		}
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 meta rows, got %d:\n%s", len(rows), strings.Join(lines, "\n"))
	}
	for _, r := range rows {
		if lipgloss.Width(r) != w {
			t.Errorf("meta row not padded flush to %d cols (got %d): %q", w, lipgloss.Width(r), r)
		}
	}
	// The priority cells end at the same (final) column — flush right.
	if !strings.HasSuffix(rows[0], "P1") || !strings.HasSuffix(rows[1], "P2") {
		t.Errorf("priority column not flush-right:\n%s", strings.Join(rows, "\n"))
	}
}

// TestTaskTreeAbsentLayoutIsLegacy proves the guard: with no layout the render is
// the legacy phase-grouped list (rails never appear), so existing task-list
// goldens are untouched.
func TestTaskTreeAbsentLayoutIsLegacy(t *testing.T) {
	out := strings.Join(treeRender(map[string]any{
		"snapshot": []any{
			map[string]any{"title": "root", "status": "ready", "depth": 0.0},
			map[string]any{"title": "child", "status": "ready", "depth": 1.0},
		},
	}, 80), "\n")
	for _, g := range []string{"├─", "└─"} {
		if strings.Contains(out, g) {
			t.Errorf("legacy render must not draw tree rails, found %q in:\n%s", g, out)
		}
	}
	// The legacy depth arrow (↳) marks the nested child instead.
	if !strings.Contains(out, "↳") {
		t.Errorf("legacy render should keep the ↳ depth arrow:\n%s", out)
	}
}
