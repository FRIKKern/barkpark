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

	// ── Detail hydration guard (charter D13/D25 — the reading substrate) ─────
	// FetchSnapshotFull rides the SAME two calls as FetchSnapshot; assert every
	// task hydrates a TaskDetail (nothing dropped by an odd content map), that
	// the detail's embedded board row agrees with the snapshot after the ready
	// overlay, and that the snapshot-inversion projector returns real work for a
	// real design_doc-bearing slug — the paper→tasks edge the Papers rail walks.
	// READ-ONLY: it fetches and decodes, it never mutates a task.
	fullSnap, details, err := FetchSnapshotFull(c)
	if err != nil {
		t.Fatalf("FetchSnapshotFull: %v", err)
	}
	if len(details) != len(fullSnap.Tasks) {
		t.Fatalf("hydrated %d details for %d tasks — an odd content map dropped a task", len(details), len(fullSnap.Tasks))
	}
	paperRefTasks, withDesignDoc := 0, ""
	for _, tk := range fullSnap.Tasks {
		d, ok := details[tk.DocID]
		if !ok {
			t.Fatalf("task %q has no hydrated TaskDetail", tk.DocID)
		}
		if d.Task.DocID != tk.DocID || d.Task.Lifecycle != tk.Lifecycle {
			t.Fatalf("detail row disagrees with snapshot for %q (lifecycle %q vs %q) — syncDetails did not run",
				tk.DocID, d.Task.Lifecycle, tk.Lifecycle)
		}
		if len(d.PaperRefs()) > 0 {
			paperRefTasks++
		}
		if withDesignDoc == "" && d.DesignDoc != "" {
			withDesignDoc = d.DesignDoc
		}
	}
	fmt.Printf("detail hydration OK: %d/%d tasks carry a paper ref\n", paperRefTasks, len(fullSnap.Tasks))
	if withDesignDoc != "" {
		driven := DrivenTasks(fullSnap.Tasks, details, withDesignDoc)
		if len(driven) == 0 {
			t.Errorf("DrivenTasks(%q) returned 0 — the snapshot-inversion projector is broken on live data", withDesignDoc)
		}
		fmt.Printf("driven-tasks inversion OK: %q drives %d tasks\n", withDesignDoc, len(driven))
	} else {
		fmt.Printf("driven-tasks inversion SKIPPED: no design_doc-bearing task in the live corpus\n")
	}

	// ── Reading-frame render probe (wave 6 — the frames meet the real corpus) ──
	// RenderTaskDetail on a MEATY task (description + children + criteria), then
	// RenderPaperFrame on a real design_doc paper fetched via apiclient.PaperDoc,
	// then the HTML-only honest state. READ-ONLY: no claim/close/relabel anywhere.
	// Every rendered line is asserted width-safe at the supported widths so a real
	// title/prose/timeline can't blow out the pane or garble on truncation.
	widthSafe := func(label string, lines []string, width int) {
		for i, ln := range lines {
			if cw := disp(ln); cw > width {
				t.Errorf("%s width %d: line %d is %d cols (blowout): %q", label, width, i, cw, ln)
			}
		}
	}
	meaty := ""
	for id, d := range details {
		if strings.TrimSpace(d.Description) == "" {
			continue
		}
		if len(ChildrenOf(fullSnap.Tasks, id)) == 0 {
			continue
		}
		if d.Criteria == nil && len(d.CriteriaItems) == 0 {
			continue
		}
		meaty = id
		break
	}
	if meaty != "" {
		d := details[meaty]
		children := ChildrenOf(fullSnap.Tasks, meaty)
		for _, w := range []int{60, 80, 100} {
			body, stops := RenderTaskDetail(d, children, 0, w, now)
			if len(body) == 0 {
				t.Errorf("RenderTaskDetail(%q) produced an empty body at width %d", meaty, w)
			}
			widthSafe("detail", body, w)
			if w == 80 {
				fmt.Printf("RenderTaskDetail OK: %q → %d body lines, %d stops (children+papers)\n", d.Title, len(body), len(stops))
			}
		}
	} else {
		fmt.Printf("RenderTaskDetail SKIPPED: no task with description+children+criteria in the live corpus\n")
	}

	if withDesignDoc != "" {
		ps, perr := FetchPaper(c, "production", withDesignDoc)
		if perr != nil {
			fmt.Printf("FetchPaper(%q) failed (honest Err state rendered): %v\n", withDesignDoc, perr)
		}
		driven := DrivenTasks(fullSnap.Tasks, details, withDesignDoc)
		for _, w := range []int{60, 80, 100} {
			body, _ := RenderPaperFrame(ps, driven, fullSnap.Tasks, 0, w, now)
			if len(body) == 0 {
				t.Errorf("RenderPaperFrame(%q) produced an empty body at width %d", withDesignDoc, w)
			}
			widthSafe("paper", body, w)
		}
		fmt.Printf("RenderPaperFrame OK: %q (loading=%v htmlOnly=%v err=%q) drives %d rail tasks\n",
			ps.Slug, ps.Loading, ps.HTMLOnly, ps.Err, len(driven))
	}

	// The HTML-only honest state must render a clear browser-handoff line (never a
	// blank frame) even when no live paper happens to be HTML-only.
	htmlBody, _ := RenderPaperFrame(PaperState{Slug: "legacy", HTMLOnly: true}, nil, nil, 0, 80, now)
	joinedHTML := strings.Join(htmlBody, "\n")
	if !strings.Contains(joinedHTML, "HTML-only") {
		t.Errorf("HTML-only paper state did not render its honest browser-handoff line:\n%s", joinedHTML)
	}
	widthSafe("html-only", htmlBody, 80)
	fmt.Printf("reading-frame probe OK: detail + paper + HTML-only states render width-safe\n")

	// ── Wave-7 compact / grouped / claim-forward guard (the live-queue retune) ─
	// The whole point of wave 7: on the real guerrilla queue (119 expired claims,
	// 0 in_progress) the DEFAULT board must read as a short list of folded section
	// headers with a READY TO CLAIM head — NOT a ~130-row flat wall. Assert it on
	// the live corpus, read-only.
	def := UIState{Conn: ConnLive, LastSync: snap.FetchedAt, CollapsedEpics: map[string]bool{}}
	defaultRows := 0
	if showReadyHead(b) {
		defaultRows += len(b.ReadyHead)
	} else {
		defaultRows += len(b.Now)
	}
	activeEpics, expandedEpics := 0, 0
	for _, e := range b.Epics {
		defaultRows++ // the header row is always a stop
		if e.Active {
			activeEpics++
		}
		if !foldedEpic(def, e) {
			expandedEpics++
			defaultRows += len(e.Children)
		}
	}
	activeClusters := 0
	for _, cl := range b.Clusters {
		defaultRows++
		if cl.Active {
			activeClusters++
		}
		if !foldedCluster(def, cl) {
			defaultRows += len(cl.Tasks)
		}
	}
	if len(b.Orphans) > 0 || b.OrphansFolded > 0 {
		defaultRows++ // the loose "(no epic)" header
		if !foldedOrphans(def, b) {
			defaultRows += len(b.Orphans)
		}
	}
	// A fully-EXPANDED count (the old wave-6 default) for the compactness ratio.
	expandedRows := len(b.Now)
	for _, e := range b.Epics {
		expandedRows += 1 + len(e.Children)
	}
	for _, cl := range b.Clusters {
		expandedRows += 1 + len(cl.Tasks)
	}
	if len(b.Orphans) > 0 || b.OrphansFolded > 0 {
		expandedRows += 1 + len(b.Orphans)
	}
	fmt.Printf("wave-7: readyHead=%d readyTotal=%d showReadyHead=%v activeEpics=%d/%d expandedEpics=%d activeClusters=%d/%d orphansActive=%v\n",
		len(b.ReadyHead), b.ReadyTotal, showReadyHead(b), activeEpics, len(b.Epics), expandedEpics,
		activeClusters, len(b.Clusters), b.OrphansActive)
	fmt.Printf("wave-7: DEFAULT visible rows=%d vs fully-expanded=%d (compaction %.0f%%)\n",
		defaultRows, expandedRows, 100*(1-float64(defaultRows)/float64(max1(expandedRows))))
	// Claim-forward: with nothing in flight the band must OFFER work, never dead-end.
	if len(b.Now) == 0 {
		if !showReadyHead(b) && b.ReadyTotal > 0 {
			t.Errorf("empty NOW with %d ready tasks did not surface a READY TO CLAIM head", b.ReadyTotal)
		}
		if len(b.ReadyHead) > readyHeadMax {
			t.Errorf("ready head is %d, over the cap %d", len(b.ReadyHead), readyHeadMax)
		}
	}
	// Compact: a section auto-expands ONLY when it owns active work, so the default
	// row count must not be a flat wall — it must be dramatically shorter than the
	// fully-expanded corpus whenever there are folded sections to collapse.
	if expandedRows > 40 && defaultRows >= expandedRows {
		t.Errorf("board did not compact: default rows %d not shorter than expanded %d (flat wall)", defaultRows, expandedRows)
	}
	fmt.Printf("wave-7 guard OK: default board is compact + claim-forward on the live corpus\n")

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

// max1 floors a divisor at 1 so the compaction ratio never divides by zero.
func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}
