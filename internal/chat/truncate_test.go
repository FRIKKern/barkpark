package chat

import (
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestTruncateWidthBound pins truncate()'s display-width contract: the result
// NEVER exceeds the target width w. The pre-fix break test — `lipgloss.Width(out)+1 >= w`
// — hardcoded a single-cell next rune, so a width-2 rune (emoji/CJK) at the
// boundary overshot w by one cell (three party-emoji at w=4 returned width 5).
// The fix measures the actual per-rune width and reserves one cell for the
// ellipsis. Each case asserts the exact output AND that lipgloss.Width(out) <= w.
func TestTruncateWidthBound(t *testing.T) {
	cases := []struct {
		name string
		in   string
		w    int
		want string
	}{
		// The regression: three width-2 party emoji at w=4. Pre-fix returned
		// "🎉🎉…" (width 5). Post-fix drops to one emoji + ellipsis (width 3).
		{"emoji_overshoot", "🎉🎉🎉", 4, "🎉…"},
		// Tight wide-rune fit: two emoji at w=3 — exactly one emoji + ellipsis.
		{"emoji_tight", "🎉🎉", 3, "🎉…"},
		// CJK (each glyph width 2): "你好世界" at w=5 → 你好 + ellipsis = width 5.
		{"cjk", "你好世界", 5, "你好…"},
		// ASCII exact-fit preserved: brief's invariant.
		{"ascii_exact", "abcdef", 4, "abc…"},
		// ASCII longer budget.
		{"ascii_wide", "abcdef", 5, "abcd…"},
		// Mixed ASCII + wide rune at the boundary must still stay in budget.
		{"mixed", "ab你好", 4, "ab…"},
		// No truncation needed — returned verbatim.
		{"no_trunc_ascii", "abc", 5, "abc"},
		{"no_trunc_emoji", "🎉", 2, "🎉"},
		// w=1 with over-wide content → bare ellipsis.
		{"w1", "abc", 1, "…"},
		// w=0 → empty.
		{"w0", "abc", 0, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := truncate(c.in, c.w)
			if got != c.want {
				t.Errorf("truncate(%q, %d) = %q (width %d); want %q (width %d)",
					c.in, c.w, got, lipgloss.Width(got), c.want, lipgloss.Width(c.want))
			}
			// The load-bearing invariant: the result never exceeds the budget.
			if c.w >= 1 && lipgloss.Width(got) > c.w {
				t.Errorf("truncate(%q, %d) = %q OVERSHOOTS: display width %d > target %d",
					c.in, c.w, got, lipgloss.Width(got), c.w)
			}
		})
	}
}
