package taskboard

import "time"

// anim.go is the deterministic animation SEAM (charter decision 16 + the
// detection half of 17). It holds only PURE functions — the aliveness predicate,
// the one-shot flash ladder, the snapshot diff that stamps flashes, and the
// flash pruner. The heartbeat tick that DRIVES these lives in program.go; the
// render that CONSUMES Frame/Flashes lands in later slices. Keeping the logic
// pure is what makes motion golden deterministically (fixed now + explicit
// Frame) and keeps the at-rest board byte-stable by construction.
//
// The whole point of the seam is a budget: motion is a MEASUREMENT. The board
// is Alive() exactly when real work is moving (an unexpired claim in the NOW
// band), a change is still fading, or we are syncing the first snapshot — and
// only then does the heartbeat schedule a frame. At rest Alive() is false, the
// ticker stops dead, and the program receives zero ticks and paints zero frames.

// flash ladder thresholds (charter decision 17). Exclusive boundaries: a change
// is bright emphasis for its first flashBright, a dim remnant until flashFade,
// then gone. Kept as consts so FlashLevel and its table test share one truth.
const (
	flashBright = 1500 * time.Millisecond // < 1.5s → level 2 (bright)
	flashFade   = 4 * time.Second         // < 4s   → level 1 (fading), else 0
)

// Alive reports whether the board is doing real work RIGHT NOW — the sole
// predicate the heartbeat consults to decide whether to schedule another frame.
// It is true iff any of:
//
//   - the NOW band holds at least one unexpired live claim (BuildBoard already
//     filters Board.Now to worker-held in_progress claims, so a non-empty band
//     IS an unexpired claim — the seconds ticker on those cards must keep going);
//   - some flash is still decaying (FlashLevel > 0 against now) — the one-shot
//     fade needs frames until it reaches level 0;
//   - the board is syncing (the honest first-paint state, isSyncing in render.go
//     — shared, package-level; do NOT fork the rule).
//
// At rest — no claims, no live flashes, already synced — Alive is false and the
// heartbeat stops. The now argument dates the flash decay; the NOW-band and
// syncing checks are snapshot truth and need no clock.
func Alive(b Board, st UIState, now time.Time) bool {
	if len(b.Now) > 0 {
		return true
	}
	for _, landed := range st.Flashes {
		if FlashLevel(landed, now) > 0 {
			return true
		}
	}
	// isSyncing lives in render.go (slice 20's file) but is package-level; Alive
	// reuses it rather than mirroring the ConnPolling+zero-LastSync rule, so the
	// two can never drift.
	return isSyncing(st)
}

// FlashLevel derives the one-shot fade for a change that landed at `landed`,
// observed at `now`: 2 (bright) under flashBright, 1 (fading) under flashFade,
// 0 once past flashFade. Boundaries are EXCLUSIVE (charter decision 17: "bright
// <1.5s, dim <4s") — exactly flashBright reads as fading, exactly flashFade
// reads as gone — so the ladder is table-testable with no off-by-one ambiguity.
// A zero `landed` (no flash) is always level 0, and a future `landed` (clock
// skew) reads as bright rather than negative.
func FlashLevel(landed, now time.Time) int {
	if landed.IsZero() {
		return 0
	}
	age := now.Sub(landed)
	switch {
	case age < flashBright:
		return 2
	case age < flashFade:
		return 1
	default:
		return 0
	}
}

// changedDocIDs is the pure snapshot diff behind the flash ladder (charter
// decision 17: change detection stays snapshot-diff, NEVER incremental event
// application per decision 4). It flags a task's doc id when it is either:
//
//   - new AND non-terminal (a fresh row worth marking — a task that arrives
//     already done/closed/cancelled is history, not motion, so it never flashes);
//     or
//   - present in both snapshots but MOVED: its UpdatedAt advanced, its lifecycle
//     changed, or its claim worker changed (claimed, released, or handed off).
//
// The result is caller-stamped into UIState.Flashes. Order follows next so the
// diff is deterministic. It is the caller's job (applySnapshot) to suppress the
// first-snapshot case — a cold paint has an empty prev and would otherwise flag
// the whole board (charter decision 17: cold paints are still).
func changedDocIDs(prev, next []Task) []string {
	prevByID := make(map[string]Task, len(prev))
	for _, t := range prev {
		prevByID[t.DocID] = t
	}
	var changed []string
	for _, n := range next {
		old, existed := prevByID[n.DocID]
		if !existed {
			if !isTerminal(n.Lifecycle) {
				changed = append(changed, n.DocID)
			}
			continue
		}
		if n.UpdatedAt.After(old.UpdatedAt) ||
			n.Lifecycle != old.Lifecycle ||
			claimWorker(n) != claimWorker(old) {
			changed = append(changed, n.DocID)
		}
	}
	return changed
}

// claimWorker is the claim identity used for change detection: the worker
// holding the claim, or "" when there is none. A claim landing, being released,
// or being handed to a different worker all shift this value and so flash.
func claimWorker(t Task) string {
	if t.Claim == nil {
		return ""
	}
	return t.Claim.Worker
}

// pruneFlashes drops every flash that has already faded to level 0 at `now`,
// mutating the map in place. The heartbeat calls it each tick so the flash set
// stays bounded and Alive() can go false the instant the last change decays —
// otherwise a stale zero-level entry would keep the board "alive" forever and
// the ticker would never stop. A nil map is a safe no-op.
func pruneFlashes(f map[string]time.Time, now time.Time) {
	for id, landed := range f {
		if FlashLevel(landed, now) == 0 {
			delete(f, id)
		}
	}
}
