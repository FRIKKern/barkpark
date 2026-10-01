package cli

import (
	"bytes"
	"testing"
)

// `bp setup --target local --yes -o json` promises one JSON object on stdout.
// The step runner streamed mix deps.get / ecto.reset output to opts.Out, which
// was stdout in every mode, so about 11,800 lines preceded the object
// (stranger walk, 2026-10-01). Under -o json the steps go to stderr.
func TestSetupStepOutputLeavesStdoutForTheJSONObject(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := &writer{stdout: &stdout, stderr: &stderr}

	if got := setupStepOut(w, true); got != &stderr {
		t.Fatalf("-o json: setup step output goes to %p, want stderr %p", got, &stderr)
	}
	// Positive control: the human run still streams steps on stdout.
	if got := setupStepOut(w, false); got != &stdout {
		t.Fatalf("human run: setup step output goes to %p, want stdout %p", got, &stdout)
	}
}
