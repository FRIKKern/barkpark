package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Claim-liveness pins for `bp cmux status` (task-6d7b68c7c0e7e8cc).
//
// hydrateLease used to set HasClaim from apiclient.Doc.ClaimEpoch's bool. A
// RELEASED row KEEPS its epoch, so that bool is true for a row nobody holds and
// `bp cmux status` rendered `held by — · epoch 2 · ~44m34s left` with
// "has_claim": true. The `(no live claim on this task)` branch was therefore
// unreachable for released rows — the only rows it actually matters for.
//
// EVERY claim object below is VERBATIM from guerrilla.barkpark.cloud, produced
// by claiming and then releasing a real row through the real `bp task claim` /
// `bp task release` verbs — never hand-built, because a fixture you wrote
// yourself cannot tell you the real code emits that shape.

// releasedClaimSessionBearing is task-75feee3462657b3e's claim after
// `bp task claim … probe-r19w7` then `bp task release … probe-r19w7 1`.
// NINE keys, because the claim carried a session. worker is JSON NULL and the
// epoch is RETAINED — and advanced to 2 by the release.
const releasedClaimSessionBearing = `{
  "epoch": 2,
  "released_at": "2026-09-15T08:49:36.925818Z",
  "released_by": "probe-r19w7",
  "session": "s_a27da76950c664eb",
  "session_origin": "s_a27da76950c664eb",
  "ts_iso": "2026-09-15T08:49:23.603626Z",
  "work_digest": "10ed0509bd041c7f",
  "work_field_digests": {"title": "e43f51a1d2557b5b"},
  "worker": null
}`

// releasedClaimSevenKey is the SEVEN-key baseline an ordinary unpulsed,
// non-session-bearing release leaves: epoch, released_at, released_by, ts_iso,
// work_digest, work_field_digests, worker. "now" appears only after a pulse.
// Pinned so no future assertion is written against a ten-key shape.
const releasedClaimSevenKey = `{
  "epoch": 2,
  "released_at": "2026-09-15T08:49:36.925818Z",
  "released_by": "probe-r19w7",
  "ts_iso": "2026-09-15T08:49:23.603626Z",
  "work_digest": "10ed0509bd041c7f",
  "work_field_digests": {"title": "e43f51a1d2557b5b"},
  "worker": null
}`

// liveClaim is task-ac96e3a252d2cebd's claim while GENUINELY HELD, verbatim.
const liveClaim = `{
  "epoch": 1,
  "lease_expires_at": "2026-09-15T09:39:27.618048Z",
  "lease_seconds": 2700,
  "session": "s_a27da76950c664eb",
  "session_origin": "s_a27da76950c664eb",
  "ts_iso": "2026-09-15T08:54:27.618048Z",
  "work_digest": "3748a7a4222d04cf",
  "work_field_digests": {"title": "08ca520b17fb61ae"},
  "worker": "probe-r19w7"
}`

func docWithClaim(t *testing.T, claimJSON, lifecycle string) apiclient.Doc {
	t.Helper()
	extra := map[string]json.RawMessage{
		"lifecycle_status": json.RawMessage(`"` + lifecycle + `"`),
	}
	if claimJSON != "" {
		extra["claim"] = json.RawMessage(claimJSON)
	}
	return apiclient.Doc{ID: "task-probe", Extra: extra}
}

// PRECONDITION CONTROL. The three fixtures must actually differ in the way the
// defect turns on — otherwise every verdict below is vacuous. A released row
// must present a claim object, a non-zero epoch, AND a worker key, so that
// Present / Epoch != 0 / has("worker") are all FALSE POSITIVES and only the
// worker VALUE discriminates.
func TestReleasedFixturesAreIndistinguishableFromLiveExceptByWorkerValue(t *testing.T) {
	for name, fixture := range map[string]string{
		"session-bearing": releasedClaimSessionBearing,
		"seven-key":       releasedClaimSevenKey,
	} {
		var m map[string]any
		if err := json.Unmarshal([]byte(fixture), &m); err != nil {
			t.Fatalf("%s: fixture is not JSON: %v", name, err)
		}
		if _, ok := m["worker"]; !ok {
			t.Fatalf("%s: fixture must CARRY a worker key (set to null) — without it this pins nothing", name)
		}
		if m["worker"] != nil {
			t.Fatalf("%s: a released row's worker must be JSON null, got %v", name, m["worker"])
		}
		info := docWithClaim(t, fixture, "open").ClaimInfo()
		if !info.Present || info.Epoch == 0 {
			t.Fatalf("%s: released fixture must look present with a retained epoch (Present=%v Epoch=%d) — that IS the trap",
				name, info.Present, info.Epoch)
		}
	}
	if n := len(strings.Split(strings.TrimSpace(sevenKeyList()), " ")); n != 7 {
		t.Fatalf("the released keyset baseline is SEVEN, got %d", n)
	}
	var seven map[string]any
	_ = json.Unmarshal([]byte(releasedClaimSevenKey), &seven)
	if len(seven) != 7 {
		t.Fatalf("releasedClaimSevenKey must hold exactly 7 keys, got %d: %v", len(seven), seven)
	}
}

func sevenKeyList() string {
	return "epoch released_at released_by ts_iso work_digest work_field_digests worker"
}

// THE DEFECT. A row released through the real release path is NOT held, and
// `bp cmux status` must reach the `(no live claim on this task)` branch.
//
// Reverting hydrateLease to `if epoch, ok := doc.ClaimEpoch(); ok { HasClaim = true }`
// REDS THIS TEST BY NAME, on the released-row fixture, quoting the phantom
// `held by —` line.
func TestCmuxStatusReleasedRowIsNotHeldAndReachesTheNoLiveClaimBranch(t *testing.T) {
	for name, fixture := range map[string]string{
		"session-bearing release": releasedClaimSessionBearing,
		"seven-key release":       releasedClaimSevenKey,
	} {
		st := cmuxStatus{Worker: "w", Task: "task-75feee3462657b3e"}
		st.hydrateLease(docWithClaim(t, fixture, "open"))

		if st.HasClaim {
			t.Errorf("%s: MISCLASSIFIED RELEASED ROW — task-75feee3462657b3e was claimed then RELEASED through the real verbs, "+
				"its claim is {worker: null, epoch: %d, released_at: %q}, and hydrateLease reports HasClaim=true. "+
				"That is a phantom holder: the epoch is retained for the NEXT claim, not for a live one",
				name, st.ClaimEpoch, st.ReleasedAtISO)
		}
		if st.ClaimEpoch != 2 {
			t.Errorf("%s: the retained epoch must still be READ (it is the base the next claim increments); got %d", name, st.ClaimEpoch)
		}

		var buf bytes.Buffer
		out := newWriter(&buf, &buf)
		out.output = "table"
		renderCmuxStatus(out, st)
		got := buf.String()
		if !strings.Contains(got, "(no live claim on this task)") {
			t.Errorf("%s: the `(no live claim on this task)` branch must be REACHED for a released row; rendered:\n%s", name, got)
		}
		if strings.Contains(got, "held by") {
			t.Errorf("%s: MISCLASSIFIED RELEASED ROW rendered a holder line:\n%s", name, got)
		}
		if !strings.Contains(got, "retains epoch 2") {
			t.Errorf("%s: the released line must name the retained epoch so nobody files clearing it as a cleanup; rendered:\n%s", name, got)
		}
	}
}

// THE SECOND ARM, and it is not optional. A change that reports "not held" for
// everything passes the test above and is a WORSE bug than the one it replaces.
// Deleting the worker-value read (returning false unconditionally from
// ClaimInfo.Live) REDS THIS.
func TestCmuxStatusGenuinelyLiveClaimStillReportsHeld(t *testing.T) {
	st := cmuxStatus{Worker: "w", Task: "task-ac96e3a252d2cebd"}
	st.hydrateLease(docWithClaim(t, liveClaim, "in_progress"))

	if !st.HasClaim {
		t.Fatalf("a GENUINELY LIVE claim (worker=probe-r19w7, captured while held) must report held, got HasClaim=false")
	}
	if st.ClaimWorker != "probe-r19w7" || st.ClaimEpoch != 1 {
		t.Fatalf("live claim must carry its holder and epoch, got worker=%q epoch=%d", st.ClaimWorker, st.ClaimEpoch)
	}
	var buf bytes.Buffer
	out := newWriter(&buf, &buf)
	out.output = "table"
	renderCmuxStatus(out, st)
	got := buf.String()
	if !strings.Contains(got, "held by probe-r19w7") {
		t.Errorf("a live claim must render its holder; rendered:\n%s", got)
	}
	if strings.Contains(got, "(no live claim on this task)") {
		t.Errorf("a live claim must NOT take the no-claim branch; rendered:\n%s", got)
	}
}

// POSITIVE CONTROL for the absence case: a row that was NEVER claimed carries
// no claim object at all and must also reach the branch — proving the branch
// text above is not matched by accident.
func TestCmuxStatusNeverClaimedRowAlsoReachesTheNoLiveClaimBranch(t *testing.T) {
	st := cmuxStatus{Worker: "w", Task: "task-never"}
	st.hydrateLease(docWithClaim(t, "", "open"))
	if st.HasClaim {
		t.Fatalf("a row with no claim object must not report held")
	}
	var buf bytes.Buffer
	out := newWriter(&buf, &buf)
	out.output = "table"
	renderCmuxStatus(out, st)
	got := buf.String()
	if !strings.Contains(got, "(no live claim on this task)") {
		t.Fatalf("never-claimed row must reach the branch; rendered:\n%s", got)
	}
	if strings.Contains(got, "retains epoch") {
		t.Errorf("a never-claimed row has no retained epoch to name; rendered:\n%s", got)
	}
}
