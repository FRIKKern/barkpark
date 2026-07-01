package main

import "testing"

// TestToSlugRuneAware pins that toSlug is Unicode-aware: it keeps any letter or
// digit (not just ASCII a-z/0-9), so non-Latin titles (accented Latin, CJK,
// Cyrillic) survive instead of collapsing to an empty or heavily-lossy slug —
// which the two-keypress "Generate" accept would otherwise store as an empty,
// collision-prone URL key. Pure-symbol input still yields "".
func TestToSlugRuneAware(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"ascii unchanged", "Hello World", "hello-world"},
		{"accented latin preserved", "Café Åre", "café-åre"},
		{"cjk preserved", "日本語ブログ", "日本語ブログ"},
		{"cyrillic preserved", "Привет Мир", "привет-мир"},
		{"pure symbols empty", "@#$", ""},
		{"collapse and trim hyphens", "  a -- b  ", "a-b"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := toSlug(c.in); got != c.want {
				t.Fatalf("toSlug(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
