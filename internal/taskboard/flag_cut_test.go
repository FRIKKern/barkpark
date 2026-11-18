package taskboard

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"strings"
	"testing"
)

func TestBodyHintCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 116)
	if got := bodyHint([]byte(pad + "🇳🇴")); got != ": "+pad+"…" {
		t.Errorf("bodyHint ends %q, want the padding and an ellipsis", got[110:])
	}
}
