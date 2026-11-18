package scaffy

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"strings"
	"testing"
)

func TestTruncateCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 16)
	if got := truncate(pad+"🇳🇴", 20); got != pad+" …[truncated]" {
		t.Errorf("truncate = %q, want the padding and the mark", got)
	}
}
