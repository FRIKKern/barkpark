package cli

// Two measured faults in `bp task close`, both of which cost an agent a
// correctly-finished task:
//
//   1. THE REASON SENTENCE IN THE SEAL SLOT. The positional shape is
//      `close <id> <worker> <epoch> <lifecycle_status> [reason]`, so a reason
//      typed as the 4th positional binds to lifecycle_status, is POSTed, and
//      comes back `invalid_lifecycle:<the whole sentence>`.
//
//   2. A `stale_claim` 409 OVER A WRITE THAT LANDED. Measured on five closes:
//      the row stored, with its own reason verbatim, and the CLI exited 6. The
//      natural recovery (re-claim, retry) then 409s `not_ready` because the row
//      is already closed — so a sealed row reports as uncloseable.
//
// Both are Execute-level, driven through the real dispatch, because both live
// in the seam between the command line, the POST and the store.

import (
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// --- fault 1: the seal slot is not a reason slot ---

// THE SPINE of fault 1: the refusal is LOCAL. The assertion that carries the
// weight is `hits == 0` — not the exit code — because the bug is that the
// sentence reaches the server at all. Delete refuseCloseSealSentence and the
// POST fires.
func TestTaskCloseExecute_ReasonSentenceInTheSealSlotIsRefusedLocally(t *testing.T) {
	_, hits := cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "the fix merged in #123"})

	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("close POST fired %d times — a reason sentence in the seal slot must be refused BEFORE the request; out:\n%s", n, out)
	}
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation (%d) — the same code the server's invalid_lifecycle carries; out:\n%s",
			code, exitValidation, out)
	}
	// It must quote back what was actually typed...
	if !strings.Contains(out, `"the fix merged in #123"`) {
		t.Errorf("refusal never quotes what the user passed; got:\n%s", out)
	}
	// ...and name the exact correct invocation, with `done` in the seal slot.
	if !strings.Contains(out, `bp task close bp-task-x w 1 done "the fix merged in #123"`) {
		t.Errorf("refusal must name the corrected invocation verbatim; got:\n%s", out)
	}
	if !strings.Contains(out, "not a lifecycle_status") {
		t.Errorf("refusal should say WHICH slot was wrong; got:\n%s", out)
	}
}

// The refusal must NOT be a silent coercion. A close that seals `done` because
// the CLI guessed is a seal nobody asked for — the one outcome worse than the
// bug.
func TestTaskCloseExecute_SealSlotRefusalNeverCoercesToDone(t *testing.T) {
	st, _ := cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "the fix merged in #123"})

	if code == exitOK {
		t.Fatalf("a refused close exited 0; out:\n%s", out)
	}
	st.mu.Lock()
	life := st.lifecycle
	st.mu.Unlock()
	if life != "open" {
		t.Fatalf("the store's lifecycle_status moved to %q — the refusal wrote a seal; out:\n%s", life, out)
	}
}

// The legal statuses still pass straight through: a guard that refused a real
// close would be a far bigger outage than the typo it catches.
func TestTaskCloseExecute_EveryLegalSealStillCloses(t *testing.T) {
	for _, seal := range closeLifecycleStatuses {
		t.Run(seal, func(t *testing.T) {
			_, hits := cpTestServer(t, cpHonest)
			out, code := captureExecuteCode(t,
				[]string{"task", "close", "bp-task-x", "w", "1", seal, "shipped it"})
			if code != exitOK {
				t.Fatalf("close with seal %q exited %d, want 0; out:\n%s", seal, code, out)
			}
			if n := atomic.LoadInt32(hits); n != 1 {
				t.Fatalf("close with seal %q fired %d POSTs, want 1", seal, n)
			}
		})
	}
}

// An OMITTED lifecycle_status is legal — the server defaults it to done — so
// the guard must not fire on the three-positional form either.
func TestTaskCloseExecute_OmittedSealIsNotRefused(t *testing.T) {
	_, hits := cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1"})

	if code != exitOK {
		t.Fatalf("close without a seal exited %d, want 0; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("close without a seal fired %d POSTs, want 1", n)
	}
}

// The legal set has ONE definition. The MCP task_close schema splices it
// rather than repeating it, so this asserts the splice actually happened —
// a re-hardcoded enum in mcp_tasks.go would pass a JSON parse and silently
// re-open the drift this removes.
func TestCloseLifecycleStatusEnumIsSingleSourced(t *testing.T) {
	if got, want := closeLifecycleStatusEnumJSON, `["done","cancelled","blocked"]`; got != want {
		t.Fatalf("closeLifecycleStatusEnumJSON = %s, want %s", got, want)
	}
	for _, s := range closeLifecycleStatuses {
		if !isCloseLifecycleStatus(s) {
			t.Errorf("isCloseLifecycleStatus(%q) = false for a member of the legal set", s)
		}
	}
	for _, s := range []string{"", "open", "in_progress", "closed", "Done", "the fix merged in #123"} {
		if isCloseLifecycleStatus(s) {
			t.Errorf("isCloseLifecycleStatus(%q) = true — not a close seal", s)
		}
	}
}

// --- fault 2: a stale_claim over a write that landed ---

// THE SPINE of fault 2. The server answers 409 stale_claim AFTER committing.
// Without the read-back arm this exits 6 and the operator re-claims into a
// `not_ready`. With it, the store is asked and the close is reported as what it
// is: landed.
func TestTaskCloseExecute_StaleClaimOverALandedWriteIsSuccess(t *testing.T) {
	cpTestServer(t, cp409StaleClaimLanded)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "done", "shipped it in #14383"})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — the store holds this close; a stale_claim describes the LEASE, not the write; out:\n%s",
			code, out)
	}
	if !strings.Contains(out, "LANDED despite") || !strings.Contains(out, "stale_claim") {
		t.Errorf("the receipt must say the write landed despite the stale-claim response, or the operator is left confused; got:\n%s", out)
	}
	if !strings.Contains(out, "lifecycle_status=done") {
		t.Errorf("the receipt must report the STORED seal; got:\n%s", out)
	}
	if !strings.Contains(out, "not_ready") {
		t.Errorf("the receipt should warn against the retry that 409s not_ready; got:\n%s", out)
	}
}

// The other half, and the one that keeps the fix honest: a stale_claim whose
// write never landed is STILL a failure. A read-back that reported success here
// would seal nothing and claim everything.
func TestTaskCloseExecute_StaleClaimOverALostWriteStaysAFailure(t *testing.T) {
	cpTestServer(t, cp409StaleClaimAbsent)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "done", "shipped it in #14383"})

	if code == exitOK {
		t.Fatalf("a stale_claim whose write never landed exited 0 — the read-back invented a seal; out:\n%s", out)
	}
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — the original 409 must stand; out:\n%s", code, exitConflict, out)
	}
	if !strings.Contains(out, "genuinely ABSENT") || !strings.Contains(out, "lifecycle_status=open") {
		t.Errorf("the refusal should report the STORED (unchanged) row; got:\n%s", out)
	}
	if !strings.Contains(out, "re-claim") {
		t.Errorf("a genuinely lost close should point at the re-claim recovery; got:\n%s", out)
	}
}

// The fingerprint is load-bearing: a terminal row holding SOMEBODY ELSE'S close
// is not this close landing. Same 409, same seal — but a different reason in
// the store, and the verdict must be failure. This is the pure predicate, so
// each half of the fingerprint can be moved independently.
func TestCloseStaleClaimLanded_Fingerprint(t *testing.T) {
	req := closeRequest{docID: "bp-task-x", worker: "w", wantSeal: "done", reason: "shipped it in #14383"}
	sealed := taskboard.SealRow{LifecycleStatus: "done", ClaimWorker: "w"}

	rb := func(content, claim string) apiclient.TaskReadback {
		out := apiclient.TaskReadback{
			DocID:  "bp-task-x",
			Status: "published",
			// LifecycleStatus rides SealRow for this predicate; the readback
			// carries the content and claim halves of the fingerprint.
			Content: json.RawMessage(content),
		}
		if claim != "" {
			out.Claim = json.RawMessage(claim)
		}
		return out
	}

	if !closeStaleClaimLanded(req, sealed, rb(`{"close_reason":"shipped it in #14383"}`, "")) {
		t.Error("a row carrying THIS close's reason verbatim was not recognised as landed")
	}
	if closeStaleClaimLanded(req, sealed, rb(`{"close_reason":"superseded by the native tabs"}`, "")) {
		t.Error("a row carrying a DIFFERENT close_reason was read as this close landing")
	}
	if closeStaleClaimLanded(req, sealed, rb(`{}`, "")) {
		t.Error("a sealed row with NO close_reason was read as this close landing")
	}
	// A stored seal that is not the one asked for is never this close.
	if closeStaleClaimLanded(req, taskboard.SealRow{LifecycleStatus: "cancelled"},
		rb(`{"close_reason":"shipped it in #14383"}`, "")) {
		t.Error("a row sealed `cancelled` satisfied a close that asked for `done`")
	}
	// A row that is not terminal at all cannot have taken this close.
	if closeStaleClaimLanded(req, taskboard.SealRow{LifecycleStatus: "open"},
		rb(`{"close_reason":"shipped it in #14383"}`, "")) {
		t.Error("an OPEN row satisfied a landed close")
	}

	// With NO reason sent there is nothing to match, so the fallback is the
	// close-out stamp the server writes in the same atomic update.
	bare := closeRequest{docID: "bp-task-x", worker: "w", wantSeal: "done"}
	if !closeStaleClaimLanded(bare, sealed, rb(`{}`, `{"worker":"w","closed_by":"w","closed_at":"2026-09-01T20:41:44Z"}`)) {
		t.Error("a close-out stamp naming THIS worker did not settle a reasonless close")
	}
	if closeStaleClaimLanded(bare, sealed, rb(`{}`, `{"worker":"w"}`)) {
		t.Error("a claim with NO close-out stamp settled a reasonless close")
	}
	if closeStaleClaimLanded(bare, sealed, rb(`{}`, `{"worker":"w","closed_by":"someone-else"}`)) {
		t.Error("another worker's close-out stamp settled this close")
	}
}
