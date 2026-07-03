package taskboard

import (
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestChipSlotStability PINS the tag→hue mapping. These pairs are the contract:
// a chip's color is learned once and must hold across every row, surface, and
// release. If the hash algorithm or the modulus ever changes, these assertions
// break in the same commit — a deliberate tripwire, because a silent re-coloring
// is a UX regression (the reader's learned "that hue = perf" would go stale).
func TestChipSlotStability(t *testing.T) {
	want := map[string]int{
		"perf":  2,
		"live":  1,
		"sse":   2,
		"theme": 0,
		"dx":    1,
	}
	for tag, slot := range want {
		if got := chipSlot(tag); got != slot {
			t.Errorf("chipSlot(%q) = %d, want %d (hash contract changed?)", tag, got, slot)
		}
	}
}

// TestChipSlotInRange proves every slot lands in [0, chipSlotCount) — chipStyle
// indexes an array with it, so an out-of-range slot would panic at render.
func TestChipSlotInRange(t *testing.T) {
	for _, tag := range []string{"", "a", "proj:cloud", "🚀", "看板", "a-very-long-label-name-x"} {
		if s := chipSlot(tag); s < 0 || s >= chipSlotCount {
			t.Errorf("chipSlot(%q) = %d, out of [0,%d)", tag, s, chipSlotCount)
		}
	}
}

// TestChipText proves one taxonomy prefix is stripped for display while any
// bare tag or unknown-prefixed tag is shown verbatim.
func TestChipText(t *testing.T) {
	cases := map[string]string{
		"proj:cloud":     "cloud",
		"area:search":    "search",
		"phase:1":        "1",
		"kind:bug":       "bug",
		"host:guerrilla": "guerrilla",
		"perf":           "perf",      // bare — verbatim
		"team:core":      "team:core", // unknown prefix — verbatim
		":leading":       ":leading",  // no prefix before ':' — verbatim
		"a:b:c":          "a:b:c",     // "a" is not a taxonomy — verbatim
		"proj:":          "proj:",     // dangling prefix — verbatim, never ""
	}
	for in, want := range cases {
		if got := chipText(in); got != want {
			t.Errorf("chipText(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestChipsBudgetFloor — under the display-column floor Chips renders nothing at
// all (a cramped run would only garble).
func TestChipsBudgetFloor(t *testing.T) {
	if got := Chips([]string{"perf"}, "", "", chipMinBudget-1); got != "" {
		t.Errorf("Chips under budget floor = %q, want empty", got)
	}
}

// TestChipsRun covers the shape rules: prefix-stripped text, section-tag
// suppression, the 2-chip cap + `+N` overflow, and the dim `+<short>?` suggested
// hint rendered last.
func TestChipsRun(t *testing.T) {
	cases := []struct {
		name      string
		labels    []string
		suggested string
		section   string
		budget    int
		want      string // ANSI-stripped
	}{
		{"single", []string{"perf"}, "", "", 40, "perf"},
		{"strip-prefix", []string{"proj:cloud"}, "", "", 40, "cloud"},
		{"two-chips", []string{"live", "sse"}, "", "", 40, "live sse"},
		{"overflow", []string{"a", "b", "c", "d"}, "", "", 40, "a b +2"},
		{"suppress-section", []string{"perf", "area:x"}, "", "area:x", 40, "perf"},
		{"suggested-only", nil, "theme", "", 40, "+theme?"},
		{"suggested-last", []string{"perf"}, "live", "", 40, "perf +live?"},
		{"suggested-stripped", nil, "phase:2", "", 40, "+2?"},
		{"skip-empty", []string{"", "perf"}, "", "", 40, "perf"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ansi.Strip(Chips(c.labels, c.suggested, c.section, c.budget))
			if got != c.want {
				t.Errorf("Chips(%v, %q, %q, %d) = %q, want %q",
					c.labels, c.suggested, c.section, c.budget, got, c.want)
			}
		})
	}
}

// TestChipsNeverExceedsBudget is the width-safety invariant — no chip run may be
// wider than its budget, on tags that would overflow a naive concatenation.
func TestChipsNeverExceedsBudget(t *testing.T) {
	labels := []string{"perf", "live", "sse", "theme", "backend", "frontend"}
	for _, budget := range []int{12, 13, 16, 20, 24, 30, 40, 60} {
		got := Chips(labels, "cleanup", "", budget)
		if w := ansi.StringWidth(got); w > budget {
			t.Errorf("budget %d: chip run is %d cols (over budget): %q", budget, w, ansi.Strip(got))
		}
	}
}

// TestChipsAtMostTwoHued proves the cap: however many eligible labels, at most
// chipMaxVisible hued chips paint and the remainder fold into one `+N`.
func TestChipsAtMostTwoHued(t *testing.T) {
	got := ansi.Strip(Chips([]string{"a", "b", "c", "d", "e"}, "", "", 60))
	if got != "a b +3" {
		t.Errorf("five labels = %q, want %q", got, "a b +3")
	}
}

// TestChipsOverflowNeverSilentlyDropped — when a hued chip lands but the `+N`
// no longer fits, the run must pop the chip and keep the (grown) honest count
// rather than hide tags without a trace. Budget 12 with an 11-wide first tag:
// the tag fits alone, "+1" doesn't, so the run degrades to "+2".
func TestChipsOverflowNeverSilentlyDropped(t *testing.T) {
	got := ansi.Strip(Chips([]string{"abcdefghijk", "x"}, "", "", 12))
	if got != "+2" {
		t.Errorf("starved overflow = %q, want %q (tags must never vanish silently)", got, "+2")
	}
}

// TestChipsAllShowsEveryLabel — the expanded-detail variant has no hued cap:
// every eligible label paints when the budget allows, so the expanded view is
// the one guaranteed place to read a task's whole tag set.
func TestChipsAllShowsEveryLabel(t *testing.T) {
	got := ansi.Strip(ChipsAll([]string{"a", "b", "c", "d", "e"}, "", "", 60))
	if got != "a b c d e" {
		t.Errorf("ChipsAll = %q, want %q", got, "a b c d e")
	}
	// It still folds honestly when the budget runs out.
	got = ansi.Strip(ChipsAll([]string{"alpha", "beta", "gamma", "delta"}, "", "", 14))
	if got != "alpha beta +2" {
		t.Errorf("ChipsAll tight = %q, want %q", got, "alpha beta +2")
	}
}
