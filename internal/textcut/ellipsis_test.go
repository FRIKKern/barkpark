package textcut

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// task-9ef60a4a9bac92fe: the rune-budget and ellipsis forms of Prefix.
const flag = "🇳🇴"

func TestEllipsisCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 196) // the budget of 200 falls between the indicators
	if got := Ellipsis(pad+flag, 200); got != pad+"…" {
		t.Errorf("Ellipsis = …%q, want the padding and an ellipsis", got[190:])
	}
	if got := Ellipsis(pad, 200); got != pad {
		t.Errorf("Ellipsis of text that fits added a mark: %q", got)
	}
}

func TestPrefixRunesCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("æ", 199) // the 200th rune is the first indicator
	if got := PrefixRunes(pad+flag, 200); got != pad {
		t.Errorf("PrefixRunes = …%q, want the padding only", got[len(got)-8:])
	}
	if got := EllipsisRunes(pad+flag, 200); got != pad+"…" {
		t.Errorf("EllipsisRunes = …%q, want the padding and an ellipsis", got[len(got)-8:])
	}
	if got := EllipsisRunes(pad+"b", 200); got != pad+"b" {
		t.Errorf("EllipsisRunes of text that fits changed it: …%q", got[len(got)-8:])
	}
}

// Text exactly at its budget is not cut, so it gets no "…" (task-71fb04465850fd41).
func TestEllipsisLeavesAnExactFitUnchanged(t *testing.T) {
	s := strings.Repeat("a", 200)
	if got := Ellipsis(s, 200); got != s {
		t.Errorf("Ellipsis of exactly 200 bytes at 200 = …%q, want the input unchanged", got[195:])
	}
	// 200 runes, 400 bytes: the rune budget, not the byte length, decides.
	r := strings.Repeat("æ", 200)
	if got := EllipsisRunes(r, 200); got != r {
		t.Errorf("EllipsisRunes of exactly 200 runes at 200 = …%q, want the input unchanged", got[390:])
	}
	if got := PrefixRunes(r, 200); got != r {
		t.Errorf("PrefixRunes of exactly 200 runes at 200 cut it to %d bytes", len(got))
	}
}

func TestPrefixRunesKeepsTheRuneBudget(t *testing.T) {
	// One letter with 500 combining marks is one grapheme. A grapheme count
	// would keep it all; the rune budget keeps 200 runes of it.
	s := "e" + strings.Repeat("́", 500)
	if got := utf8.RuneCountInString(PrefixRunes(s, 200)); got != 200 {
		t.Errorf("PrefixRunes kept %d runes of one oversized grapheme, want 200", got)
	}
	if got := PrefixRunes("abc", 0); got != "" {
		t.Errorf("PrefixRunes with no budget = %q, want empty", got)
	}
	// A stray byte counts as one rune and is kept, as Prefix keeps it.
	if got := PrefixRunes("a\xffbc", 2); got != "a\xff" {
		t.Errorf("PrefixRunes over a stray byte = %q, want %q", got, "a\xff")
	}
}
