package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// closeCmd looks up `task close` in the served-manifest fixture.
func closeCmd(t *testing.T) (*manifest.Manifest, manifest.Command) {
	t.Helper()
	m, tree := loadTreeFrom(t, fullManifest)
	cmd, ok := tree.Lookup("task", "close")
	if !ok {
		t.Fatal("task close missing from full-manifest fixture")
	}
	return m, *cmd
}

func closeCtx() manifest.Context {
	return manifest.Context{
		Server:  "https://api.barkpark.cloud",
		Dataset: "production",
		Token:   "test-token",
	}
}

// TestTaskCloseMalformedSetAbortsBeforeAnyRequest pins HALF (2) of gh-2314:
// "a failed --set does NOT abort the close: the bare close proceeds, consumes
// the claim epoch, and leaves criteria un-flipped."
//
// It cannot, and this is the seam that proves it. `dispatch` sends exactly what
// `buildManifestRequest` hands back (run.go: build the URL → apply query →
// buildBody → authHeaders → return *manifestRequest), so a build-time error
// returns NO request object at all — there is nothing to send, on any code
// path, and the claim epoch is never reached. The test asserts the two halves
// that make that argument sound: the malformed `--set` yields (nil request,
// error), and the SAME invocation minus that one flag builds a request — so the
// refusal is attributable to the payload, not to a missing positional.
func TestTaskCloseMalformedSetAbortsBeforeAnyRequest(t *testing.T) {
	m, cmd := closeCmd(t)

	// The rubric a worker pastes, with one brace lost to a shell or a
	// copy-paste — the exact accident the row reports.
	malformed := []string{
		"task-6e819f39fe3aa9e6", "lead-cli", "3", "done", "shipped",
		"--set", `criteria:=[{"criterion":"the rubric shape is accepted","met":true,]`,
	}

	req, derr := buildManifestRequest(globals{}, closeCtx(), m, cmd, malformed, false)
	if derr == nil {
		t.Fatal("a malformed --set must abort the close, not fall through to a bare close")
	}
	if req != nil {
		t.Fatalf("no request may be built from a malformed --set; got %#v", req)
	}
	if !strings.Contains(derr.Error(), "is not valid JSON") {
		t.Fatalf("error = %q, want it to name the invalid JSON", derr)
	}

	// Same command, same positionals, --set removed: this one builds. The
	// refusal above is the payload's, so the abort is not an artifact of the
	// fixture or of arg binding.
	ok, derr := buildManifestRequest(
		globals{}, closeCtx(), m, cmd,
		[]string{"task-6e819f39fe3aa9e6", "lead-cli", "3", "done", "shipped"},
		false,
	)
	if derr != nil {
		t.Fatalf("the same close without --set must build: %v", derr)
	}
	if ok == nil || ok.method != "POST" {
		t.Fatalf("close request = %#v, want a POST", ok)
	}
}

// TestTaskCloseRubricShapeRidesSet pins HALF (1) of gh-2314 at the CLI seam: the
// authoring rubric row — `{"criterion":…,"met":…,"evidence":…}`, the shape
// `bp task get` prints and the shape the row says was REJECTED — rides the
// generic typed `--set` path into the close body verbatim, as a real JSON array
// with NO index key. Whether the server then accepts it is the server's
// contract (Params.parse_criteria + Internal.merge_criteria, tested there); what
// the CLI owes is not to mangle or reject it on the way out.
func TestTaskCloseRubricShapeRidesSet(t *testing.T) {
	m, cmd := closeCmd(t)

	req, derr := buildManifestRequest(
		globals{}, closeCtx(), m, cmd,
		[]string{
			"task-6e819f39fe3aa9e6", "lead-cli", "3", "blocked", "handing off",
			"--set", `criteria:=[{"criterion":"the rubric shape is accepted","met":true,"evidence":"PR #14400"}]`,
		},
		false,
	)
	if derr != nil {
		t.Fatalf("buildManifestRequest: %v", derr)
	}

	var body map[string]any
	if err := json.Unmarshal(req.body, &body); err != nil {
		t.Fatalf("close body not valid JSON: %s", req.body)
	}

	criteria, ok := body["criteria"].([]any)
	if !ok || len(criteria) != 1 {
		t.Fatalf("criteria = %v, want a 1-element JSON array; body = %s", body["criteria"], req.body)
	}
	entry, ok := criteria[0].(map[string]any)
	if !ok {
		t.Fatalf("criteria[0] = %v, want an object; body = %s", criteria[0], req.body)
	}
	if _, hasIndex := entry["index"]; hasIndex {
		t.Errorf("the CLI must not invent an index; criteria[0] = %v", entry)
	}
	if entry["criterion"] != "the rubric shape is accepted" || entry["met"] != true ||
		entry["evidence"] != "PR #14400" {
		t.Errorf("criteria[0] = %v, want the rubric row verbatim", entry)
	}
	// The positional args still ride alongside the --set payload.
	if body["worker_id"] != "lead-cli" || body["observed_epoch"] != "3" ||
		body["lifecycle_status"] != "blocked" {
		t.Errorf("--set must merge OVER the positionals, not replace them; body = %s", req.body)
	}
}
