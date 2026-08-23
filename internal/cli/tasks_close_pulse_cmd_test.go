package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// --- the READ-BACK for close and pulse (pds-w26-close-pulse-readback) ---
//
// `bp task stamp` got its second read in wave 26 and its two siblings on the
// same ledger were left reporting success on an exit code alone. The fixtures
// below mirror the stamp ones exactly: ONE package-level request per verb, and
// pairs that vary only on the STORED row — so a receipt that echoed the request
// would print the same bytes for both halves and the ledger-row property
// (TestLedgerRowsAreProbedWithTheStoredRow) would fail it.

// closeVerdictReq is the ONE package-level close request the registry rows share.
var closeVerdictReq = closeRequest{
	docID:    "task-abc",
	worker:   "go-internal",
	wantSeal: "done",
}

// closeStoredBacked is the row a store holds when the close LANDED: the seal
// took and the claim was released.
func closeStoredBacked() taskboard.SealRow {
	return taskboard.SealRow{LifecycleStatus: closeVerdictReq.wantSeal, Met: 3, Total: 3}
}

// closeStoredContradicted is the row a dropped close leaves: a 200, a normal
// envelope, and the task still open in the store.
//
// The criteria tally is held IDENTICAL to the backed half on purpose. The pair
// must vary on the SEAL and nothing else — a pair that also moved the tally
// would print two different lines for a reason other than the post-condition
// under test, and TestClaimProbesHoldIdentityFixed refuses exactly that.
func closeStoredContradicted() taskboard.SealRow {
	return taskboard.SealRow{LifecycleStatus: "open", Met: 3, Total: 3}
}

// pulseVerdictReq is the ONE package-level pulse request the registry rows share.
var pulseVerdictReq = pulseRequest{
	docID:   "task-abc",
	worker:  "go-internal",
	wantNow: "warm-up pinned, rerunning",
}

// pulseStoredBacked is the claim a store holds when the pulse LANDED.
func pulseStoredBacked() taskboard.PulseRow {
	return taskboard.PulseRow{
		Now:         &taskboard.ClaimPulse{Text: pulseVerdictReq.wantNow, At: time.Unix(1750000000, 0), Criterion: -1},
		ClaimWorker: pulseVerdictReq.worker,
		ClaimEpoch:  4,
	}
}

// pulseStoredContradicted is the claim a dropped pulse leaves: the lease is
// there, the now-line the board renders is not.
func pulseStoredContradicted() taskboard.PulseRow {
	return taskboard.PulseRow{ClaimWorker: pulseVerdictReq.worker, ClaimEpoch: 4}
}

// closePulseReadbackPublished is the row IDENTITY the ordinary cases assume.
func closePulseReadbackPublished() apiclient.TaskReadback {
	return apiclient.TaskReadback{DocID: closeVerdictReq.docID, Status: "published"}
}

// --- close ---

// The verdict must be read off the STORE. A task still open after its close
// exits non-zero and names the seal that was asked for and the one found.
func TestRenderCloseVerdict_UnlandedSealIsNotSuccess(t *testing.T) {
	out, buf := stampVerdictWriter()

	code := renderCloseVerdict(out, closeVerdictReq, closeStoredContradicted(), closePulseReadbackPublished(), exitOK)

	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — a close the store did not take must not report success", code, exitConflict)
	}
	got := buf()
	for _, want := range []string{`"done"`, "open", "3/3"} {
		if !strings.Contains(got, want) {
			t.Errorf("the receipt does not name %q; got:\n%s", want, got)
		}
	}
}

func TestRenderCloseVerdict_LandedSealGreens(t *testing.T) {
	out, buf := stampVerdictWriter()

	code := renderCloseVerdict(out, closeVerdictReq, closeStoredBacked(), closePulseReadbackPublished(), exitOK)

	if code != exitOK {
		t.Fatalf("a landed close exited %d, want 0; output:\n%s", code, buf())
	}
}

// A close whose seal took but whose lease release did not is HALF-landed: the
// board shows a closed task somebody still holds. Reporting that as a clean
// success is the same class of lie as reporting an unlanded one.
func TestRenderCloseVerdict_SealedButStillClaimedIsHalfLanded(t *testing.T) {
	out, buf := stampVerdictWriter()
	stored := closeStoredBacked()
	stored.ClaimWorker = "someone-else"

	code := renderCloseVerdict(out, closeVerdictReq, stored, closePulseReadbackPublished(), exitOK)

	if code == exitOK {
		t.Fatalf("a sealed-but-still-claimed row exited 0 — the close half-landed; output:\n%s", buf())
	}
	if !strings.Contains(buf(), "someone-else") {
		t.Errorf("the receipt does not name the holder; got:\n%s", buf())
	}
}

// A read-back that carried no lifecycle_status has not confirmed the seal. It
// must say UNCHECKED rather than either invent a failure or claim a success.
func TestRenderCloseVerdict_AbsentSealIsUnchecked(t *testing.T) {
	out, buf := stampVerdictWriter()

	code := renderCloseVerdict(out, closeVerdictReq, taskboard.SealRow{}, closePulseReadbackPublished(), exitOK)

	if code == exitOK {
		t.Fatalf("a close the read-back could not confirm exited 0; output:\n%s", buf())
	}
	if !strings.Contains(buf(), "unchecked close") {
		t.Errorf("the receipt does not say the close is unchecked; got:\n%s", buf())
	}
}

func TestRenderCloseVerdict_DraftRowRefusesTheGreen(t *testing.T) {
	out, buf := stampVerdictWriter()
	draft := apiclient.TaskReadback{DocID: "drafts." + closeVerdictReq.docID, Status: "draft"}

	code := renderCloseVerdict(out, closeVerdictReq, closeStoredBacked(), draft, exitOK)

	if code == exitOK {
		t.Fatalf("a close confirmed only on a DRAFT exited 0; output:\n%s", buf())
	}
	if !strings.Contains(buf(), "drafts."+closeVerdictReq.docID) {
		t.Errorf("the receipt does not name the draft row; got:\n%s", buf())
	}
}

// --- pulse ---

// A pulse that renewed the lease but left no now-line on the board did not do
// the thing the verb is for.
func TestRenderPulseVerdict_MissingNowLineIsNotSuccess(t *testing.T) {
	out, buf := stampVerdictWriter()

	code := renderPulseVerdict(out, pulseVerdictReq, pulseStoredContradicted(), closePulseReadbackPublished(), exitOK)

	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — a now-line the board never got must not report success", code, exitConflict)
	}
	if !strings.Contains(buf(), pulseVerdictReq.wantNow) {
		t.Errorf("the receipt does not name the now-line that was sent; got:\n%s", buf())
	}
}

func TestRenderPulseVerdict_LandedNowLineGreens(t *testing.T) {
	out, buf := stampVerdictWriter()

	code := renderPulseVerdict(out, pulseVerdictReq, pulseStoredBacked(), closePulseReadbackPublished(), exitOK)

	if code != exitOK {
		t.Fatalf("a landed pulse exited %d, want 0; output:\n%s", code, buf())
	}
}

// A now-line that is present but is somebody ELSE's is the failure a bare exit
// code hides most completely: the board looks alive and is showing the wrong
// worker's line.
func TestRenderPulseVerdict_DifferentStoredLineIsNotSuccess(t *testing.T) {
	out, buf := stampVerdictWriter()
	stored := pulseStoredBacked()
	stored.Now = &taskboard.ClaimPulse{Text: "something else entirely", Criterion: -1}

	code := renderPulseVerdict(out, pulseVerdictReq, stored, closePulseReadbackPublished(), exitOK)

	if code == exitOK {
		t.Fatalf("a DIFFERENT stored now-line exited 0; output:\n%s", buf())
	}
}

func TestRenderPulseVerdict_ClaimHeldByAnotherWorkerIsNotSuccess(t *testing.T) {
	out, buf := stampVerdictWriter()
	stored := pulseStoredBacked()
	stored.ClaimWorker = "someone-else"

	code := renderPulseVerdict(out, pulseVerdictReq, stored, closePulseReadbackPublished(), exitOK)

	if code == exitOK {
		t.Fatalf("a pulse onto someone else's lease exited 0; output:\n%s", buf())
	}
	if !strings.Contains(buf(), "someone-else") {
		t.Errorf("the receipt does not name the actual holder; got:\n%s", buf())
	}
}

func TestRenderPulseVerdict_DraftRowRefusesTheGreen(t *testing.T) {
	out, buf := stampVerdictWriter()
	draft := apiclient.TaskReadback{DocID: "drafts." + pulseVerdictReq.docID, Status: "draft"}

	code := renderPulseVerdict(out, pulseVerdictReq, pulseStoredBacked(), draft, exitOK)

	if code == exitOK {
		t.Fatalf("a pulse confirmed only on a DRAFT exited 0; output:\n%s", buf())
	}
}
