package pdrender

import (
	"strings"
	"testing"
)

// gridPara builds a paragraph Block with the given text and optional grid-cell
// attrs (span/order) merged onto its Attrs.
func gridPara(text string, extra map[string]any) Block {
	attrs := map[string]any{
		"type":    "paragraph",
		"content": []any{map[string]any{"type": "text", "value": text}},
	}
	for k, v := range extra {
		attrs[k] = v
	}
	return Block{Type: "paragraph", Attrs: attrs}
}

// gridSection builds a section Block in grid mode with the given tracks and
// children (children set directly, as decode.go would).
func gridSection(title string, tracks int, kids ...Block) Block {
	return Block{
		Type: "section",
		Attrs: map[string]any{
			"type":   "section",
			"title":  title,
			"layout": map[string]any{"mode": "grid", "tracks": tracks},
		},
		Children: kids,
	}
}

// someLineHasBoth reports whether one output line contains both substrings.
func someLineHasBoth(lines []string, a, b string) bool {
	for _, ln := range lines {
		if strings.Contains(ln, a) && strings.Contains(ln, b) {
			return true
		}
	}
	return false
}

// lineIndexOf returns the index of the first line containing substr (-1 if none).
func lineIndexOf(lines []string, substr string) int {
	for i, ln := range lines {
		if strings.Contains(ln, substr) {
			return i
		}
	}
	return -1
}

// TestSectionGridSideBySide proves a two-track grid section lays its cells
// side-by-side on one line when each cell clears MinWidth (w80: cellW=(80-2)/2=39),
// and degrades to a stacked one-per-line layout when it does not (w40:
// cellW=(40-2)/2=19 < 20). This is the MinWidth-boundary assert.
func TestSectionGridSideBySide(t *testing.T) {
	reg := testRegistry()
	sec := gridSection("Grid", 2,
		gridPara("alphaword", nil),
		gridPara("bravoword", nil),
	)

	wide := strings.Split(renderBlock(reg, sec, 80), "\n")
	if !someLineHasBoth(wide, "alphaword", "bravoword") {
		t.Fatalf("w80: expected alphaword and bravoword on ONE line (side-by-side), got:\n%s", strings.Join(wide, "\n"))
	}

	narrow := strings.Split(renderBlock(reg, sec, 40), "\n")
	if someLineHasBoth(narrow, "alphaword", "bravoword") {
		t.Fatalf("w40: expected alphaword and bravoword STACKED (cellW 19 < MinWidth), got:\n%s", strings.Join(narrow, "\n"))
	}
	if lineIndexOf(narrow, "alphaword") < 0 || lineIndexOf(narrow, "bravoword") < 0 {
		t.Fatalf("w40 stacked fallback dropped a cell, got:\n%s", strings.Join(narrow, "\n"))
	}
}

// TestSectionGridSpanFillsRow proves a span:2 child in a 2-track grid consumes
// both slots and sits alone on its own row (never sharing a line with a
// single-slot cell).
func TestSectionGridSpanFillsRow(t *testing.T) {
	reg := testRegistry()
	sec := gridSection("Grid", 2,
		gridPara("leftcell", nil),
		gridPara("rightcell", nil),
		gridPara("wideband", map[string]any{"span": 2}),
	)
	lines := strings.Split(renderBlock(reg, sec, 80), "\n")

	// leftcell and rightcell share row 1.
	if !someLineHasBoth(lines, "leftcell", "rightcell") {
		t.Fatalf("expected leftcell+rightcell on one row, got:\n%s", strings.Join(lines, "\n"))
	}
	// The span:2 band must NOT share a line with either single cell.
	if someLineHasBoth(lines, "wideband", "leftcell") || someLineHasBoth(lines, "wideband", "rightcell") {
		t.Fatalf("span:2 band must fill its own row, got:\n%s", strings.Join(lines, "\n"))
	}
}

// TestSectionGridOrder proves the CSS-order reorder: a child with order:-1
// renders BEFORE an earlier-in-source child with no order (default 0).
func TestSectionGridOrder(t *testing.T) {
	reg := testRegistry()
	sec := gridSection("Grid", 2,
		gridPara("sourcefirst", nil),
		gridPara("orderedfirst", map[string]any{"order": -1}),
	)
	lines := strings.Split(renderBlock(reg, sec, 80), "\n")
	oi := lineIndexOf(lines, "orderedfirst")
	si := lineIndexOf(lines, "sourcefirst")
	if oi < 0 || si < 0 {
		t.Fatalf("missing a cell, got:\n%s", strings.Join(lines, "\n"))
	}
	// They share row 1 (both single-slot), so assert the WITHIN-line order: the
	// ordered cell's column comes first.
	row := lines[oi]
	if strings.Index(row, "orderedfirst") > strings.Index(row, "sourcefirst") {
		t.Fatalf("order:-1 child should lead, got line:\n%s", row)
	}
}

// TestSectionStackByteIdentical is the PARITY TRIPWIRE: a section with NO layout
// key and a section with an explicit {"mode":"stack"} layout must render
// byte-for-byte identically at every width — the grid branch fires ONLY on
// mode=="grid", so every legacy/explicit-stack section is untouched (mirrors
// compose.ex's byte-identical guarantee). If the grid branch ever leaks into the
// stack path this reds.
func TestSectionStackByteIdentical(t *testing.T) {
	reg := testRegistry()
	kids := []Block{
		gridPara("first child text that is long enough to wrap at the narrow widths", nil),
		gridPara("second child text", nil),
	}
	noLayout := Block{Type: "section", Attrs: map[string]any{"type": "section", "title": "S"}, Children: kids}
	stack := Block{Type: "section", Attrs: map[string]any{"type": "section", "title": "S",
		"layout": map[string]any{"mode": "stack"}}, Children: kids}

	for _, w := range goldenWidths {
		a := renderBlock(reg, noLayout, w)
		b := renderBlock(reg, stack, w)
		if a != b {
			t.Errorf("w%d: {mode:stack} diverged from no-layout section — grid branch leaked into the stack path\n--- no-layout ---\n%s\n--- mode:stack ---\n%s", w, a, b)
		}
	}
}

// TestSectionGridDegradesToStack proves a grid whose per-cell width falls below
// MinWidth degrades to the SAME output as an explicit stack section (the
// verbatim fallback), so a narrow surface stays byte-identical to today.
func TestSectionGridDegradesToStack(t *testing.T) {
	reg := testRegistry()
	kids := []Block{gridPara("cell one text", nil), gridPara("cell two text", nil)}
	grid := Block{Type: "section", Attrs: map[string]any{"type": "section", "title": "S",
		"layout": map[string]any{"mode": "grid", "tracks": 2}}, Children: kids}
	stack := Block{Type: "section", Attrs: map[string]any{"type": "section", "title": "S"}, Children: kids}

	// w40: cellW=(40-2)/2=19 < MinWidth → grid must equal the stack render.
	if g, s := renderBlock(reg, grid, 40), renderBlock(reg, stack, 40); g != s {
		t.Errorf("w40 grid degrade should equal the stack path\n--- grid ---\n%s\n--- stack ---\n%s", g, s)
	}
}

// TestSectionGridTracksDefault proves gridTracks mirrors compose.ex grid_tracks:
// positive int, stringy positive int, else default 2.
func TestSectionGridTracksDefault(t *testing.T) {
	cases := []struct {
		in   any
		want int
	}{
		{3, 3}, {float64(4), 4}, {"2", 2}, {"5", 5},
		{0, 2}, {-1, 2}, {"nope", 2}, {"3px", 2}, {nil, 2}, {2.5, 2},
	}
	for _, c := range cases {
		if got := gridTracks(c.in); got != c.want {
			t.Errorf("gridTracks(%#v) = %d, want %d", c.in, got, c.want)
		}
	}
}
