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
//   - a doc only in prev, window NOT truncated (truncated==false): dropped — a
//     real close/deletion. A snapshot that lists every task is authoritative
//     about an absence, and the row is never resurrected.
//   - a doc only in prev, window TRUNCATED (truncated==true): the fetch is
//     desc:updated_at clamped to a fixed row count (tasks_controller.ex), so
//     over a corpus bigger than the clamp a quiet open/ready/blocked row simply
//     rotates out of the window — that is NOT the same fact as a close. A
//     NON-terminal row absent from next is therefore KEPT (appended, since it
//     has no position in next's order — next never mentioned it). A TERMINAL
//     row (done/closed/cancelled) is still dropped even under truncation: a
//     truncated window must never resurrect a closed task.
//
// The second return value is the count of rows kept this way — how many
// previously-displayed rows are outside the current window rather than
// actually closed — so the caller can surface an honest "N aged out of the
// window" notice, distinct from the ambient "showing N of M" footnote (which
// only says the corpus is bigger, never that specific rows went stale). It is
// always 0 when truncated is false.
//
// Output order: kept/incoming rows follow next's order (kept-prev rows are
// substituted in place); aged-out rows are appended after, in prev's order.
//
// Missing metadata: if EITHER side's UpdatedAt is zero (an older API envelope
// without the field), the comparison is untrustworthy, so we take the incoming
// row. This deliberately errs toward freshness — never strand a displayed row
// on missing metadata by holding a stale copy forever.
func mergeForward(prev, next []Task, truncated bool) ([]Task, int) {
	prevByID := make(map[string]Task, len(prev))
	for _, t := range prev {
		prevByID[t.DocID] = t
	}
	inNext := make(map[string]bool, len(next))
	merged := make([]Task, 0, len(next))
	for _, n := range next {
		inNext[n.DocID] = true
		if old, ok := prevByID[n.DocID]; ok &&
			!old.UpdatedAt.IsZero() && !n.UpdatedAt.IsZero() &&
			serverNewer(old, n) {
			// The incoming snapshot is stale for this row — keep what's shown.
			merged = append(merged, old)
			continue
		}
		merged = append(merged, n)
	}
	if !truncated {
		return merged, 0
	}
	agedOut := 0
	for _, p := range prev {
		if inNext[p.DocID] || isTerminal(p.Lifecycle) {
			continue
		}
		merged = append(merged, p)
		agedOut++
	}
	return merged, agedOut
}
