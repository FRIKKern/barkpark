package cloudclient

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"strings"
	"testing"
)

func TestCloudErrorCutsOnAGraphemeBoundary(t *testing.T) {
	pad := strings.Repeat("a", 199)
	got := cloudError(502, []byte(pad+"🇳🇴")).Error()
	if !strings.Contains(got, pad+"…") || strings.Contains(got, "\U0001F1F3") {
		t.Errorf("cloudError message %q does not end on the padding", got[len(got)-20:])
	}
}
