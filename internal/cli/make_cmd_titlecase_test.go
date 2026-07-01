package cli

import (
	"testing"
	"unicode/utf8"
)

// TestTitleCaseUTF8 guards the rune-aware head-upper: a schema name whose first
// letter is a multi-byte rune must not be byte-sliced into a U+FFFD corruption.
func TestTitleCaseUTF8(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"über artikkel", "Über Artikkel"},
		{"índice", "Índice"},
		{"日本語 post", "日本語 Post"},
		{"my_post-type", "My Post Type"},
	}
	for _, c := range cases {
		got := titleCase(c.in)
		if got != c.want {
			t.Errorf("titleCase(%q) = %q, want %q", c.in, got, c.want)
		}
		if !utf8.ValidString(got) {
			t.Errorf("titleCase(%q) = %q is not valid UTF-8", c.in, got)
		}
	}
}
