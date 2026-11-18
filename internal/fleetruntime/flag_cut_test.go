package fleetruntime

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"strings"
	"testing"
)

func TestTrimCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 196)
	if got := trim([]byte(pad + "🇳🇴")); got != pad+"…" {
		t.Errorf("trim ends %q, want the padding and an ellipsis", got[190:])
	}
}
