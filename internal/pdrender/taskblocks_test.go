package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// renderBlock is a small helper: render one block at a width and return the
// ANSI-stripped joined output.
func renderBlock(reg *Registry, b Block, w int) string {
	return ansi.Strip(strings.Join(
		reg.Render(b, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}),
		"\n"))
}

// TestTaskBlocksNeverPanic asserts the four task-family renderers
// (task-list/tasks, task-detail, task-board, roadmap) degrade gracefully on
// empty, unresolved, degenerate, and out-of-range inputs. Portable-doc content is
// API-served and attacker-controllable, so a malformed task block must never take
// down the whole RenderDoc — it degrades to a placeholder / bare stack instead of
// panicking. Widths span a sub-MinWidth flat-degrade (10), a normal (60), and a
// wide (120) surface.
func TestTaskBlocksNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		// task-list / tasks: missing key (unresolved), query-only (unresolved),
		// wrong-typed snapshot, empty snapshot, all-empty row, non-object rows,
		// out-of-range depth, aggregated criteria, junk priority.
		{Type: "task-list", Attrs: map[string]any{}},
		{Type: "tasks", Attrs: map[string]any{}},
		{Type: "task-list", Attrs: map[string]any{"query": map[string]any{"type": "task"}}},
		{Type: "task-list", Attrs: map[string]any{"snapshot": "not-a-list"}},
		{Type: "task-list", Attrs: map[string]any{"snapshot": []any{}}},
		{Type: "task-list", Attrs: map[string]any{"snapshot": []any{map[string]any{}}}},
		{Type: "task-list", Attrs: map[string]any{"snapshot": []any{nil, 42, "x"}}},
		{Type: "task-list", Attrs: map[string]any{"snapshot": []any{
			map[string]any{"title": "deep", "status": "ready", "depth": 99},
			map[string]any{"title": "neg", "status": "done", "depth": -3},
			map[string]any{"title": "junk-pri", "status": "in_progress", "priority": "urgent",
				"criteria": map[string]any{"met": 0, "total": 0}},
		}}},
		// task-detail: missing key (no title → placeholder), empty task map,
		// title-only, block-attrs-as-task (no `task` wrapper), degenerate criteria
		// / children element types.
		{Type: "task-detail", Attrs: map[string]any{}},
		{Type: "task-detail", Attrs: map[string]any{"task": map[string]any{}}},
		{Type: "task-detail", Attrs: map[string]any{"task": map[string]any{"title": "only a title"}}},
		{Type: "task-detail", Attrs: map[string]any{"title": "inline task", "status": "done"}},
		{Type: "task-detail", Attrs: map[string]any{"task": map[string]any{
			"title":    "degenerate",
			"criteria": []any{nil, 42, map[string]any{}},
			"children": []any{nil, "x", map[string]any{}},
			"papers":   []any{nil, ""},
			"labels":   []any{nil, ""},
		}}},
		// task-board: missing key (unresolved), query-only, wrong-typed, empty,
		// all-empty row, unknown status (→ open, dropped from the fixed lanes),
		// non-object rows.
		{Type: "task-board", Attrs: map[string]any{}},
		{Type: "task-board", Attrs: map[string]any{"query": map[string]any{"type": "task"}}},
		{Type: "task-board", Attrs: map[string]any{"snapshot": "not-a-list"}},
		{Type: "task-board", Attrs: map[string]any{"snapshot": []any{}}},
		{Type: "task-board", Attrs: map[string]any{"snapshot": []any{map[string]any{}}}},
		{Type: "task-board", Attrs: map[string]any{"snapshot": []any{
			map[string]any{"title": "weird", "status": "not-a-status"},
		}}},
		{Type: "task-board", Attrs: map[string]any{"snapshot": []any{nil, 42, "x"}}},
		// roadmap: missing key (unresolved), query-only, wrong-typed, empty,
		// all-empty row, out-of-range left/width overflow, negatives, non-numeric
		// today, string scale cells.
		{Type: "roadmap", Attrs: map[string]any{}},
		{Type: "roadmap", Attrs: map[string]any{"query": map[string]any{"type": "task"}}},
		{Type: "roadmap", Attrs: map[string]any{"snapshot": "not-a-list"}},
		{Type: "roadmap", Attrs: map[string]any{"snapshot": []any{}}},
		{Type: "roadmap", Attrs: map[string]any{"snapshot": []any{map[string]any{}}}},
		{Type: "roadmap", Attrs: map[string]any{
			"today": "not-a-number",
			"scale": []any{"Q1", nil, 3, "Q4"},
			"snapshot": []any{
				map[string]any{"title": "overflow", "status": "done", "left": 100, "width": 80},
				map[string]any{"title": "neg", "status": "ready", "left": -20, "width": -5},
				map[string]any{"title": "phase", "phase_row": true, "status": "in_progress", "left": 50, "width": 200},
			},
		}},
		{Type: "roadmap", Attrs: map[string]any{
			"today": 100,
			"snapshot": []any{
				map[string]any{"title": "edge", "status": "blocked", "left": 99.9, "width": 0.1},
			},
		}},
	}

	for _, w := range []int{10, 60, 120} {
		for _, b := range cases {
			b := b
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("task block %q panicked (w=%d) on %v: %v", b.Type, w, b.Attrs, r)
					}
				}()
				_ = reg.Render(b, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor})
			}()
		}
	}
}

// TestTaskBlocksDegradeHonestly asserts the honest degrade lines: an unresolved
// (query-only) block shows the dim `[<label> — unresolved]` placeholder, while a
// present-but-empty snapshot shows the "No tasks yet." / "No roadmap items." copy
// — the two are DISTINCT states and must not be conflated.
func TestTaskBlocksDegradeHonestly(t *testing.T) {
	reg := testRegistry()
	cases := []struct {
		name       string
		block      Block
		wantSubstr string
	}{
		{"task-list unresolved", Block{Type: "task-list", Attrs: map[string]any{"query": map[string]any{}}}, "[task-list — unresolved]"},
		{"task-board unresolved", Block{Type: "task-board", Attrs: map[string]any{"query": map[string]any{}}}, "[task-board — unresolved]"},
		{"task-detail unresolved", Block{Type: "task-detail", Attrs: map[string]any{}}, "[task-detail — unresolved]"},
		{"roadmap unresolved", Block{Type: "roadmap", Attrs: map[string]any{"query": map[string]any{}}}, "[roadmap — unresolved]"},
		{"task-list empty", Block{Type: "task-list", Attrs: map[string]any{"snapshot": []any{}}}, "No tasks yet."},
		{"task-board empty", Block{Type: "task-board", Attrs: map[string]any{"snapshot": []any{}}}, "No tasks yet."},
		{"roadmap empty", Block{Type: "roadmap", Attrs: map[string]any{"snapshot": []any{}}}, "No roadmap items."},
	}
	for _, c := range cases {
		got := renderBlock(reg, c.block, 60)
		if !strings.Contains(got, c.wantSubstr) {
			t.Errorf("%s: expected %q, got:\n%s", c.name, c.wantSubstr, got)
		}
	}
}

// TestTaskGlyphsMatchLadder guards status-vocabulary drift: a done row must carry
// ✓, an in_progress row ⠋, a blocked row !, a ready row ○. The task widgets share
// the roleGlyph source with the status-legend, so this pins the two together — a
// manifest drift that changed the glyph would fail here AND in
// TestStatusLegendShowsFullLadder.
func TestTaskGlyphsMatchLadder(t *testing.T) {
	reg := testRegistry()
	got := renderBlock(reg, Block{Type: "task-list", Attrs: map[string]any{"snapshot": []any{
		map[string]any{"title": "d", "status": "done"},
		map[string]any{"title": "p", "status": "in_progress"},
		map[string]any{"title": "b", "status": "blocked"},
		map[string]any{"title": "r", "status": "ready"},
	}}}, 60)

	for status, glyph := range map[string]string{
		"done":        "✓",
		"in_progress": "⠋",
		"blocked":     "!",
		"ready":       "○",
	} {
		if !strings.Contains(got, glyph) {
			t.Errorf("task-list missing %q glyph %q, got:\n%s", status, glyph, got)
		}
	}
	// Cross-check the shared helper directly so the assertion is about the
	// vocabulary, not just this render.
	if g := glyphForRole(roleForStatus("done")); g != "✓" {
		t.Errorf("done role glyph drifted: got %q want ✓", g)
	}
	if g := glyphForRole(roleForStatus("in_progress")); g != "⠋" {
		t.Errorf("in_progress role glyph drifted: got %q want ⠋", g)
	}
}
