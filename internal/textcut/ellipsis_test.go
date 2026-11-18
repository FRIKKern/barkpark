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
