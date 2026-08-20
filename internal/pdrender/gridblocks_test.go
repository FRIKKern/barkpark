package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestGridBlocksNeverPanic asserts the notes / pipeline / cards / status-legend
// renderers degrade gracefully on empty and degenerate inputs. Portable-doc
// content is API-served and attacker-controllable, so a malformed grid block must
// never take down the whole RenderDoc — it degrades to a blank line / bare stack
// instead of panicking.
func TestGridBlocksNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		// notes: missing key, wrong-typed key, empty list, all-empty item,
		// non-object elements.
		{Type: "notes", Attrs: map[string]any{}},
		{Type: "notes", Attrs: map[string]any{"items": "not-a-list"}},
		{Type: "notes", Attrs: map[string]any{"items": []any{}}},
		{Type: "notes", Attrs: map[string]any{"items": []any{map[string]any{}}}},
		{Type: "notes", Attrs: map[string]any{"items": []any{nil, 42, "x"}}},
		// pipeline: missing key, wrong-typed key, empty list, all-empty node,
		// non-object elements.
		{Type: "pipeline", Attrs: map[string]any{}},
		{Type: "pipeline", Attrs: map[string]any{"nodes": "not-a-list"}},
		{Type: "pipeline", Attrs: map[string]any{"nodes": []any{}}},
		{Type: "pipeline", Attrs: map[string]any{"nodes": []any{map[string]any{}}}},
		{Type: "pipeline", Attrs: map[string]any{"nodes": []any{nil, 42, "x"}}},
		// cards: missing key, wrong-typed key, empty list, all-empty item,
		// unknown tone, non-object elements.
		{Type: "cards", Attrs: map[string]any{}},
		{Type: "cards", Attrs: map[string]any{"items": "not-a-list"}},
		{Type: "cards", Attrs: map[string]any{"items": []any{}}},
		{Type: "cards", Attrs: map[string]any{"items": []any{map[string]any{}}}},
		{Type: "cards", Attrs: map[string]any{"items": []any{map[string]any{"title": "t", "tone": "bogus"}}}},
		{Type: "cards", Attrs: map[string]any{"items": []any{nil, 42, "x"}}},
		// status-legend: ignores attrs entirely, so an empty / junk map is fine.
		{Type: "status-legend", Attrs: map[string]any{}},
		{Type: "status-legend", Attrs: map[string]any{"items": "ignored"}},
	}
	// Exercise a range of widths, including a sub-MinWidth width that forces the
	// cards flat-degrade branch and the note bar-drop branch, plus a wide one.
	for _, w := range []int{10, 40, 120} {
		for _, b := range cases {
			b := b
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("grid block %q panicked (w=%d) on %v: %v", b.Type, w, b.Attrs, r)
					}
				}()
				_ = reg.Render(b, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor})
			}()
		}
	}
}

// TestNotesRendersNormally checks a well-formed notes block stacks its items as
// `▌` definition rows carrying each item's label / lead / text, and that an item
// with an omitted lead still renders.
func TestNotesRendersNormally(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "notes", Attrs: map[string]any{"items": []any{
		map[string]any{"label": "L1", "lead": "leadone", "text": "bodyone"},
		map[string]any{"label": "L2", "text": "bodytwo"}, // no lead
	}}}
	out := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"L1", "leadone", "bodyone", "L2", "bodytwo", "▌"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected notes output to contain %q, got:\n%s", want, out)
		}
	}
}

// TestPipelineRendersNormally checks a well-formed pipeline stacks its nodes as
// stage cells joined by a dim `↓` connector, with exactly one connector between
// two nodes (never a dangling one).
func TestPipelineRendersNormally(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "pipeline", Attrs: map[string]any{"nodes": []any{
		map[string]any{"kind": "in", "title": "First", "source": "cli"},
		map[string]any{"kind": "out", "title": "Second"},
	}}}
	out := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"IN", "First", "source: cli", "OUT", "Second", "↓"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected pipeline output to contain %q, got:\n%s", want, out)
		}
	}
	if n := strings.Count(out, "↓"); n != 1 {
		t.Errorf("expected exactly one ↓ connector between two nodes, got %d:\n%s", n, out)
	}
}

// TestCardsRendersNormally checks a well-formed cards block draws one rounded
// tone-bordered box per item at a wide width, and flat-degrades (no border, body
// kept) below MinWidth.
func TestCardsRendersNormally(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "cards", Attrs: map[string]any{"items": []any{
		map[string]any{"title": "Alpha", "text": "alpha body", "tone": "info"},
		map[string]any{"title": "Bravo", "text": "bravo body", "tone": "danger"},
	}}}

	boxed := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	for _, want := range []string{"Alpha", "alpha body", "Bravo", "bravo body", "╭", "╰"} {
		if !strings.Contains(boxed, want) {
			t.Fatalf("expected cards output to contain %q, got:\n%s", want, boxed)
		}
	}
	// Two items → two top border corners.
	if n := strings.Count(boxed, "╭"); n != 2 {
		t.Errorf("expected two tone-bordered boxes, got %d top corners:\n%s", n, boxed)
	}

	// Sub-MinWidth width forces the flat degrade: content survives, box does not.
	flat := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 10, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(flat, "Alpha") || !strings.Contains(flat, "Bravo") {
		t.Fatalf("expected flat-degraded cards to keep their content, got:\n%s", flat)
	}
	if strings.Contains(flat, "╭") || strings.Contains(flat, "╰") {
		t.Errorf("narrow cards must flat-degrade (no rounded border), got:\n%s", flat)
	}
}

// TestGridOptIn pins the corpus-freeze guarantee: a notes/cards/pipeline widget
// only enters the horizontal Flex path when it carries layout:{mode:"grid"}.
// WITHOUT a layout (the entire legacy corpus) → false → verbatim vertical stack,
// byte-identical to before the Flex path existed (why sample_m5 stays frozen).
// WITH it → true → side-by-side eligible. Any other layout shape stays false.
func TestGridOptIn(t *testing.T) {
	cases := []struct {
		name  string
		attrs map[string]any
		want  bool
	}{
		{"with layout mode grid → opt in", map[string]any{"layout": map[string]any{"mode": "grid"}}, true},
		{"no layout at all → stacks", map[string]any{}, false},
		{"nil attrs → stacks", nil, false},
		{"layout present but not grid → stacks", map[string]any{"layout": map[string]any{"mode": "stack"}}, false},
		{"layout not an object → stacks", map[string]any{"layout": "grid"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := gridOptIn(Block{Attrs: tc.attrs}); got != tc.want {
				t.Errorf("gridOptIn(%v) = %v, want %v", tc.attrs, got, tc.want)
			}
		})
	}
}

// TestStatusLegendShowsFullLadder pins the status-legend to the fixed 8-rung
// ladder — the six lifecycle states plus the two thought states (considering /
// researching) at the ladder bottom (charter D9/D12) — so a drift in
// design/status-manifest.json (or the inlined statusLadder copy) trips this test.
func TestStatusLegendShowsFullLadder(t *testing.T) {
	reg := testRegistry()
	out := ansi.Strip(strings.Join(
		reg.Render(Block{Type: "status-legend"}, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}),
		"\n"))

	// All eight role names (the "white ladder" order + the two thought states).
	for _, name := range []string{"open", "ready", "progress", "blocked", "done", "cancel", "considering", "researching"} {
		if !strings.Contains(out, name) {
			t.Errorf("status-legend missing role %q, got:\n%s", name, out)
		}
	}
	// All eight glyphs (○ appears for both open and ready → at least two).
	for _, glyph := range []string{"○", "⠋", "!", "✓", "✕", "◌", "◎"} {
		if !strings.Contains(out, glyph) {
			t.Errorf("status-legend missing glyph %q, got:\n%s", glyph, out)
		}
	}
	if n := strings.Count(out, "○"); n < 2 {
		t.Errorf("expected the ○ glyph for both open and ready rungs, got %d:\n%s", n, out)
	}
	// Exactly eight rungs. Each row is `glyph  name  — meaning`, so the meaning
	// separator is an em-dash preceded by TWO spaces (a meaning body may itself
	// contain a single-space " — ", so match the wider "  — " to count only rows).
	if n := strings.Count(out, "  — "); n != 8 {
		t.Errorf("expected eight ladder rungs (eight meaning separators), got %d:\n%s", n, out)
	}
}
