package taskboard

// merge.go owns the per-row forward-only snapshot reconciliation that sits
// UNDER the coarse FetchedAt out-of-order guard in applySnapshot.
//
// Why it exists: FetchedAt is the CLIENT wall clock (fetch.go stamps it with
// time.Now at the IO boundary), so it orders FETCHES, not DATA freshness. A
// backstop poll or a post-action reconcile can read slightly-stale server rows
// yet land with a NEWER client timestamp — it passes the FetchedAt guard and,
// under a blind whole-board replace, would REVERT a row the user just saw
// advance (CLAIMED → unclaimed → CLAIMED flicker on the next poll).
//
// The fix: reconcile the incoming snapshot against the currently-displayed rows
// per doc id, keeping whichever row is newer in SERVER truth — UpdatedAt, then
// claim Epoch as the tie-break. A displayed row can then only ever move FORWARD
// in (UpdatedAt, Epoch); a stale snapshot can never downgrade it.

// serverNewer reports whether a is strictly newer than b in server truth: a
// later UpdatedAt wins, and on an exact UpdatedAt tie the higher claim epoch
// wins. It is a strict order (serverNewer(x, x) == false), which mergeForward
// relies on to prefer the incoming row on an exact tie.
func serverNewer(a, b Task) bool {
	if a.UpdatedAt.After(b.UpdatedAt) {
		return true
	}
	if a.UpdatedAt.Equal(b.UpdatedAt) {
		return taskEpoch(a) > taskEpoch(b)
	}
	return false
}

// taskEpoch is the server-authoritative claim generation for the row, or 0 when
// the task carries no claim. It is the tie-break used when two snapshots stamp a
// row with the exact same UpdatedAt (a claim landing bumps the epoch even when
// the second-resolution UpdatedAt is unchanged).
func taskEpoch(t Task) int {
	if t.Claim == nil {
		return 0
	}
	return t.Claim.Epoch
}

// mergeForward reconciles the incoming snapshot (next) against the currently
// displayed tasks (prev), per doc id, forward-only in server time:
//
//   - a doc present in BOTH: keep the prev row ONLY if it is server-newer than
//     the incoming row (the incoming snapshot is stale for that row); otherwise
//     take the incoming row.
//   - a doc only in next: added (a genuinely new row).
//   - a doc only in prev: dropped — a real close/deletion. Never resurrected;
//     a snapshot that no longer lists a task is authoritative about its absence.
//
// Output order follows next (kept-prev rows are substituted in place), so the
// board still tracks the fresh snapshot's ordering.
//
// Missing metadata: if EITHER side's UpdatedAt is zero (an older API envelope
// without the field), the comparison is untrustworthy, so we take the incoming
// row. This deliberately errs toward freshness — never strand a displayed row
// on missing metadata by holding a stale copy forever.
func mergeForward(prev, next []Task) []Task {
	prevByID := make(map[string]Task, len(prev))
	for _, t := range prev {
		prevByID[t.DocID] = t
	}
	merged := make([]Task, 0, len(next))
	for _, n := range next {
		if old, ok := prevByID[n.DocID]; ok &&
			!old.UpdatedAt.IsZero() && !n.UpdatedAt.IsZero() &&
			serverNewer(old, n) {
			// The incoming snapshot is stale for this row — keep what's shown.
			merged = append(merged, old)
			continue
		}
		merged = append(merged, n)
	}
	return merged
}
