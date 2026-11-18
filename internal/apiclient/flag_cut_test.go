package apiclient

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"strings"
	"testing"
)

func TestTrimForErrCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 196)
	if got := trimForErr([]byte(pad + "🇳🇴")); got != pad+"…" {
		t.Errorf("trimForErr ends %q, want the padding and an ellipsis", got[190:])
	}
}

func TestBodyPreviewCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 196)
	if got := bodyPreview([]byte(pad + "🇳🇴")); got != pad+"…" {
		t.Errorf("bodyPreview ends %q, want the padding and an ellipsis", got[190:])
	}
}

func TestHumanAPIErrorCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 199) // the 200th rune is the first indicator
	if got := humanAPIError(502, []byte(pad+"🇳🇴")).Error(); got != "error 502: "+pad+"…" {
		t.Errorf("humanAPIError ends %q, want the padding and an ellipsis", got[len(got)-12:])
	}
}
