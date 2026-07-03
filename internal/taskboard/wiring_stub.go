package taskboard

// wiring_stub.go — TEMPORARY cross-slice contract stubs for wave-4 slice 20
// (motion paint). These are the frozen signatures OWNED by sibling slices that
// this slice's render/motion code links against; the epic lead DELETES this
// whole file at merge, when the real implementations land:
//
//   - Alive / FlashLevel        → slice 18 (anim.go)
//   - CriteriaChecklist         → slice 19 (components.go)
//
// NOTE on StatusGlyph: the charter's wave-4 stub list also names slice 19's
// StatusGlyph(lifecycle string, frame int) string. It is DELIBERATELY not
// stubbed here — components.go already defines the wave-3 StatusGlyph(lifecycle
// string) string, and Go forbids two functions of the same name in one package,
// so a second declaration would not compile. Slice 20 never calls the framed
// StatusGlyph anyway (the motion paint touches titles, elapsed and the ticker
// head, none of which re-glyph a row), so nothing here needs it. Slice 19's
// branch owns the signature change on components.go.

import "time"

// FlashLevel is slice 18's one-shot flash ladder (decision 17): 2 = bright
// emphasis (<1.5s since the change landed), 1 = a fading remnant (<4s), 0 =
// gone. Thresholds are exclusive and the zero landed-time (no recorded change)
// is always 0, so a still row never flashes. A future-stamped landing (clock
// skew) clamps to the brightest level rather than rendering as already-gone.
// This stub carries the real behaviour so slice 20's render tests are honest;
// slice 18's anim.go supersedes it at merge.
func FlashLevel(landed, now time.Time) int {
	if landed.IsZero() {
		return 0
	}
	d := now.Sub(landed)
	if d < 0 { // clock skew — treat a just-landed/future stamp as freshest
		d = 0
	}
	switch {
	case d < 1500*time.Millisecond:
		return 2
	case d < 4*time.Second:
		return 1
	default:
		return 0
	}
}

// Alive is slice 18's aliveness budget: true iff the board has real motion to
// animate (unexpired claims, a still-decaying flash, or a sync in flight), so
// the heartbeat schedules ticks ONLY then and the at-rest board paints zero
// frames. Slice 20 does not consume it — the ticker head gates on b.Now/syncing
// directly — but it is stubbed for the contract; slice 18 supersedes it.
func Alive(b Board, st UIState, now time.Time) bool {
	if len(b.Now) > 0 || isSyncing(st) {
		return true
	}
	for _, landed := range st.Flashes {
		if FlashLevel(landed, now) > 0 {
			return true
		}
	}
	return false
}

// CriteriaChecklist is slice 19's expanded-detail acceptance-criteria checklist
// (decision 18). Slice 20 does not render it; the stub exists only so the frozen
// symbol resolves on this branch. Slice 19's components.go supersedes it.
func CriteriaChecklist(items []CriterionItem, c *Criteria, indent, width int) []string {
	return nil
}
