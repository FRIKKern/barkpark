package agent

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// TestTruncateMultibyteStaysValid verifies truncate cuts on rune boundaries,
// not byte boundaries — a multibyte body (Norwegian æ = 2 bytes) capped at n
// runes must remain valid UTF-8 and carry exactly n runes before the ellipsis.
func TestTruncateMultibyteStaysValid(t *testing.T) {
	in := strings.Repeat("æ", 300)
	got := truncate(in, 200)

	if !utf8.ValidString(got) {
		t.Fatalf("truncate produced invalid UTF-8: %q", got)
	}

	pre := strings.TrimSuffix(got, "…")
	if pre == got {
		t.Fatalf("expected an ellipsis suffix, got %q", got)
	}
	if n := utf8.RuneCountInString(pre); n != 200 {
		t.Fatalf("pre-ellipsis rune count = %d, want 200", n)
	}
}
