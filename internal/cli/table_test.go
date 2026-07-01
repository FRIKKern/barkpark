package cli

import (
	"bytes"
	"strings"
	"testing"
	"unicode/utf8"
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
