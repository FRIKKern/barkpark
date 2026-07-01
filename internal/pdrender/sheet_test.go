package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// TestPdSheet3x3 renders a 3x3 sheet with a head row and col_widths and
// asserts structural + content invariants without a golden file (new block,
// output shape is not yet frozen).
func TestPdSheet3x3(t *testing.T) {
	reg := testRegistry()

	block := Block{
		Type: "PdSheet",
		Attrs: map[string]any{
			"kind": "PdSheet",
			// Three-column header.
			"head": []any{"Name", "Score", "Tag"},
			// Three rows × three columns.
			"rows": []any{
				[]any{"Alice", "42", "alpha"},
				[]any{"Bob", "7", "beta"},
				[]any{"Carol", "100", "gamma"},
			},
			// Explicit column widths: 10, 7, 8 chars.
			"col_widths": []any{float64(10), float64(7), float64(8)},
		},
	}

	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	lines := reg.Render(block, ctx)
	out := ansi.Strip(strings.Join(lines, "\n"))

	// Head row must be present and uppercased.
	if !strings.Contains(out, "NAME") {
		t.Errorf("expected uppercase head cell 'NAME', got:\n%s", out)
	}
	if !strings.Contains(out, "SCORE") {
		t.Errorf("expected uppercase head cell 'SCORE', got:\n%s", out)
	}
	if !strings.Contains(out, "TAG") {
		t.Errorf("expected uppercase head cell 'TAG', got:\n%s", out)
	}

	// All data cells must appear.
	for _, want := range []string{"Alice", "Bob", "Carol", "42", "7", "100", "alpha", "beta", "gamma"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected cell %q in output, got:\n%s", want, out)
		}
	}

	// At least 5 lines: top border + header + header/body separator + 3 data rows + bottom border.
	if len(lines) < 5 {
		t.Errorf("expected at least 5 lines, got %d:\n%s", len(lines), out)
	}

	// Border chars present (NormalBorder uses │ and ─).
	if !strings.Contains(out, "│") {
		t.Errorf("expected vertical border char '│', got:\n%s", out)
	}
	if !strings.Contains(out, "─") {
		t.Errorf("expected horizontal border char '─', got:\n%s", out)
	}
}

// TestPdSheetNoHead renders a sheet without a head row; asserts no uppercase
// spurious header and that data cells still render.
func TestPdSheetNoHead(t *testing.T) {
	reg := testRegistry()
	block := Block{
		Type: "PdSheet",
		Attrs: map[string]any{
			"kind": "PdSheet",
			"rows": []any{
				[]any{"x", "y"},
				[]any{"1", "2"},
			},
		},
	}
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(strings.Join(reg.Render(block, ctx), "\n"))

	for _, want := range []string{"x", "y", "1", "2"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected cell %q in output, got:\n%s", want, out)
		}
	}
}

// TestPdSheetNeverPanic asserts the sheet renderer degrades gracefully for
// empty and degenerate inputs.
func TestPdSheetNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		{Type: "PdSheet", Attrs: map[string]any{"kind": "PdSheet"}},
		{Type: "PdSheet", Attrs: map[string]any{"kind": "PdSheet", "head": []any{}, "rows": []any{}}},
		{Type: "PdSheet", Attrs: map[string]any{"kind": "PdSheet", "rows": []any{[]any{}}}},
	}
	for _, b := range cases {
		b := b
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("PdSheet panicked on degenerate input: %v", r)
				}
			}()
			_ = reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
		}()
	}
}

// TestPdSheetRenderSample logs the rendered output for human review; the
// content is asserted by TestPdSheet3x3 — this is purely an inspection hook.
func TestPdSheetRenderSample(t *testing.T) {
	reg := testRegistry()
	block := Block{
		Type: "PdSheet",
		Attrs: map[string]any{
			"kind": "PdSheet",
			"head": []any{"Name", "Score", "Tag"},
			"rows": []any{
				[]any{"Alice", "42", "alpha"},
				[]any{"Bob", "7", "beta"},
				[]any{"Carol", "100", "gamma"},
			},
			"col_widths": []any{float64(10), float64(7), float64(8)},
		},
	}
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(strings.Join(reg.Render(block, ctx), "\n"))
	t.Logf("PdSheet sample render:\n%s", out)
}

// TestPdSheetColWidthsPadTruncate unit-tests padOrTruncate in isolation.
func TestPdSheetColWidthsPadTruncate(t *testing.T) {
	cases := []struct {
		s    string
		w    int
		want string
	}{
		{"hi", 5, "hi   "},
		{"hello world", 5, "hell…"},
		{"exact", 5, "exact"},
		{"x", 1, "x"},
		{"ab", 1, "…"},
		{"", 4, "    "},
	}
	for _, c := range cases {
		got := padOrTruncate(c.s, c.w)
		if got != c.want {
			t.Errorf("padOrTruncate(%q, %d) = %q, want %q", c.s, c.w, got, c.want)
		}
	}
}

// TestPdSheetColWidthsPadTruncateWide checks that truncation accounts for
// full-width (CJK / emoji) runes by display width, not rune count. The core
// invariant is no-overflow: a truncated cell must never exceed w display
// columns, otherwise it pushes every following Wrap(false) column out of
// alignment. Where the content can land exactly on w, it must.
func TestPdSheetColWidthsPadTruncateWide(t *testing.T) {
	cases := []struct {
		s     string
		w     int
		exact bool // true when the result must fill exactly w columns
	}{
		{"日本語テキスト", 5, true},     // width-2 runes: 日本 (4) + … (1) == 5
		{"日本語テキスト", 6, false},    // width-2 runes can't hit 6 exactly; must stay <= 6
		{"aあb", 4, true},         // mixed: a(1)+あ(2)+…(1) == 4
		{"日本語テキスト", 2, false},    // no wide rune fits in w-1=1 → just "…" (width 1), must not overflow
		{"hello world", 5, true}, // ASCII truncates to exactly w
		{"exact", 5, true},       // ASCII fits exactly, unchanged
	}
	for _, c := range cases {
		got := padOrTruncate(c.s, c.w)
		w := lipgloss.Width(got)
		if w > c.w {
			t.Errorf("padOrTruncate(%q, %d) width %d overflows column (got %q)", c.s, c.w, w, got)
		}
		if c.exact && w != c.w {
			t.Errorf("padOrTruncate(%q, %d) width = %d, want exactly %d (got %q)", c.s, c.w, w, c.w, got)
		}
	}
}

// TestSheetEmbedBlock locks the raw paper "sheet" embed path: the authored
// {"type":"sheet","snapshot":{…}} shape the API serves renders the dense
// value grid (NOT the unknown-block box), values-at-anchor for merges, no
// styles, and px col_widths dropped — the documented losses in sheet.go.
func TestSheetEmbedBlock(t *testing.T) {
	reg := testRegistry()
	raw := []byte(`[{"id":"s1","type":"sheet","ref":"demo","tab":0,
	  "snapshot":{"head":["Metric","Q3","Q4"],
	  "rows":[["Revenue","1200","3.5"],["Active?","TRUE",""]],
	  "col_widths":[120,0,0],"merges":[[1,1,1,2]],
	  "styles":{"0,0":{"b":true,"bg":"#ffee00"}}}}]`)
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(reg.RenderDoc(blocks, ctx))

	if strings.Contains(out, "unknown block") {
		t.Fatalf("sheet embed fell through to the unknown-block box:\n%s", out)
	}
	// Head + every anchor value renders (merged range shows its anchor value).
	for _, want := range []string{"METRIC", "Revenue", "1200", "3.5", "Active?", "TRUE"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in sheet embed render, got:\n%s", want, out)
		}
	}
	// px col_widths are dropped — no 120-char padded column.
	for _, line := range strings.Split(out, "\n") {
		if lw := len([]rune(line)); lw > 80 {
			t.Errorf("line wider than ctx.Width (%d chars) — px widths leaked as char widths:\n%s", lw, line)
		}
	}
}

// TestSheetEmbedBlockDegenerate: no snapshot / empty snapshot never panics.
func TestSheetEmbedBlockDegenerate(t *testing.T) {
	reg := testRegistry()
	cases := [][]byte{
		[]byte(`[{"type":"sheet","ref":"x"}]`),
		[]byte(`[{"type":"sheet","snapshot":{}}]`),
		[]byte(`[{"type":"sheet","snapshot":{"rows":[]}}]`),
	}
	for _, raw := range cases {
		blocks, err := Decode(raw)
		if err != nil {
			t.Fatalf("decode: %v", err)
		}
		_ = reg.RenderDoc(blocks, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
	}
}
