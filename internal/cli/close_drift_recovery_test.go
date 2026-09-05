package cli

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// liveDriftBody is the 409 a real `bp task close` receives when the task's
// work-defining brief changed under the claim — the tasks_controller.ex
// :doc_changed_since_claim arm, verbatim in shape. Note where the two recovery
// values live: `current_rev` and `changed_fields` are TOP-LEVEL siblings of
// `reason`, not members of an `error` object, which is why classifyError's
// {"ok":false,"reason":…} branch — whose struct declared only Error/Reason/OK —
// dropped both after the server had already computed them.
//
// pds-bl-close-409-hint-promises-absent-fields: the hint printed under this
// refusal said "the 409 body names current_rev + changed_fields" and then
// offered `--set observed_rev=<current_rev>` — a literal placeholder. True of
// the wire, unreachable from the tool's own output: the operator was told the
// refusal had already handed them the rev, and had to go read the doc again to
// find it. That extra read is the exact step the hint claimed to have saved.
const liveDriftBody = `{"ok":false,"reason":"doc_changed_since_claim","current_rev":"9fa027e31333e85391f58fa43c28e435","changed_fields":["description"],"message":"the task's brief changed under your claim (description), so this close would seal work described differently from what you read. Nothing was written. Re-read it, reconcile those fields, then close pinning the rev in this body: bp task close <id> <worker> <epoch> --set observed_rev=9fa027e31333e85391f58fa43c28e435"}`

const liveDriftRev = "9fa027e31333e85391f58fa43c28e435"

// TestClassifyErrorKeepsTheDriftRecoveryValues: the two values the hint names
// must survive classification, or the hint is naming data the CLI deleted.
func TestClassifyErrorKeepsTheDriftRecoveryValues(t *testing.T) {
	ae := classifyError(http.StatusConflict, []byte(liveDriftBody))
	if ae.code != "doc_changed_since_claim" || ae.exit != exitConflict {
		t.Fatalf("code/exit = %q/%d, want doc_changed_since_claim/%d", ae.code, ae.exit, exitConflict)
	}
	if ae.details == nil {
		t.Fatal("details is nil — current_rev and changed_fields were dropped, which is the whole bug")
	}
	var got struct {
		CurrentRev    string   `json:"current_rev"`
		ChangedFields []string `json:"changed_fields"`
	}
	if err := json.Unmarshal(ae.details, &got); err != nil {
		t.Fatalf("details is not the drift payload: %v (%s)", err, ae.details)
	}
	if got.CurrentRev != liveDriftRev {
		t.Errorf("details.current_rev = %q, want the rev the server sent (%q)", got.CurrentRev, liveDriftRev)
	}
	if len(got.ChangedFields) != 1 || got.ChangedFields[0] != "description" {
		t.Errorf("details.changed_fields = %v, want [description]", got.ChangedFields)
	}
	if ae.driftRev() != liveDriftRev {
		t.Errorf("driftRev() = %q, want %q", ae.driftRev(), liveDriftRev)
	}
}

// TestTopLevelDriftLeavesOtherReasonsByteIdentical: the lift is keyed on the
// PRESENCE of a non-empty top-level current_rev, so no other ok:false refusal
// may grow a details payload it did not have. A details appearing where none
// did would change the -o json envelope for every unrelated task refusal.
func TestTopLevelDriftLeavesOtherReasonsByteIdentical(t *testing.T) {
	for _, body := range []string{
		`{"ok":false,"reason":"not_ready"}`,
		`{"ok":false,"reason":"fenced_off","message":"epoch 3 is stale"}`,
		`{"ok":false,"reason":"doc_changed_since_claim"}`,
		`{"ok":false,"reason":"doc_changed_since_claim","current_rev":""}`,
		`{"ok":false,"reason":"criteria_unmet:0,1"}`,
	} {
		if ae := classifyError(http.StatusConflict, []byte(body)); ae.details != nil {
			t.Errorf("%s produced details %s, want none", body, ae.details)
		}
	}
	// And the conflicts lift keeps its own bytes — the two shapes never collide.
	ae := classifyError(http.StatusConflict, []byte(liveResourceConflictBody))
	if ae.details == nil || !strings.Contains(string(ae.details), "conflicts") {
		t.Errorf("resource_conflict details = %s, want the conflicts payload untouched", ae.details)
	}
}

// TestDriftHintSubstitutesTheRevWhenTheBodyCarriesIt is criterion 2 at the
// level of the sentence: with the rev in hand the printed command is COMPLETE.
// The operator copies one line and runs it; no `bp task get` in between.
func TestDriftHintSubstitutesTheRevWhenTheBodyCarriesIt(t *testing.T) {
	ae := classifyError(http.StatusConflict, []byte(liveDriftBody))
	h := ae.hint()
	if want := "--set observed_rev=" + liveDriftRev; !strings.Contains(h, want) {
		t.Errorf("hint does not carry the runnable command %q:\n%s", want, h)
	}
	for _, banned := range []string{"<current_rev>", "the 409 body names"} {
		if strings.Contains(h, banned) {
			t.Errorf("hint still carries the unspendable promise %q:\n%s", banned, h)
		}
	}
}

// TestDriftHintFallsBackHonestlyWithoutDetails is the other half of the same
// contract, and the one that keeps the fix from becoming a NEW lie: an older
// server (or any body that omits the values) must produce a hint that says the
// rev has to be read — never a promise the body did not keep.
func TestDriftHintFallsBackHonestlyWithoutDetails(t *testing.T) {
	ae := classifyError(http.StatusConflict, []byte(`{"ok":false,"reason":"doc_changed_since_claim"}`))
	h := ae.hint()
	if h == "" {
		t.Fatal("doc_changed_since_claim lost its hint entirely")
	}
	if strings.Contains(h, "the 409 body names") {
		t.Errorf("the detail-less hint still promises the body names the rev:\n%s", h)
	}
	if !strings.Contains(h, "bp task get") {
		t.Errorf("the detail-less hint does not tell the operator where to get the rev:\n%s", h)
	}
	if strings.Contains(h, "observed_rev="+liveDriftRev) {
		t.Errorf("a rev appeared out of nowhere:\n%s", h)
	}
	// The server's own envelope hint still outranks both wordings.
	withServer := apiError{code: "doc_changed_since_claim", serverHint: "server says"}
	if got := withServer.hint(); got != "server says" {
		t.Errorf("hint = %q, want the server's envelope hint to take precedence", got)
	}
}

// --- through the REAL `bp task close` dispatch ---------------------------

// TestTaskCloseExecute_DriftRefusalPrintsTheRunnableRecovery is criterion 2
// end to end: what an operator SEES on a drift 409 must be enough to recover
// from, with no second command. The rev, the changed field, and the full
// `--set observed_rev=<rev>` line all have to reach the terminal.
func TestTaskCloseExecute_DriftRefusalPrintsTheRunnableRecovery(t *testing.T) {
	taxonomyClosingServer(t, http.StatusConflict, liveDriftBody)
	out, code := captureExecuteCode(t, []string{
		"task", "close", "bp-task-x", "w", "1", "done", "summary", "--yes",
	})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d); out:\n%s", code, exitConflict, out)
	}
	for _, want := range []string{
		liveDriftRev,
		"--set observed_rev=" + liveDriftRev,
		"description",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output is missing %q — the recovery the server already computed:\n%s", want, out)
		}
	}
	if strings.Contains(out, "<current_rev>") {
		t.Errorf("output still prints the placeholder instead of the rev:\n%s", out)
	}
}

// TestTaskCloseExecute_DriftWithoutTheValuesDoesNotPromiseThem is the control.
// Same refusal token, a body that carries neither value: the output must not
// claim the refusal named a rev it did not name.
func TestTaskCloseExecute_DriftWithoutTheValuesDoesNotPromiseThem(t *testing.T) {
	taxonomyClosingServer(t, http.StatusConflict,
		`{"ok":false,"reason":"doc_changed_since_claim","message":"the brief changed"}`)
	out, code := captureExecuteCode(t, []string{
		"task", "close", "bp-task-x", "w", "1", "done", "summary", "--yes",
	})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d); out:\n%s", code, exitConflict, out)
	}
	if strings.Contains(out, "the 409 body names") {
		t.Errorf("output promises fields this body never carried:\n%s", out)
	}
	if !strings.Contains(out, "bp task get") {
		t.Errorf("output does not say where the rev must be read from:\n%s", out)
	}
}
