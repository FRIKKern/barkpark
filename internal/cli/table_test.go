package cli

import (
	"bytes"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/mattn/go-runewidth"
)

func TestTruncateCell(t *testing.T) {
	cases := []struct {
		name string
		in   string
		max  int
		want string
	}{
		{"short unchanged", "short", 60, "short"},
		{"exactly max unchanged", strings.Repeat("x", 60), 60, strings.Repeat("x", 60)},
		{"over max capped", strings.Repeat("x", 61), 60, strings.Repeat("x", 57) + "..."},
		// Rune-safe: the cap counts DISPLAY RUNES; the first 7 runes of a string
		// that starts with 3 multibyte chars are æøå + 4 x's, then "...".
		{"multibyte rune-safe", "æøå" + strings.Repeat("x", 100), 10, "æøåxxxx..."},
		// max < 4 has no room for "..."; return the first max runes bare, never
		// a negative slice bound (which would panic).
		{"max zero", "hello", 0, ""},
		{"max one no ellipsis", "hello", 1, "h"},
		{"max two no ellipsis", "hello", 2, "he"},
		{"max three no ellipsis", "hello", 3, "hel"},
		// Bare-cap path stays rune-safe: cuts on the rune boundary, not mid-byte.
		{"multibyte no ellipsis", "æøåé", 2, "æø"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := truncateCell(c.in, c.max)
			if got != c.want {
				t.Errorf("truncateCell(%q, %d) = %q, want %q", c.in, c.max, got, c.want)
			}
			if !utf8.ValidString(got) {
				t.Errorf("truncateCell produced invalid UTF-8: %q", got)
			}
		})
	}
}

// A cell of 40 CJK ideographs is 40 runes but 80 terminal DISPLAY cells. The old
// rune-count cap left it at 40 runes / 80 cells — blowing the very column-width
// budget the cap exists to enforce. The display-width cap keeps the result within
// cellMaxRunes cells (and rune-safe / valid UTF-8).
func TestTruncateCellBoundsDisplayWidth(t *testing.T) {
	got := truncateCell(strings.Repeat("中", 40), cellMaxRunes)
	if w := runewidth.StringWidth(got); w > cellMaxRunes {
		t.Errorf("CJK cell is %d display cells, exceeds the %d-cell budget: %q", w, cellMaxRunes, got)
	}
	if !utf8.ValidString(got) {
		t.Errorf("truncateCell produced invalid UTF-8: %q", got)
	}
}

func TestCellStringSanitizesControlChars(t *testing.T) {
	// A document field like "Line1\nLine2\twith\x1b[31m escape" must render as one
	// clean cell: newline/tab/CR collapse to a space, other control bytes (ESC,
	// DEL) drop out entirely — no line break, no raw terminal escape.
	got := cellString("Line1\nLine2\twith\x1b[31mred\rend\x7f")
	if strings.ContainsAny(got, "\n\r\t\x1b\x7f") {
		t.Errorf("cellString left control bytes in %q", got)
	}
	if got != "Line1 Line2 with[31mred end" {
		t.Errorf("cellString sanitized to %q, want %q", got, "Line1 Line2 with[31mred end")
	}
	// The default branch (non-string scalar) inherits the same sanitizing via
	// fmt.Sprintf. A stringer that emits control bytes must be scrubbed too.
	if s := cellString(ctrlStringer{}); strings.ContainsAny(s, "\n\x1b") {
		t.Errorf("default branch left control bytes in %q", s)
	}
}

type ctrlStringer struct{}

func (ctrlStringer) String() string { return "a\nb\x1bc" }

func TestRenderRowsTruncatesLongStringCells(t *testing.T) {
	// A long STRING value used to stretch its column to the full value width
	// (only nested map/array cells were capped). The table must stay bounded.
	long := strings.Repeat("a", 100)
	rows := []any{
		map[string]any{"title": long, "slug": "ok"},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderRows(w, rows, nil)
	out := stdout.String()

	if strings.Contains(out, long) {
		t.Errorf("100-char string cell was not truncated:\n%s", out)
	}
	if !strings.Contains(out, strings.Repeat("a", 57)+"...") {
		t.Errorf("expected the cell capped at 57 runes + \"...\":\n%s", out)
	}
	// No output line should exceed a sane bound (cap + short 'slug' col + sep).
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if utf8.RuneCountInString(line) > 80 {
			t.Errorf("table line exceeds 80 runes (%d), truncation not bounding it:\n%s",
				utf8.RuneCountInString(line), line)
		}
	}
}

// A bare array of scalars (a `["a","b"]` list response) must render as a single
// "value" column — before the fix pickColumns found no object keys, so the loop
// produced an empty header + blank rows and silently dropped the values.
func TestRenderRowsScalarArray(t *testing.T) {
	rows := []any{"alpha", "beta", "gamma"}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderRows(w, rows, nil)
	out := stdout.String()

	for _, want := range []string{"value", "alpha", "beta", "gamma"} {
		if !strings.Contains(out, want) {
			t.Errorf("scalar-array table missing %q:\n%s", want, out)
		}
	}
}

// The full renderTable entry: a top-level scalar-array payload renders its values.
func TestRenderTableTopLevelScalarArray(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderTable(w, []byte(`["production","staging"]`))
	out := stdout.String()
	if !strings.Contains(out, "production") || !strings.Contains(out, "staging") {
		t.Errorf("top-level scalar array dropped by table renderer:\n%s", out)
	}
}

func TestRenderRowsEmptyEchoesCountMeta(t *testing.T) {
	// A user runs `?count=true` precisely to learn the match total. On the one
	// page where the number matters most — zero rows — the count/total must
	// still print (a filter that matched zero vs. an offset past the end).
	rows := []any{}
	meta := map[string]any{"count": float64(0), "total": float64(0)}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderRows(w, rows, meta)
	if got := stdout.String(); got != "(no rows)\n\ncount: 0\ntotal: 0\n" {
		t.Errorf("empty-page count meta = %q, want %q", got, "(no rows)\n\ncount: 0\ntotal: 0\n")
	}
}

func TestRenderRowsEmptyNilMetaSilent(t *testing.T) {
	// No meta (or meta without a "count" key): the empty page prints only the
	// "(no rows)" line, no trailing blank or count.
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderRows(w, []any{}, nil)
	if got := stdout.String(); got != "(no rows)\n" {
		t.Errorf("empty-page nil meta = %q, want %q", got, "(no rows)\n")
	}
}

func TestRenderRowsAlignsWideRunes(t *testing.T) {
	// A CJK ideograph is one rune but occupies two terminal columns. With
	// rune-count padding the wide-value row over-shoots and the next column
	// starts a couple of cells to the right of the narrow-value row — a sheared
	// table. Display-width padding keeps every row's value column at the same
	// visual offset. (CJK ideographs are unambiguously wide, so this is
	// deterministic regardless of the runewidth east-asian-ambiguous setting.)
	rows := []any{
		map[string]any{"name": "世界", "v": "AA"},
		map[string]any{"name": "hi", "v": "BB"},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderRows(w, rows, nil)
	out := stdout.String()

	var wideRow, narrowRow string
	for _, ln := range strings.Split(out, "\n") {
		switch {
		case strings.Contains(ln, "AA"):
			wideRow = ln
		case strings.Contains(ln, "BB"):
			narrowRow = ln
		}
	}
	if wideRow == "" || narrowRow == "" {
		t.Fatalf("expected both data rows in output:\n%s", out)
	}
	// The value column must begin at the same DISPLAY offset on both rows.
	wideOff := runewidth.StringWidth(wideRow[:strings.Index(wideRow, "AA")])
	narrowOff := runewidth.StringWidth(narrowRow[:strings.Index(narrowRow, "BB")])
	if wideOff != narrowOff {
		t.Errorf("wide-rune column misaligned: value starts at display col %d on the CJK row but %d on the ASCII row\n%s",
			wideOff, narrowOff, out)
	}
}
