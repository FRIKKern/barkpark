package provisioner

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"strings"
	"testing"
)

func TestSupportTrimBodyCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 296)
	if got := supportTrimBody([]byte(pad + "🇳🇴")); got != pad+"…" {
		t.Errorf("supportTrimBody ends %q, want the padding and an ellipsis", got[290:])
	}
}

func TestWorkerTruncateCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 199)
	if got := truncate(pad+"🇳🇴", 200); got != pad+"…" {
		t.Errorf("truncate ends %q, want the padding and an ellipsis", got[190:])
	}
}
