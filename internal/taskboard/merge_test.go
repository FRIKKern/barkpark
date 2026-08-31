package taskboard

import (
	"testing"
	"time"
)

// claimed builds a task carrying a claim at a given (UpdatedAt, Epoch) so the
// forward-only merge has both order components to compare.
func claimed(id, worker string, epoch int, updated time.Time) Task {
	return Task{
		DocID:     id,
		Title:     id,
		Lifecycle: lifeInProgress,
		UpdatedAt: updated,
		Claim:     &Claim{Worker: worker, Epoch: epoch},
	}
}

// mergeForward is forward-only per doc id: a stale incoming row is ignored (the
// shown row is kept), a server-newer incoming row is taken, rows only-in-new are
// added, rows only-in-old are dropped, and an exact UpdatedAt tie is broken by
// the higher claim epoch.
func TestMergeForward(t2 *testing.T) {
	ta := time.Unix(1000, 0) // older server time
	tb := time.Unix(2000, 0) // newer server time

	// Row present in both, incoming is STALE (older UpdatedAt) → keep the old row.
	{
		old := claimed("a", "worker", 4, tb)
		next := claimed("a", "", 3, ta) // released, but from an older server read
		got, _ := mergeForward([]Task{old}, []Task{next}, false)
		if len(got) != 1 || got[0].Claim == nil || got[0].Claim.Worker != "worker" {
			t2.Fatalf("stale incoming downgraded the row: %+v", got)
		}
		if !got[0].UpdatedAt.Equal(tb) {
			t2.Fatalf("kept row lost its server UpdatedAt: %v", got[0].UpdatedAt)
		}
	}

	// Row present in both, incoming is server-NEWER → take the new row.
	{
		old := claimed("a", "", 3, ta)
		next := claimed("a", "worker", 4, tb)
		got, _ := mergeForward([]Task{old}, []Task{next}, false)
		if len(got) != 1 || got[0].Claim == nil || got[0].Claim.Worker != "worker" {
			t2.Fatalf("server-newer incoming was not taken: %+v", got)
		}
	}

	// Row only in the new snapshot → added.
	{
		got, _ := mergeForward([]Task{claimed("a", "w", 1, ta)}, []Task{claimed("a", "w", 1, ta), t("b")}, false)
		if len(got) != 2 || got[1].DocID != "b" {
			t2.Fatalf("new-only row not added: %+v", got)
		}
	}

	// Row only in the old set, window NOT truncated → dropped (a genuine
	// close/deletion, never resurrected).
	{
		got, agedOut := mergeForward([]Task{t("a"), t("gone")}, []Task{upd("a", tb)}, false)
		if len(got) != 1 || got[0].DocID != "a" {
			t2.Fatalf("old-only row was resurrected: %+v", got)
		}
		if agedOut != 0 {
			t2.Fatalf("non-truncated merge reported %d aged-out rows, want 0", agedOut)
		}
	}

	// Exact UpdatedAt tie → the higher claim epoch wins. Old epoch 5 beats new
	// epoch 4 at the same instant → keep old.
	{
		old := claimed("a", "worker", 5, tb)
		next := claimed("a", "", 4, tb)
		got, _ := mergeForward([]Task{old}, []Task{next}, false)
		if got[0].Claim == nil || got[0].Claim.Epoch != 5 {
			t2.Fatalf("higher-epoch old row lost the UpdatedAt tie: %+v", got[0])
		}
		// ...and new epoch 6 beats old epoch 5 at the same instant → take new.
		old2 := claimed("a", "worker", 5, tb)
		next2 := claimed("a", "other", 6, tb)
		got2, _ := mergeForward([]Task{old2}, []Task{next2}, false)
		if got2[0].Claim == nil || got2[0].Claim.Epoch != 6 {
			t2.Fatalf("higher-epoch new row lost the UpdatedAt tie: %+v", got2[0])
		}
	}

	// Output order follows the incoming snapshot even when an old row is kept.
	{
		old := []Task{claimed("a", "w", 9, tb), t("b")}
		next := []Task{t("b"), claimed("a", "", 1, ta)} // a is stale → kept; order = next
		got, _ := mergeForward(old, next, false)
		if len(got) != 2 || got[0].DocID != "b" || got[1].DocID != "a" {
			t2.Fatalf("merged order did not follow the incoming snapshot: %+v", got)
		}
		if got[1].Claim == nil || got[1].Claim.Worker != "w" {
			t2.Fatalf("kept-in-place row lost its shown state: %+v", got[1])
		}
	}
}

// openAt builds a non-terminal OPEN task with a given old UpdatedAt — the
// exact shape of a quiet row that rotates out of the 1000-row desc:updated_at
// window long before it is ever touched again.
func openAt(id string, updated time.Time) Task {
	return Task{DocID: id, Title: id, Lifecycle: lifeOpen, UpdatedAt: updated}
}

// TestMergeForwardTruncatedKeepsNonTerminalRow is the truncation case: when
// truncated is true, a previously-displayed OPEN row absent from next is kept
// — not silently dropped as a close — and the kept count (the aged-out
// notice's source) reflects it. Reverting mergeForward to ignore `truncated`
// reds this case (see the mutation-proof evidence on the bp task).
func TestMergeForwardTruncatedKeepsNonTerminalRow(t2 *testing.T) {
	ta := time.Unix(1000, 0)
	old := openAt("a", ta) // quiet OPEN row, last touched long ago
	prev := []Task{old}
	next := []Task{t("b")} // the 1000-row window no longer mentions "a" at all

	got, agedOut := mergeForward(prev, next, true)

	var kept *Task
	for i := range got {
		if got[i].DocID == "a" {
			kept = &got[i]
		}
	}
	if kept == nil {
		t2.Fatalf("truncated window dropped a non-terminal row instead of keeping it: %+v", got)
	}
	if kept.Lifecycle != lifeOpen {
		t2.Fatalf("kept row changed lifecycle: %+v", kept)
	}
	// The row must be visibly distinguished from an ordinary fresh row, not
	// silently retained as if nothing happened: mergeForward reports it through
	// the aged-out count (live.go turns this into the per-refresh notice).
	if agedOut != 1 {
		t2.Fatalf("aged-out count = %d, want 1 — the kept row must be marked, not silently retained", agedOut)
	}
}

// TestMergeForwardTruncatedStillDropsTerminalRow: even under truncation, a
// prev-only TERMINAL row (done/cancelled) is still dropped — a truncated
// window must never resurrect a closed task.
func TestMergeForwardTruncatedStillDropsTerminalRow(t2 *testing.T) {
	ta := time.Unix(1000, 0)
	done := Task{DocID: "a", Title: "a", Lifecycle: lifeDone, UpdatedAt: ta}
	cancelled := Task{DocID: "c", Title: "c", Lifecycle: lifeCancelled, UpdatedAt: ta}
	prev := []Task{done, cancelled}
	next := []Task{t("b")}

	got, agedOut := mergeForward(prev, next, true)

	for _, row := range got {
		if row.DocID == "a" || row.DocID == "c" {
			t2.Fatalf("truncated window resurrected a terminal row: %+v", got)
		}
	}
	if agedOut != 0 {
		t2.Fatalf("aged-out count = %d, want 0 — terminal rows never count as aged-out", agedOut)
	}
}

// TestMergeForwardNonTruncatedByteIdentical: with truncated explicitly false,
// a non-terminal prev-only row is STILL dropped exactly as before this change
// — truncation awareness must never alter the untruncated path.
func TestMergeForwardNonTruncatedByteIdentical(t2 *testing.T) {
	ta := time.Unix(1000, 0)
	open := openAt("a", ta)
	prev := []Task{open, t("gone")}
	next := []Task{t("b")}

	got, agedOut := mergeForward(prev, next, false)

	if len(got) != 1 || got[0].DocID != "b" {
		t2.Fatalf("non-truncated merge resurrected a prev-only row: %+v", got)
	}
	if agedOut != 0 {
		t2.Fatalf("non-truncated merge reported %d aged-out rows, want 0", agedOut)
	}
}

// A zero/missing UpdatedAt on either side is untrusted: take the incoming row so
// a row is never stranded on missing metadata (older API without the field).
func TestMergeForwardMissingMetadataTakesNew(t2 *testing.T) {
	tb := time.Unix(2000, 0)

	// Incoming has no UpdatedAt (zero) while the shown row does. Without the
	// guard, serverNewer(old,new) would be true forever and strand the old row.
	old := claimed("a", "worker", 4, tb)
	next := Task{DocID: "a", Title: "a", Lifecycle: lifeReady} // zero UpdatedAt
	got, _ := mergeForward([]Task{old}, []Task{next}, false)
	if len(got) != 1 || got[0].Claim != nil {
		t2.Fatalf("missing-metadata incoming row was not taken (row stranded): %+v", got[0])
	}
}
