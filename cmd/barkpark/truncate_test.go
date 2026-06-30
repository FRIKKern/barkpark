package main

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/charmbracelet/lipgloss"
)

// TestTruncateRuneSafeAndWidthBudget pins that truncate measures DISPLAY width,
// not bytes: it never splits a multibyte rune (the old s[:max] byte slice could
// emit invalid UTF-8) and never exceeds the column budget (the old
// `s[:max-1] + "..."` overflowed by 2). Norwegian content (æøå = 2 bytes / 1
// column) is the common case for this project's titles.
func TestTruncateRuneSafeAndWidthBudget(t *testing.T) {
	cases := []struct {
		name string
		s    string
		max  int
	}{
		// "a" + ø forces an ODD byte boundary, so the old s[:max-1] byte slice
		// split a 2-byte ø and emitted invalid UTF-8.
		{"ascii-prefix-then-multibyte", "a" + strings.Repeat("ø", 20), 5},
		{"all-multibyte", strings.Repeat("æ", 30), 8},
		{"norwegian-title", "Håndbok for grensesnittdesign", 12},
		{"no-truncation-needed", "kort", 10},
		{"tiny-budget", "Bjørnsønn", 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := truncate(tc.s, tc.max)
			if !utf8.ValidString(got) {
				t.Errorf("truncate(%q, %d) = %q: invalid UTF-8 (rune split)", tc.s, tc.max, got)
			}
			if w := lipgloss.Width(got); w > tc.max {
				t.Errorf("truncate(%q, %d) width = %d, exceeds the %d-column budget: %q",
					tc.s, tc.max, w, tc.max, got)
			}
		})
	}
}
