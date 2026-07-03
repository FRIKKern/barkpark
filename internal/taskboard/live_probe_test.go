//go:build liveprobe

package taskboard

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// TestLiveProbe is a manual wire-contract probe (go test -tags liveprobe
// -run TestLiveProbe with BP_SERVER/BP_TOKEN set). Never runs in CI.
func TestLiveProbe(t *testing.T) {
	server, token := os.Getenv("BP_SERVER"), os.Getenv("BP_TOKEN")
	if server == "" || token == "" {
		t.Skip("BP_SERVER/BP_TOKEN not set")
	}
	c := apiclient.New(apiclient.Config{BaseURL: server, Token: token})
	snap, err := FetchSnapshot(c)
	if err != nil {
		t.Fatalf("FetchSnapshot: %v", err)
	}
	fmt.Printf("tasks=%d counts=%v events=%d fetched=%s\n", len(snap.Tasks), snap.Counts, len(snap.Events), snap.FetchedAt.Format(time.RFC3339))
	ready, claims, withCriteria := 0, 0, 0
	for _, tk := range snap.Tasks {
		if tk.Lifecycle == "ready" {
			ready++
		}
		if tk.Claim != nil && tk.Claim.Worker != "" {
			claims++
		}
		if tk.Criteria != nil {
			withCriteria++
		}
	}
	fmt.Printf("overlaid-ready=%d live-claims=%d with-criteria=%d\n", ready, claims, withCriteria)
	now := time.Now().UTC()
	b := BuildBoard(snap, RepoContext{}, now)
	fmt.Printf("board: now=%d epics=%d orphans=%d orphansFolded=%d\n", len(b.Now), len(b.Epics), len(b.Orphans), b.OrphansFolded)
	for i, e := range b.Epics {
		if i >= 6 {
			break
		}
		fmt.Printf("  epic %-30q children=%d folded=%d dormant=%v\n", e.Root.Title, len(e.Children), e.DoneFolded, e.Dormant)
	}
	for i, tk := range b.Now {
		if i >= 5 {
			break
		}
		fmt.Printf("  NOW %-40q worker=%s age=%s\n", tk.Title, tk.Claim.Worker, time.Since(tk.Claim.ClaimedAt).Round(time.Minute))
	}

	// ── Live-shape regression guard ─────────────────────────────────────────
	// Wave 2 shipped on fixtures alone; this pins the invariants the real
	// guerrilla queue exercises that a fixture can't, so a future change that
	// only passes the goldens can't silently break the live shape.
	if len(snap.Tasks) == 0 {
		t.Fatal("live queue returned zero tasks — the wire contract or scope broke")
	}
	if b.TaskCount != len(snap.Tasks) {
		t.Fatalf("TaskCount %d != decoded tasks %d", b.TaskCount, len(snap.Tasks))
	}
	// The NOW guard is load-bearing: the live queue carries dozens of DONE tasks
	// that RETAIN a non-empty worker after close (close does not clear the
	// claim). Only in_progress+live-worker rows may reach NOW, or those closed
	// rows flood the pinned band. This is the single most important live-only
	// invariant — a fixture with tidy claims never exercises it.
	for _, tk := range b.Now {
		if tk.Lifecycle != lifeInProgress {
			t.Errorf("NOW holds a non-in_progress row (%q lifecycle=%q) — done+worker leak", tk.Title, tk.Lifecycle)
		}
		if tk.Claim == nil || tk.Claim.Worker == "" {
			t.Errorf("NOW holds a row with no live worker: %q", tk.Title)
		}
	}
	// Every decoded task lands somewhere accountable: a NOW card, an epic
	// (root or child, kept or folded), a DERIVED cluster (member or folded), or
	// the orphan pile (kept or folded). Clusters were added in wave 3 and hold the
	// bulk of a flat live queue — omitting them here undercounted by ~73 rows on
	// the real corpus (131 tasks) and tripped this guard on a healthy board.
	accounted := len(b.Now)
	for _, e := range b.Epics {
		accounted += 1 + len(e.Children) + e.DoneFolded
	}
	for _, cl := range b.Clusters {
		accounted += len(cl.Tasks) + cl.DoneFolded
	}
	accounted += len(b.Orphans) + b.OrphansFolded
	// NOW rows are ALSO counted among their epic/orphan home, so accounted may
	// exceed the corpus by exactly len(b.Now); it must never be short.
	if accounted < len(snap.Tasks) {
		t.Errorf("board lost tasks: accounted %d < corpus %d", accounted, len(snap.Tasks))
	}
	// ── Criteria (checklist progress) decode guard ──────────────────────────
	// criteria_progress rides the envelope as an omit-when-absent {met,total}.
	// A fixture can hand-pick tidy values; only the live corpus proves the decode
	// against whatever the server actually serves. Every present meter must be
	// sane (0 <= met <= total, total > 0) or the header's ▰▰▱ rail lies. When the
	// wave-4 per-item checklist (CriteriaItems text) lands, extend this same guard
	// to assert each item's decoded label is non-empty and the met count matches
	// the number of checked items.
	criteriaChecked := 0
	for _, tk := range snap.Tasks {
		c := tk.Criteria
		if c == nil {
			continue
		}
		criteriaChecked++
		if c.Total <= 0 {
			t.Errorf("task %q decoded criteria with non-positive total %d", tk.Title, c.Total)
		}
		if c.Met < 0 || c.Met > c.Total {
			t.Errorf("task %q decoded criteria met=%d out of range [0,%d]", tk.Title, c.Met, c.Total)
		}
	}
	fmt.Printf("criteria decode guard OK: %d meters, all in [0,total]\n", criteriaChecked)

	// The pure spine + full frame must survive the real corpus at every
	// supported width without panicking or overrunning the pane.
	st := UIState{Conn: ConnLive, LastSync: snap.FetchedAt}
	for _, w := range []int{60, 70, 80, 100} {
		frame := Render(b, st, w, 100, now)
		if frame == "" {
			t.Errorf("empty frame at width %d over live data", w)
		}
		for i, ln := range strings.Split(frame, "\n") {
			if cw := disp(ln); cw > w {
				t.Errorf("width %d: line %d is %d cols (over budget): %q", w, i, cw, ln)
			}
		}
	}
	fmt.Printf("live-shape guard OK: %d tasks accounted, NOW invariant held, frames width-safe\n", len(snap.Tasks))
}
