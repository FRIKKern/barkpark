package taskboard

import (
	"strings"
	"testing"
	"time"
)

// claimforward_test.go — the TWO ARMS for ClaimForwardViolations (task
// p-claim-forward criterion 3).
//
// Present-in-file is not fires-when-it-should. A contract checker that returns
// "no violations" on everything is worse than no checker, because it launders
// a broken board into a green. So this file pairs, deliberately:
//
//	ARM A (FIRES)  — TestClaimForwardCheckerCatchesEachBreach injects one
//	                 breach per criterion into a board built from the REAL
//	                 corpus fixture and demands the checker name it. Delete the
//	                 corresponding branch of ClaimForwardViolations and exactly
//	                 that sub-test reds.
//	ARM B (QUIET)  — TestClaimForwardCheckerIsQuietOnHonestBoards runs the
//	                 checker over boards that are CORRECT, including the honest
//	                 nothing-ready board and a legal resumable-only strip. A
//	                 checker that fired on "no ready work" would red here.
//
// Both arms drive the REAL BuildBoard over the REAL corpusSnapshot fixture, so
// what they check is the shipped resolveNext policy, not a hand-built Board.

// cfBoard builds the real corpus board at the corpus clock.
func cfBoard(t *testing.T) (Snapshot, Board) {
	t.Helper()
	s := corpusSnapshot()
	b := BuildBoard(s, RepoContext{}, corpusFixedNow)
	if len(b.Next) == 0 {
		t.Fatal("precondition: the corpus board surfaces no NEXT strip — the fixture no longer exercises claim-forward")
	}
	readyOutsideNow := 0
	nowSet := map[string]bool{}
	for _, tk := range b.Now {
		nowSet[bareID(tk.DocID)] = true
	}
	for _, tk := range collapseDraftTwins(s.Tasks) {
		if tk.Lifecycle == lifeReady && !nowSet[bareID(tk.DocID)] {
			readyOutsideNow++
		}
	}
	if readyOutsideNow == 0 {
		t.Fatal("precondition: the corpus holds no ready work outside NOW — C0 would be vacuous")
	}
	return s, b
}

// emptySnapshot is a board state with NOTHING ready: one done task, no events.
func emptySnapshot() Snapshot {
	return Snapshot{
		Tasks:     []Task{ctask("only", "a closed thing", lifeDone, "")},
		Counts:    map[string]int{"done": 1},
		FetchedAt: corpusFixedNow,
	}
}

func TestClaimForwardCheckerCatchesEachBreach(t *testing.T) {
	s, b := cfBoard(t)

	t.Run("C0 empty strip while ready work exists", func(t *testing.T) {
		broken := b
		broken.Next = nil
		v := ClaimForwardViolations(s, broken)
		if !anyHas(v, "C0:") {
			t.Fatalf("checker did not catch an empty NEXT strip over ready work; got %v", v)
		}
	})

	t.Run("C1 ready row that is not in the overlay", func(t *testing.T) {
		broken := b
		ghost := ctask("ghost-not-in-corpus", "a row nobody can claim", lifeOpen, "1")
		broken.Next = []NextItem{{Task: ghost, Kind: nextReady}}
		v := ClaimForwardViolations(s, broken)
		if !anyHas(v, "dead claim target") {
			t.Fatalf("checker did not catch a NEXT row outside the ready overlay; got %v", v)
		}
	})

	t.Run("C1 ready row already pinned in NOW", func(t *testing.T) {
		if len(b.Now) == 0 {
			t.Fatal("precondition: the corpus board pins nothing in NOW")
		}
		pinned := b.Now[0]
		pinned.Lifecycle = lifeReady // make it pass the overlay check, so ONLY the NOW clause can fire
		broken := b
		broken.Next = []NextItem{{Task: pinned, Kind: nextReady}}
		s2 := s
		s2.Tasks = append(append([]Task{}, s.Tasks...), pinned)
		v := ClaimForwardViolations(s2, broken)
		if !anyHas(v, "already pinned in NOW") {
			t.Fatalf("checker did not catch a NEXT row duplicating a NOW claim; got %v", v)
		}
	})

	t.Run("C1 terminal resumable", func(t *testing.T) {
		broken := b
		broken.Next = append([]NextItem{{
			Task: ctask("closed-resume", "already done", lifeDone, ""),
			Kind: nextResume, LeaseExpiredAt: corpusFixedNow.Add(-time.Hour),
		}}, b.Next...)
		v := ClaimForwardViolations(s, broken)
		if !anyHas(v, "as a resumable — dead claim target") {
			t.Fatalf("checker did not catch a terminal resumable; got %v", v)
		}
	})

	t.Run("C1 resumable still held by a live worker", func(t *testing.T) {
		held := ctask("held-resume", "somebody is on it", lifeInProgress, "1")
		held.Claim = &Claim{Worker: "opus-7", Epoch: 1, ClaimedAt: corpusFixedNow.Add(-time.Minute)}
		broken := b
		broken.Next = append([]NextItem{{Task: held, Kind: nextResume}}, b.Next...)
		v := ClaimForwardViolations(s, broken)
		if !anyHas(v, "still holds it") {
			t.Fatalf("checker did not catch a resumable under a live claim; got %v", v)
		}
	})

	t.Run("C2 fabricated ready row on a nothing-ready board", func(t *testing.T) {
		es := emptySnapshot()
		broken := BuildBoard(es, RepoContext{}, corpusFixedNow)
		if len(broken.Next) != 0 {
			t.Fatalf("precondition: the nothing-ready board already surfaces %d NEXT rows", len(broken.Next))
		}
		broken.Next = []NextItem{{Task: ctask("invented", "claim me", lifeOpen, "1"), Kind: nextReady}}
		v := ClaimForwardViolations(es, broken)
		if !anyHas(v, "C2:") {
			t.Fatalf("checker did not catch a fabricated claim control on an empty board; got %v", v)
		}
	})
}

func TestClaimForwardCheckerIsQuietOnHonestBoards(t *testing.T) {
	t.Run("the real corpus board keeps the contract", func(t *testing.T) {
		s, b := cfBoard(t)
		if v := ClaimForwardViolations(s, b); len(v) != 0 {
			t.Fatalf("the shipped board violates claim-forward on the corpus fixture: %v", v)
		}
	})

	t.Run("nothing ready degrades honestly and the checker stays quiet", func(t *testing.T) {
		es := emptySnapshot()
		b := BuildBoard(es, RepoContext{}, corpusFixedNow)
		if len(b.Next) != 0 {
			t.Fatalf("a nothing-ready board surfaced %d NEXT rows — a dead control", len(b.Next))
		}
		if v := ClaimForwardViolations(es, b); len(v) != 0 {
			t.Fatalf("checker fired on an honest empty board: %v", v)
		}
	})

	t.Run("a legal resumable on a nothing-ready board is not a violation", func(t *testing.T) {
		es := emptySnapshot()
		b := BuildBoard(es, RepoContext{}, corpusFixedNow)
		b.Next = []NextItem{{
			Task: ctask("dropped", "a lapsed lease, nobody on it", lifeOpen, "1"),
			Kind: nextResume, LeaseExpiredAt: corpusFixedNow.Add(-30 * time.Minute),
		}}
		if v := ClaimForwardViolations(es, b); len(v) != 0 {
			t.Fatalf("checker treated a follow-up resumable as a fabricated ready row: %v", v)
		}
	})
}

func anyHas(v []string, want string) bool {
	for _, s := range v {
		if strings.Contains(s, want) {
			return true
		}
	}
	return false
}
