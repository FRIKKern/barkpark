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

// boardFixture builds a task-board block spanning all four lanes.
func boardFixture() Block {
	return Block{Type: "task-board", Attrs: map[string]any{"snapshot": []any{
		map[string]any{"title": "claim it", "status": "ready", "priority": "2"},
		map[string]any{"title": "in flight", "status": "in_progress", "priority": "1"},
		map[string]any{"title": "await review", "status": "blocked", "priority": "0", "blocked_by": 1},
		map[string]any{"title": "shipped", "status": "done", "priority": "1"},
	}}}
}

// TestTaskBoardSideBySide proves the board draws bordered lanes SIDE-BY-SIDE when
// every lane clears MinWidth (w120: 4 lanes, cellW=(120-6)/4=28), and STACKS them
// (the verbatim fallback) when they cannot (w40: cellW=(40-6)/4=8).
func TestTaskBoardSideBySide(t *testing.T) {
	reg := testRegistry()
	b := boardFixture()

	wide := strings.Split(renderBlock(reg, b, 120), "\n")
	// All four lane headers align on one row when the boxes sit side-by-side.
	if !someLineHasBoth(wide, "Ready", "Done") {
		t.Fatalf("w120: expected lanes side-by-side (Ready and Done on one line), got:\n%s", strings.Join(wide, "\n"))
	}
	if lineIndexOf(wide, "╭") < 0 {
		t.Fatalf("w120: expected rounded lane borders, got:\n%s", strings.Join(wide, "\n"))
	}

	narrow := strings.Split(renderBlock(reg, b, 40), "\n")
	if someLineHasBoth(narrow, "Ready", "Done") {
		t.Fatalf("w40: expected lanes STACKED (cellW 8 < MinWidth), got:\n%s", strings.Join(narrow, "\n"))
	}
}

// TestTaskListMomentumBar proves the task-list carries a proportional ▓/░ bar
// directly under the momentum counts (the house-standard pairing).
func TestTaskListMomentumBar(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "task-list", Attrs: map[string]any{"snapshot": []any{
		map[string]any{"title": "a", "status": "done"},
		map[string]any{"title": "b", "status": "done"},
		map[string]any{"title": "c", "status": "ready"},
		map[string]any{"title": "d", "status": "in_progress"},
	}}}
	lines := strings.Split(renderBlock(reg, b, 80), "\n")
	barIdx := -1
	for i, ln := range lines {
		if strings.Contains(ln, "▓") && strings.Contains(ln, "░") {
			barIdx = i
			break
		}
	}
	if barIdx < 0 {
		t.Fatalf("expected a ▓/░ momentum bar, got:\n%s", strings.Join(lines, "\n"))
	}
	// The bar sits directly under the momentum counts (the "%" line).
	if barIdx == 0 || !strings.Contains(lines[barIdx-1], "%") {
		t.Fatalf("momentum bar should sit directly under the counts line, got:\n%s", strings.Join(lines, "\n"))
	}
	// 2 of 4 done → the bar is ~half filled: at w80 that is 40 ▓ cells.
	fill := strings.Count(lines[barIdx], "▓")
	if fill != 40 {
		t.Errorf("expected 40 ▓ cells (2/4 of 80), got %d in:\n%s", fill, lines[barIdx])
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

// TestTaskDetailTimeline is the au-w5 content-parity guard: the task-detail
// renderer emits the lifecycle timeline (one glyph+label cell per transition,
// joined by a dim ` → ` arrow) mirroring the Elixir emitter's detail_timeline/1
// — and emits NOTHING when the task carries no `timeline` key (conditional-nil,
// which keeps timeline-less fixtures like sample_m6 byte-frozen). Asserting the
// specific glyphs + arrow (not mere non-emptiness) makes both halves load-bearing.
func TestTaskDetailTimeline(t *testing.T) {
	reg := testRegistry()

	// With a timeline: the row carries each ladder glyph, its label, and the
	// dim arrow separator between cells.
	withTL := renderBlock(reg, Block{Type: "task-detail", Attrs: map[string]any{"task": map[string]any{
		"title": "has a timeline",
		"timeline": []any{
			map[string]any{"status": "open", "label": "Filed"},
			map[string]any{"status": "ready", "label": "Groomed"},
			map[string]any{"status": "in_progress", "label": "Claimed"},
			map[string]any{"status": "blocked", "label": "Waiting"},
			map[string]any{"status": "done", "label": "Shipped"},
		},
	}}}, 120)
	if !strings.Contains(withTL, "→") {
		t.Fatalf("timeline row missing the ` → ` arrow separator, got:\n%s", withTL)
	}
	for _, want := range []string{
		"○ Filed", "○ Groomed", "⠋ Claimed", "! Waiting", "✓ Shipped",
	} {
		if !strings.Contains(withTL, want) {
			t.Errorf("timeline row missing glyph+label %q, got:\n%s", want, withTL)
		}
	}

	// Without a timeline: no arrow row at all (conditional-nil). A task-detail
	// uses ` → ` nowhere else, so its absence proves the timeline emitted nothing.
	noTL := renderBlock(reg, Block{Type: "task-detail", Attrs: map[string]any{"task": map[string]any{
		"title":       "no timeline",
		"description": "just a description, no lifecycle history",
	}}}, 120)
	if strings.Contains(noTL, "→") {
		t.Errorf("task-detail without a `timeline` key must emit no arrow row, got:\n%s", noTL)
	}

	// And the underlying helper returns nil (not an empty-string line) when the
	// key is absent — the precise conditional-nil contract.
	ctx := RenderCtx{Width: 120, Theme: DarkTheme(), Profile: NoColor}
	if got := detailTimeline(map[string]any{"title": "x"}, ctx, 120); got != nil {
		t.Errorf("detailTimeline with no `timeline` key must return nil, got %#v", got)
	}
}

// TestTaskBoardThoughtStateLanes is the ROW-LOSS guard: a considering row and a
// researching row must reach the board and land in lanes of their OWN.
//
// The bug it pins (mob-zb-bl-tui-board-thought-lanes): tlv-s3 widened
// gridblocks.go's roleForStatus so `considering`/`researching` resolve to their
// own ladder roles, but its file list omitted taskblocks.go — boardColumns
// stayed the 5-entry set and Render collects lanes by iterating boardColumns
// ALONE. So those rows bucketed into roles nobody collects and were SILENTLY
// DROPPED (before the widening they at least fell back to `open`), making the
// TUI board strictly worse than it had been.
//
// MUTATION PROOF: revert boardColumns to {"open","ready","progress","blocked",
// "done"} and this test goes RED on the dropped titles; restore the 7 and it is
// GREEN.
func TestTaskBoardThoughtStateLanes(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "task-board", Attrs: map[string]any{"snapshot": []any{
		map[string]any{"title": "weighing it", "status": "considering"},
		map[string]any{"title": "digging in", "status": "researching"},
		map[string]any{"title": "shipped", "status": "done"},
	}}}

	// Narrow enough that the lanes STACK, so every title renders verbatim.
	got := renderBlock(reg, b, 40)
	for _, want := range []string{"weighing it", "digging in", "shipped"} {
		if !strings.Contains(got, want) {
			t.Errorf("row %q was DROPPED from the board, got:\n%s", want, got)
		}
	}
	// Each thought state gets its OWN lane header (not folded into another).
	for _, want := range []string{"Considering", "Researching", "Done"} {
		if !strings.Contains(got, want) {
			t.Errorf("expected a %q lane header, got:\n%s", want, got)
		}
	}
	// And the thought-state glyphs come from the shared roleGlyph source.
	for role, glyph := range map[string]string{"considering": "◌", "researching": "◎"} {
		if !strings.Contains(got, glyph) {
			t.Errorf("expected the %s glyph %q on the board, got:\n%s", role, glyph, got)
		}
	}
}

// TestBoardColumnsMatchManifestLadder pins boardColumns to the manifest ladder
// minus `cancel` — the SAME set react's BOARD_ROLES and Elixir's board_roles/0
// carry (open ready progress blocked done considering researching), in the same
// order. A manifest rung added without widening the board reds here.
func TestBoardColumnsMatchManifestLadder(t *testing.T) {
	var want []string
	for _, role := range statusLadder {
		if role == "cancel" {
			continue
		}
		want = append(want, role)
	}
	if strings.Join(boardColumns, ",") != strings.Join(want, ",") {
		t.Errorf("boardColumns = %v, want the manifest ladder minus cancel: %v", boardColumns, want)
	}
}
