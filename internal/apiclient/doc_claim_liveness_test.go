package apiclient

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// Root pins for task-6d7b68c7c0e7e8cc: ClaimEpoch's docstring asserted it
// reported "whether a live claim is present", contradicting its own sibling
// ClaimInfo twenty lines below, which documented the hazard correctly. Two
// docstrings in one file disagreeing, and the wrong one was the one people
// called.

func claimDoc(claimJSON string) Doc {
	return Doc{ID: "task-probe", Extra: map[string]json.RawMessage{"claim": json.RawMessage(claimJSON)}}
}

// realReleasedClaim is VERBATIM from guerrilla — task-75feee3462657b3e after a
// real `bp task claim` then `bp task release`. Never hand-built.
const realReleasedClaim = `{"epoch":2,"released_at":"2026-09-15T08:49:36.925818Z","released_by":"probe-r19w7","ts_iso":"2026-09-15T08:49:23.603626Z","work_digest":"10ed0509bd041c7f","work_field_digests":{},"worker":null}`

const realLiveClaim = `{"epoch":1,"lease_expires_at":"2026-09-15T09:39:27.618048Z","lease_seconds":2700,"ts_iso":"2026-09-15T08:54:27.618048Z","work_digest":"3748a7a4222d04cf","work_field_digests":{},"worker":"probe-r19w7"}`

// ONLY THE WORKER VALUE DISCRIMINATES. claim != null, a non-zero epoch, and the
// mere PRESENCE of a worker key are all true on a released row.
func TestClaimInfoLiveIsDecidedByTheWorkerValueAlone(t *testing.T) {
	released := claimDoc(realReleasedClaim).ClaimInfo()
	if released.Live() {
		t.Errorf("MISCLASSIFIED RELEASED ROW: task-75feee3462657b3e's real post-release claim "+
			"{worker: null, epoch: 2, released_at: %q} reported Live()=true", released.ReleasedAt)
	}
	if !released.Present || released.Epoch != 2 {
		t.Errorf("the released row must still look Present with its RETAINED epoch — that is the trap; got %+v", released)
	}

	live := claimDoc(realLiveClaim).ClaimInfo()
	if !live.Live() {
		t.Errorf("a GENUINELY LIVE claim (worker=probe-r19w7) must report Live()=true; got %+v", live)
	}

	// A blank/whitespace worker is vacant, not held — matching claimVerdict.
	for _, blank := range []string{`""`, `"   "`} {
		if claimDoc(`{"epoch":3,"worker":` + blank + `}`).ClaimInfo().Live() {
			t.Errorf("worker %s is blank, not a holder", blank)
		}
	}
	if claimDoc(`null`).ClaimInfo().Live() {
		t.Errorf("a null claim is not held")
	}
	if (Doc{}).ClaimInfo().Live() {
		t.Errorf("a doc with no claim object is not held")
	}
}

// THE RETAINED EPOCH IS LOAD-BEARING. ClaimEpoch must keep reporting it off a
// RELEASED row: Barkpark.Tasks.Claim computes `next_epoch = current_epoch(doc)
// + 1` from exactly that row, and check_fencing/2 in Barkpark.Tasks.Close
// fences :fenced_off on any epoch mismatch.
// Clearing it would restart the lease numbering and let a stale holder's
// old-epoch close land on the NEXT worker.
func TestClaimEpochStillReportsTheRetainedEpochOnAReleasedRow(t *testing.T) {
	epoch, ok := claimDoc(realReleasedClaim).ClaimEpoch()
	if !ok || epoch != 2 {
		t.Fatalf("the retained epoch must survive a release unchanged (it is the next claim's base); got epoch=%d ok=%v", epoch, ok)
	}
}

// THE CONTRADICTION IS GONE — with a positive control, because an absence claim
// read off a mistyped path is a clean, meaningless pass.
func TestClaimEpochAndClaimInfoDocstringsAgree(t *testing.T) {
	src, err := os.ReadFile("doc.go")
	if err != nil {
		t.Fatalf("POSITIVE CONTROL FAILED: cannot read doc.go (%v) — every absence assertion below would pass vacuously", err)
	}
	text := string(src)

	// Positive control: the file must still document ClaimEpoch at all.
	if !strings.Contains(text, "// ClaimEpoch returns the fencing epoch") {
		t.Fatalf("POSITIVE CONTROL FAILED: doc.go no longer carries a ClaimEpoch docstring — " +
			"the absence assertions below would pass on a file that documents nothing")
	}
	if !strings.Contains(text, "// ClaimInfo is the flattened content.claim object read back RAW") {
		t.Fatalf("POSITIVE CONTROL FAILED: doc.go no longer carries the ClaimInfo docstring")
	}

	// The retracted claim itself. Probe for the SENTENCE, not a word that also
	// occurs in the replacement prose explaining why it was wrong.
	if strings.Contains(text, "whether a live claim is present") {
		t.Errorf("ClaimEpoch still asserts it reports \"whether a live claim is present\" — it does not; "+
			"a RELEASED row retains its epoch, so that bool is true for a row nobody holds (%s)", realReleasedClaim)
	}
	// The replacement must SAY what the value is and point at the predicate.
	for _, want := range []string{
		"THE BOOL IS NOT A LIVENESS ANSWER",
		"verify_task/2 in\n// api/lib/barkpark/tasks/claim_fence.ex",
		"ClaimInfo().Live()",
		"DO NOT CLEAR, ZERO OR \"NORMALISE\" IT",
		"api/lib/barkpark/tasks/claim.ex computes",
		"check_fencing/2 in\n// api/lib/barkpark/tasks/close.ex",
		"SEVEN keys",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("ClaimEpoch's docstring must carry %q — it is where the next reader meets the retained epoch", want)
		}
	}
}
