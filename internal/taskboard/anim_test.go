package taskboard

import (
	"sort"
	"testing"
	"time"
)

// animBase is the reference clock the flash-ladder tables are laid out against.
var animBase = time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)

// FlashLevel is the one-shot fade ladder: 2 bright under 1.5s, 1 fading under
// 4s, 0 after — EXCLUSIVE boundaries so exactly-1.5s already fades and
// exactly-4s is already gone (charter decision 17).
func TestFlashLevelLadder(t *testing.T) {
	cases := []struct {
		name   string
		landed time.Time
		now    time.Time
		want   int
	}{
		{"zero landed is never lit", time.Time{}, animBase, 0},
		{"just landed is bright", animBase, animBase, 2},
		{"still bright below 1.5s", animBase, animBase.Add(1400 * time.Millisecond), 2},
		{"exactly 1.5s has faded to dim", animBase, animBase.Add(1500 * time.Millisecond), 1},
		{"dim just below 4s", animBase, animBase.Add(3900 * time.Millisecond), 1},
		{"exactly 4s is gone", animBase, animBase.Add(4 * time.Second), 0},
		{"long past is gone", animBase, animBase.Add(30 * time.Second), 0},
		{"future landed (clock skew) reads bright, never negative", animBase, animBase.Add(-2 * time.Second), 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := FlashLevel(c.landed, c.now); got != c.want {
				t.Errorf("FlashLevel(%v) = %d, want %d", c.now.Sub(c.landed), got, c.want)
			}
		})
	}
}

// changedDocIDs is the pure snapshot diff. It flags new-and-non-terminal tasks
// and existing tasks whose UpdatedAt moved, lifecycle changed, or claim worker
// changed — and nothing else. A terminal task arriving fresh is history, not
// motion, and must NOT flash (charter decision 17).
func TestChangedDocIDs(t *testing.T) {
	// task builds a Task with an explicit updated time + optional claim worker.
	task := func(id, life string, updated time.Time, worker string) Task {
		out := Task{DocID: id, Title: id, Lifecycle: life, UpdatedAt: updated}
		if worker != "" {
			out.Claim = &Claim{Worker: worker, ClaimedAt: updated}
		}
		return out
	}
	u := animBase

	prev := []Task{
		task("stable", lifeReady, u, ""),           // unchanged → no flash
		task("moved", lifeReady, u, ""),            // UpdatedAt advances → flash
		task("relifed", lifeReady, u, ""),          // lifecycle changes → flash
		task("claimed", lifeReady, u, ""),          // gains a claim worker → flash
		task("handed", lifeInProgress, u, "alice"), // worker changes → flash
		task("released", lifeInProgress, u, "bob"), // loses its worker → flash
	}
	next := []Task{
		task("stable", lifeReady, u, ""),
		task("moved", lifeReady, u.Add(time.Minute), ""),
		task("relifed", lifeInProgress, u, ""),
		task("claimed", lifeReady, u, "carol"),
		task("handed", lifeInProgress, u, "dave"),
		task("released", lifeInProgress, u, ""),
		task("newlive", lifeReady, u, ""),    // new + non-terminal → flash
		task("newdone", lifeDone, u, ""),     // new + terminal → NO flash
		task("newclosed", lifeClosed, u, ""), // new + terminal → NO flash
	}

	got := changedDocIDs(prev, next)
	sort.Strings(got)
	want := []string{"claimed", "handed", "moved", "newlive", "released", "relifed"}
	if len(got) != len(want) {
		t.Fatalf("changedDocIDs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("changedDocIDs = %v, want %v", got, want)
		}
	}
}

// A brand-new task that is already terminal never flashes — regression guard for
// the "terminal-new-task NOT flashing" contract on its own.
func TestChangedDocIDsTerminalNewTaskDoesNotFlash(t *testing.T) {
	next := []Task{{DocID: "d", Title: "d", Lifecycle: lifeDone, UpdatedAt: animBase}}
	if got := changedDocIDs(nil, next); len(got) != 0 {
		t.Fatalf("a fresh terminal task flashed: %v", got)
	}
}

// Alive is true iff the NOW band has an unexpired claim, some flash is still
// decaying, or the board is syncing — and false at rest.
func TestAlive(t *testing.T) {
	syncing := UIState{Conn: ConnPolling} // LastSync zero → isSyncing true
	synced := UIState{Conn: ConnLive, LastSync: animBase.Add(-time.Minute)}

	t.Run("now claim keeps it alive", func(t *testing.T) {
		b := Board{Now: []Task{claimedTask("c1", 1)}}
		if !Alive(b, synced, animBase) {
			t.Fatal("a NOW claim did not read as alive")
		}
	})
	t.Run("a decaying flash keeps it alive", func(t *testing.T) {
		ui := synced
		ui.Flashes = map[string]time.Time{"x": animBase.Add(-time.Second)} // level 1
		if !Alive(Board{}, ui, animBase) {
			t.Fatal("a fading flash did not read as alive")
		}
	})
	t.Run("a fully-decayed flash is at rest", func(t *testing.T) {
		ui := synced
		ui.Flashes = map[string]time.Time{"x": animBase.Add(-10 * time.Second)} // level 0
		if Alive(Board{}, ui, animBase) {
			t.Fatal("an expired flash still read as alive")
		}
	})
	t.Run("syncing is alive", func(t *testing.T) {
		if !Alive(Board{}, syncing, animBase) {
			t.Fatal("the syncing first paint did not read as alive")
		}
	})
	t.Run("an empty synced board is at rest", func(t *testing.T) {
		if Alive(Board{}, synced, animBase) {
			t.Fatal("an empty, synced, flashless board read as alive")
		}
	})
}

// pruneFlashes drops only the entries that have already decayed to level 0,
// leaving the still-fading ones — so Alive() can go false the instant the last
// change decays. A nil map is a safe no-op.
func TestPruneFlashes(t *testing.T) {
	f := map[string]time.Time{
		"fresh": animBase.Add(-time.Second),      // level 1 → kept
		"stale": animBase.Add(-10 * time.Second), // level 0 → dropped
	}
	pruneFlashes(f, animBase)
	if _, ok := f["stale"]; ok {
		t.Error("pruneFlashes kept a fully-decayed entry")
	}
	if _, ok := f["fresh"]; !ok {
		t.Error("pruneFlashes dropped a still-fading entry")
	}

	// nil map must not panic.
	pruneFlashes(nil, animBase)
}
