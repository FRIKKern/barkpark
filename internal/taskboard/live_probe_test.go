//go:build liveprobe

package taskboard

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/charmbracelet/x/ansi"
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

	// ── Claim-forward against the LIVE ready overlay (task p-claim-forward) ──
	// The board's ready set is not authored here: composeSnapshot OVERLAYS it
	// from prime's derived ready head (storage never stores lifecycle "ready"),
	// clamped at primeReadyLimit and raced against claims landing between the
	// two fetches. A fixture cannot speak for that. ClaimForwardViolations is
	// the SAME predicate the CI arms in claimforward_test.go exercise — run
	// here against the real corpus, so "verified against the live guerrilla
	// ready overlay" means a command, not a reading.
	liveReadyOutsideNow := 0
	liveNow := map[string]bool{}
	for _, tk := range b.Now {
		liveNow[bareID(tk.DocID)] = true
	}
	for _, tk := range collapseDraftTwins(snap.Tasks) {
		if tk.Lifecycle == lifeReady && !liveNow[bareID(tk.DocID)] {
			liveReadyOutsideNow++
		}
	}
	fmt.Printf("claim-forward: overlay-ready-outside-NOW=%d next-strip=%d next-more=%d independent-ready=%d clamped=%v\n",
		liveReadyOutsideNow, len(b.Next), b.NextReadyMore, b.IndependentReady, snap.ReadyHeadClamped)
	for i, ni := range b.Next {
		kind := "ready"
		if ni.Kind == nextResume {
			kind = "resume"
		}
		fmt.Printf("  NEXT[%d] %-6s %-34q reason=%q\n", i, kind, ni.Task.DocID, ni.Reason)
	}
	if v := ClaimForwardViolations(snap, b); len(v) != 0 {
		for _, msg := range v {
			t.Errorf("claim-forward violation on the LIVE corpus: %s", msg)
		}
	} else {
		fmt.Printf("claim-forward contract OK on the live corpus (C0/C1/C2)\n")
	}
	// The live queue is never empty in practice, so assert the non-vacuous arm
	// explicitly: a pass above must have MEASURED ready work, not skipped it.
	if liveReadyOutsideNow == 0 {
		t.Log("claim-forward: live overlay held no ready work outside NOW — C0 was vacuous this run")
	} else if len(b.Next) == 0 {
		t.Errorf("claim-forward: %d ready tasks in the live overlay but the NEXT strip is empty", liveReadyOutsideNow)
	}

	// ── The agent↔task JOIN against the live corpus (wsc-bl-agent-task-join) ──
	// The join's rule is fixture-tested; what a fixture cannot say is whether the
	// EMITTER grammar it reproduces still matches the titles the live ledger
	// actually holds. Two numbers decide that, and both are read here, read-only:
	//
	//   · how many live titles slug past the emitter's 40-char slice (if this is
	//     ~0 the cap is untested by the corpus and the fixture arms are the only
	//     proof left — say so rather than passing quietly);
	//   · how many emitted slugs are shared by two or more DIFFERENT rows (the
	//     degrade-on-ambiguity path's live population).
	//
	// Then every emitted key is fed back through JoinAgentTask: a key that
	// resolves must resolve to a row whose own emitted slug IS that key, and an
	// ambiguous key must resolve to nothing. That is the contract, asserted
	// against whatever the server serves rather than against three hand-picked
	// titles.
	idx := NewAgentTaskIndex(snap.Tasks)
	overBudget := 0
	for _, tk := range collapseDraftTwins(snap.Tasks) {
		if tk.Title != "" && len(slugify(tk.Title)) > agentSlugBudget {
			overBudget++
		}
	}
	ambiguousKeys, ambiguousRows := 0, 0
	for _, key := range idx.Keys() {
		if rows := idx.Rows(key); len(rows) > 1 {
			distinct := map[string]bool{}
			for _, r := range rows {
				distinct[bareID(r.DocID)] = true
			}
			if len(distinct) > 1 {
				ambiguousKeys++
				ambiguousRows += len(distinct)
			}
		}
	}
	fmt.Printf("agent-task join: distinct-keys=%d over-40-char-titles=%d ambiguous-keys=%d ambiguous-rows=%d\n",
		idx.Len(), overBudget, ambiguousKeys, ambiguousRows)
	if overBudget == 0 {
		t.Log("agent-task join: NO live title slugs past 40 chars — the emitter cap is UNMEASURED this run; the fixture arms are the only proof")
	}
	if ambiguousKeys == 0 {
		t.Log("agent-task join: NO ambiguous emitted slug on the live corpus — the degrade path is UNMEASURED this run")
	}
	joined, degraded := 0, 0
	for _, key := range idx.Keys() {
		distinct := map[string]bool{}
		for _, r := range idx.Rows(key) {
			distinct[bareID(r.DocID)] = true
		}
		j, ok := idx.Join("build:" + key)
		if !ok {
			degraded++
			if len(distinct) == 1 {
				t.Errorf("agent-task join: the unambiguous live key %q joined to nothing", key)
			}
			continue
		}
		joined++
		if len(distinct) > 1 {
			t.Errorf("agent-task join: the ambiguous live key %q (%d distinct rows) resolved to %s — a fabricated match",
				key, len(distinct), j.Task.DocID)
		}
		if agentEmitterSlug(j.Task.Title) != key && slugify(j.Task.Title) != key {
			t.Errorf("agent-task join: key %q resolved to %q whose own slugs are %q / %q",
				key, j.Task.DocID, agentEmitterSlug(j.Task.Title), slugify(j.Task.Title))
		}
		// The two emitter grammars must land on the same row.
		if j2, ok2 := idx.Join("build:cli:" + key); !ok2 || j2.Task.DocID != j.Task.DocID {
			t.Errorf("agent-task join: the two-segment grammar disagreed on %q (ok=%v)", key, ok2)
		}
	}
	if joined == 0 {
		t.Errorf("agent-task join: not ONE live key joined — the join is inert on the real corpus")
	}
	fmt.Printf("agent-task join OK: %d/%d live keys joined, %d degraded to nothing\n", joined, idx.Len(), degraded)

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
		accounted += 1 + len(e.Children) + e.DoneFolded + e.CancelledFolded
	}
	for _, cl := range b.Clusters {
		accounted += len(cl.Tasks) + cl.DoneFolded + cl.CancelledFolded
	}
	accounted += len(b.Orphans) + b.OrphansFolded + b.OrphansCancelledFolded
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

	// ── Wave-11 ACTIVITY-FOCUS guard (charter D49–D52) ─ On the real guerrilla
	// queue the board must be ONE list: recency-ordered sections, active work shown
	// with a bounded focus window (never the flat wall), done never flooding, and
	// NO READY TO CLAIM band. Assert it on the live corpus, read-only.

	// D49: epic sections come back recency-desc (Active-first, then LastActivity).
	for i := 1; i < len(b.Epics); i++ {
		if b.Epics[i-1].Active == b.Epics[i].Active && b.Epics[i-1].LastActivity.Before(b.Epics[i].LastActivity) {
			t.Errorf("epics not recency-desc at %d: %q before %q", i, b.Epics[i-1].Root.Title, b.Epics[i].Root.Title)
		}
	}
	// D50: no ACTIVE section keeps more than doneCueMax done rows — done never floods.
	activeEpics := 0
	for _, e := range b.Epics {
		if e.Active {
			activeEpics++
		}
		if len(e.FocusSet) > 0 {
			kept := 0
			for _, c := range e.Children {
				if isTerminal(c.Lifecycle) {
					kept++
				}
			}
			if kept > doneCueMax {
				t.Errorf("epic %q keeps %d done rows in its window, over the cue %d", e.Root.DocID, kept, doneCueMax)
			}
		}
	}
	fmt.Printf("wave-11: epics=%d activeEpics=%d clusters=%d orphans=%d orphansFolded=%d\n",
		len(b.Epics), activeEpics, len(b.Clusters), len(b.Orphans), b.OrphansFolded)

	// The pure spine + full frame must survive the real corpus at every supported
	// width without panicking or overrunning the pane, AND carry NO READY TO CLAIM
	// band. Widths 56 + 72 are the REQUIRED read-only live dump (charter D55).
	st := UIState{Conn: ConnLive, LastSync: snap.FetchedAt}
	for _, w := range []int{56, 60, 70, 72, 80, 100} {
		frame := ansi.Strip(Render(b, st, w, 120, now))
		if frame == "" {
			t.Errorf("empty frame at width %d over live data", w)
		}
		if strings.Contains(frame, "READY TO CLAIM") {
			t.Errorf("width %d: the retired READY TO CLAIM band appeared on the live board", w)
		}
		for i, ln := range strings.Split(frame, "\n") {
			if cw := disp(ln); cw > w {
				t.Errorf("width %d: line %d is %d cols (over budget): %q", w, i, cw, ln)
			}
		}
		if w == 56 || w == 72 {
			fmt.Printf("\n═══ LIVE DUMP width %d ═══\n%s\n", w, frame)
		}
	}
	fmt.Printf("wave-11 guard OK: %d tasks accounted, NOW invariant held, ONE recency-ordered list, no READY TO CLAIM, frames width-safe\n", len(snap.Tasks))
}
