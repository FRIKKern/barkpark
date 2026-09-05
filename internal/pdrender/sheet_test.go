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

	assertNoUnknownBlock(t, "sheet embed snapshot", out)
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

// TestSheetEmbedTruncationNote: a clipped snapshot (`"truncated": true`) must
// append the muted partial-data note so a TUI reader is not silently missing
// rows — parity with walk.ex `sheet_truncation_note/3` and web `truncationNotice`.
// The note is absent when the flag is not set.
func TestSheetEmbedTruncationNote(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}

	truncated := []byte(`[{"type":"sheet","ref":"demo",
	  "snapshot":{"head":["Metric"],
	  "rows":[["r1"],["r2"],["r3"]],"truncated":true,"total_rows":30000}}]`)
	blocks, err := Decode(truncated)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	out := ansi.Strip(reg.RenderDoc(blocks, ctx))
	// Byte-matched to walk.ex/web; shown count is the rendered row count (3).
	want := "Sheet truncated — showing the first 3 rows"
	if !strings.Contains(out, want) {
		t.Errorf("expected truncation note %q, got:\n%s", want, out)
	}

	// Same grid without the flag renders no note.
	clean := []byte(`[{"type":"sheet","ref":"demo",
	  "snapshot":{"head":["Metric"],"rows":[["r1"],["r2"],["r3"]]}}]`)
	blocks, err = Decode(clean)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	out = ansi.Strip(reg.RenderDoc(blocks, ctx))
	if strings.Contains(out, "Sheet truncated") {
		t.Errorf("did not expect a truncation note without the flag, got:\n%s", out)
	}
}

// TestPdSheetColWidthsCapped: an author-controlled col_widths entry must not
// drive an unbounded strings.Repeat allocation in padOrTruncate. A huge width
// is clamped at read time and rendering completes without panic/OOM.
func TestPdSheetColWidthsCapped(t *testing.T) {
	var sr sheetRenderer
	widths := sr.readColWidths(map[string]any{
		"col_widths": []any{"1000000000000000000"},
	})
	if len(widths) != 1 {
		t.Fatalf("expected 1 width, got %d: %v", len(widths), widths)
	}
	if widths[0] > maxColWidth {
		t.Fatalf("col width not clamped: got %d, want <= %d", widths[0], maxColWidth)
	}

	// End-to-end: the crafted block must render without panicking.
	reg := testRegistry()
	block := Block{
		Type: "PdSheet",
		Attrs: map[string]any{
			"kind":       "PdSheet",
			"head":       []any{"A"},
			"rows":       []any{[]any{"x"}},
			"col_widths": []any{"1000000000000000000"},
		},
	}
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("PdSheet panicked on huge col_widths: %v", r)
			}
		}()
		_ = reg.Render(block, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})
	}()
}

// TestScaleLadderCapsSpan: an attacker-controlled scale.max must not drive an
// unbounded allocation/loop. A huge span returns promptly with a bounded,
// collapsed "min … max" output instead of enumerating every step.
func TestScaleLadderCapsSpan(t *testing.T) {
	q := map[string]any{"scale": map[string]any{"min": 1, "max": 1000000000}}
	got := scaleLadder(q, lipgloss.NewStyle())
	if len(got) >= 100 {
		t.Fatalf("scaleLadder did not cap huge span: len=%d got=%q", len(got), got)
	}
}

// TestPadOrTruncateZeroWidth locks the padOrTruncate `if w <= 0 { return s }`
// guard (sheet.go). The golden suite renders sheets only at widths >= 40, and
// col_widths flow from those, so a zero/negative target column is never
// exercised there — yet PdSheet col_widths are attacker/manifest-supplied and
// pdrender is a standalone CLI renderer, so w<=0 is reachable.
//
// RED-ON-REMOVAL PROOF (observably different, not just "safe either way"): with
// the guard, w=0 returns the input UNCHANGED. Without the guard the switch falls
// through — vis>w (any non-empty string has vis>0) enters the `if w <= 1` branch
// and returns the ellipsis "…". So deleting the guard silently rewrites
// padOrTruncate("x", 0) from "x" to "…". This test pins the guarded behavior so
// that regression is caught.
func TestPadOrTruncateZeroWidth(t *testing.T) {
	cases := []struct {
		name string
		s    string
		w    int
		want string
	}{
		{"zero-width-single-rune", "x", 0, "x"},        // guarded: unchanged; unguarded → "…"
		{"zero-width-multi-rune", "hello", 0, "hello"}, // guarded: unchanged; unguarded → "…"
		{"zero-width-empty", "", 0, ""},                // unchanged
		{"negative-width", "hello", -5, "hello"},       // w<0 also short-circuits, unchanged
		{"negative-width-single", "x", -1, "x"},        // unchanged
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := padOrTruncate(tc.s, tc.w); got != tc.want {
				t.Fatalf("padOrTruncate(%q, %d) = %q, want %q — the `if w <= 0` guard in sheet.go is missing or broken (unguarded, w<=0 falls through to the w<=1 ellipsis branch and returns %q)", tc.s, tc.w, got, tc.want, "…")
			}
		})
	}
}
