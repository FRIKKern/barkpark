package taskboard

import (
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// --- fixtures & helpers ------------------------------------------------------

func t(id string) Task { return Task{DocID: id, Title: id} }

// sampleBoard is a fixture exercising every row kind: two NOW cards, three
// epics (one dormant, so its children are hidden; two normal), and one orphan.
//
// Fresh (nothing collapsed) it flattens to 9 navigable rows:
//
//	0 now n1      3 child c1     6 header e3
//	1 now n2      4 child c2     7 child c3
//	2 header e1   5 header e2    8 orphan o1
//	                (e2 dormant)
func sampleBoard() Board {
	return Board{
		Now: []Task{t("n1"), t("n2")},
		Epics: []Epic{
			{Root: t("e1"), Children: []Task{t("c1"), t("c2")}},
			{Root: t("e2"), Children: []Task{t("cx")}, Dormant: true},
			{Root: t("e3"), Children: []Task{t("c3")}},
		},
		Orphans: []Task{t("o1")},
	}
}

func testModel(b Board) Model {
	m := newModel(nil, "", Config{})
	m.board = b
	return m
}

// step feeds one message through Update and type-asserts the concrete Model back.
func step(t2 *testing.T, m Model, msg tea.Msg) (Model, tea.Cmd) {
	t2.Helper()
	nm, cmd := m.Update(msg)
	mm, ok := nm.(Model)
	if !ok {
		t2.Fatalf("Update returned %T, want taskboard.Model", nm)
	}
	return mm, cmd
}

func runes(s string) tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)} }

// --- flattening --------------------------------------------------------------

func TestVisibleRowsOrderAndKinds(t2 *testing.T) {
	m := testModel(sampleBoard())
	rows := m.visibleRows()
	want := []struct {
		kind  rowKind
		docID string
	}{
		{rowNow, "n1"},
		{rowNow, "n2"},
		{rowEpicHeader, "e1"},
		{rowChild, "c1"},
		{rowChild, "c2"},
		{rowEpicHeader, "e2"}, // dormant → no children follow
		{rowEpicHeader, "e3"},
		{rowChild, "c3"},
		{rowOrphan, "o1"},
	}
	if len(rows) != len(want) {
		t2.Fatalf("got %d rows, want %d: %+v", len(rows), len(want), rows)
	}
	for i, w := range want {
		if rows[i].kind != w.kind || rows[i].docID != w.docID {
			t2.Errorf("row %d = {%v %q}, want {%v %q}", i, rows[i].kind, rows[i].docID, w.kind, w.docID)
		}
	}
}

// TestCursorParityShellRender is the shell↔render selection tripwire: for
// EVERY cursor index, the ▶ marker in the rendered frame must sit on the row
// visibleRows says the cursor is on — the row the act verbs (c/x/o) fire on.
// Wave 1 shipped with the renderer counting only spine tasks while the shell
// counted NOW cards + epic headers too, so the highlight was offset from the
// acted-on row; this pins the repaired parity forever.
func TestCursorParityShellRender(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Conn = ConnLive
	m.ui.LastSync = time.Unix(1, 0)
	m.now = func() time.Time { return time.Unix(2, 0) }
	m.width, m.height = 80, 40

	rows := m.visibleRows()
	for i, r := range rows {
		m.ui.Cursor = i
		frame := ansi.Strip(m.View())
		var marked []string
		for _, ln := range strings.Split(frame, "\n") {
			if strings.Contains(ln, "▶") {
				marked = append(marked, ln)
			}
		}
		if len(marked) != 1 {
			t2.Fatalf("cursor %d (%v %q): %d ▶-marked lines, want exactly 1\n%s",
				i, r.kind, r.docID, len(marked), frame)
		}
		// The board's titles equal the doc ids (see t()), and an epic header
		// row carries its root's title — either way the marked line must name
		// the row the shell would act on.
		if !strings.Contains(marked[0], r.docID) {
			t2.Errorf("cursor %d: marked line %q does not carry %q (kind %v)",
				i, marked[0], r.docID, r.kind)
		}
	}
}

// Folded orphans are absent from Board.Orphans by construction, so the flattened
// visible-row list — and therefore all cursor math — never touches them. The
// flat board (3 NOW claims + 45 survivors, 55 folded) navigates exactly 48 rows,
// and G lands on a real survivor, never a folded "dn*" ghost.
func TestVisibleRowsExcludeFoldedOrphans(t2 *testing.T) {
	m := testModel(BuildBoard(loadFlatSnapshot(t2), RepoContext{}, refNow))
	rows := m.visibleRows()
	if len(rows) != 48 {
		t2.Fatalf("flat board visible rows = %d, want 48 (3 NOW + 45 survivors)", len(rows))
	}
	for _, r := range rows {
		if len(r.docID) >= 2 && r.docID[:2] == "dn" {
			t2.Fatalf("folded stale-done orphan %q became a navigable row", r.docID)
		}
	}
	m, _ = step(t2, m, runes("G"))
	if m.ui.Cursor != 47 {
		t2.Fatalf("G on the flat board left cursor at %d, want 47 (last survivor)", m.ui.Cursor)
	}
}

// clusterBoard extends sampleBoard with two derived clusters (freshest-first,
// AFTER the authored epics, BEFORE the orphan) — the fixture the wave-3 cursor
// contract must survive. The first cluster's first member is a twin (⧉), so the
// parity walk also proves the twin glyph never shifts the acted-on row.
//
// Fresh (nothing collapsed) it flattens to 14 navigable rows:
//
//	0 now n1        5 header e2 (dormant)   10 clusterMember a2
//	1 now n2        6 header e3             11 clusterHeader beta
//	2 header e1     7 child c3              12 clusterMember b1
//	3 child c1      8 clusterHeader alpha   13 orphan o1
//	4 child c2      9 clusterMember a1
func clusterBoard() Board {
	b := sampleBoard()
	a1 := t("a1")
	a1.TwinOf = "a2"
	b.Clusters = []Cluster{
		{Key: "proj:alpha", Tasks: []Task{a1, t("a2")}},
		{Key: "proj:beta", Tasks: []Task{t("b1")}},
	}
	return b
}

// clusterHeaderKey mirrors the shell's fold-key namespacing for the tests.
func clusterHeaderKey(key string) string { return "cluster:" + key }

func TestVisibleRowsWithClusters(t2 *testing.T) {
	m := testModel(clusterBoard())
	rows := m.visibleRows()
	want := []struct {
		kind  rowKind
		docID string
	}{
		{rowNow, "n1"},
		{rowNow, "n2"},
		{rowEpicHeader, "e1"},
		{rowChild, "c1"},
		{rowChild, "c2"},
		{rowEpicHeader, "e2"}, // dormant → no children follow
		{rowEpicHeader, "e3"},
		{rowChild, "c3"},
		{rowClusterHeader, "cluster:proj:alpha"}, // clusters after epics
		{rowClusterMember, "a1"},
		{rowClusterMember, "a2"},
		{rowClusterHeader, "cluster:proj:beta"},
		{rowClusterMember, "b1"},
		{rowOrphan, "o1"}, // orphans last, after the clusters
	}
	if len(rows) != len(want) {
		t2.Fatalf("got %d rows, want %d: %+v", len(rows), len(want), rows)
	}
	for i, w := range want {
		if rows[i].kind != w.kind || rows[i].docID != w.docID {
			t2.Errorf("row %d = {%v %q}, want {%v %q}", i, rows[i].kind, rows[i].docID, w.kind, w.docID)
		}
	}
}

// TestCursorParityWithClusters is the wave-3 extension of the shell↔render
// tripwire: for EVERY cursor index on a board carrying NOW cards + epics +
// clusters + a folded cluster + orphans, the ▶ marker in the rendered frame must
// sit on exactly the row visibleRows says the cursor is on. A cluster header
// paints its SHORT name (prefix stripped), so its expected token is derived from
// the fold key; every other row's title equals its doc id (see t()).
func TestCursorParityWithClusters(t2 *testing.T) {
	for _, folded := range []bool{false, true} {
		m := testModel(clusterBoard())
		m.ui.Conn = ConnLive
		m.ui.LastSync = time.Unix(1, 0)
		m.now = func() time.Time { return time.Unix(2, 0) }
		m.width, m.height = 80, 60
		if folded {
			m.ui.CollapsedEpics[clusterHeaderKey("proj:alpha")] = true
		}

		rows := m.visibleRows()
		for i, r := range rows {
			m.ui.Cursor = i
			frame := ansi.Strip(m.View())
			var marked []string
			for _, ln := range strings.Split(frame, "\n") {
				if strings.Contains(ln, "▶") {
					marked = append(marked, ln)
				}
			}
			if len(marked) != 1 {
				t2.Fatalf("folded=%v cursor %d (%v %q): %d ▶-marked lines, want 1\n%s",
					folded, i, r.kind, r.docID, len(marked), frame)
			}
			want := r.docID
			if r.kind == rowClusterHeader {
				want = chipText(strings.TrimPrefix(r.docID, "cluster:")) // "cluster:proj:alpha" → "alpha"
			}
			if !strings.Contains(marked[0], want) {
				t2.Errorf("folded=%v cursor %d: marked line %q does not carry %q (kind %v)",
					folded, i, marked[0], want, r.kind)
			}
		}
	}
}

// TestClusterFoldHidesMembersAndMovesCursorAcross proves a cluster folds/unfolds
// exactly like an epic and that j/k step cleanly across the fold — the members
// leave the navigable list entirely, so the cursor never lands on a hidden row.
func TestClusterFoldHidesMembersAndMovesCursorAcross(t2 *testing.T) {
	m := testModel(clusterBoard())
	if got := len(m.visibleRows()); got != 14 {
		t2.Fatalf("unfolded cluster board = %d rows, want 14", got)
	}

	// Put the cursor on the alpha cluster header (index 8) and fold with h.
	m.ui.Cursor = 8
	m, _ = step(t2, m, runes("h"))
	if !m.ui.CollapsedEpics[clusterHeaderKey("proj:alpha")] {
		t2.Fatalf("h on a cluster header did not record the fold")
	}
	rows := m.visibleRows()
	if len(rows) != 12 { // a1 + a2 (2 members) gone
		t2.Fatalf("after folding alpha: %d rows, want 12", len(rows))
	}
	for _, r := range rows {
		if r.docID == "a1" || r.docID == "a2" {
			t2.Fatalf("folded cluster member %q is still navigable", r.docID)
		}
	}
	// j from the alpha header steps straight to the beta header (index 9 now).
	m, _ = step(t2, m, runes("j"))
	if r, _ := m.currentRow(); r.kind != rowClusterHeader || r.docID != clusterHeaderKey("proj:beta") {
		t2.Fatalf("j across the folded cluster landed on {%v %q}, want the beta header", r.kind, r.docID)
	}

	// enter on the alpha header (back up two rows) unfolds it again.
	m.ui.Cursor = 8
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.visibleRows()) != 14 {
		t2.Fatalf("enter did not unfold alpha: %d rows, want 14", len(m.visibleRows()))
	}
}

// TestActVerbsReachClusterMembers proves taskByID finds a cluster member so the
// act verbs (c/x/o) operate on it — a member is claimable/closable/openable
// exactly like an epic child, never a dead row.
func TestActVerbsReachClusterMembers(t2 *testing.T) {
	b := clusterBoard()
	b.Clusters[1].Tasks[0].Lifecycle = lifeReady // b1 is claimable
	m := testModel(b)

	if got, ok := m.taskByID("a2"); !ok || got.DocID != "a2" {
		t2.Fatalf("taskByID did not find cluster member a2: %v %+v", ok, got)
	}
	// Cursor on b1 (index 12), c fires a claim command (ready row).
	m.ui.Cursor = 12
	if r, _ := m.currentRow(); r.docID != "b1" {
		t2.Fatalf("cursor 12 is on %q, want b1", r.docID)
	}
	m2, cmd := step(t2, m, runes("c"))
	if cmd == nil {
		t2.Fatalf("c on a ready cluster member produced no claim command")
	}
	if strings.Contains(m2.ui.Strip.Message, "no task") {
		t2.Fatalf("c treated a cluster member as no-task: %q", m2.ui.Strip.Message)
	}
}

// --- cursor movement ---------------------------------------------------------

func TestCursorMovesAndClampsAtEnds(t2 *testing.T) {
	m := testModel(sampleBoard()) // 9 rows

	// k at the top is a no-op (clamps at 0).
	m, _ = step(t2, m, runes("k"))
	if m.ui.Cursor != 0 {
		t2.Fatalf("k at top moved cursor to %d, want 0", m.ui.Cursor)
	}

	// j walks down and clamps at the last row (index 8).
	for i := 0; i < 20; i++ {
		m, _ = step(t2, m, runes("j"))
	}
	if m.ui.Cursor != 8 {
		t2.Fatalf("j past the bottom left cursor at %d, want 8", m.ui.Cursor)
	}

	// G / g jump to bottom / top.
	m, _ = step(t2, m, runes("g"))
	if m.ui.Cursor != 0 {
		t2.Fatalf("g left cursor at %d, want 0", m.ui.Cursor)
	}
	m, _ = step(t2, m, runes("G"))
	if m.ui.Cursor != 8 {
		t2.Fatalf("G left cursor at %d, want 8", m.ui.Cursor)
	}

	// Arrow keys are equivalent to j/k.
	m.ui.Cursor = 4
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyUp})
	if m.ui.Cursor != 3 {
		t2.Fatalf("↑ left cursor at %d, want 3", m.ui.Cursor)
	}
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyDown})
	if m.ui.Cursor != 4 {
		t2.Fatalf("↓ left cursor at %d, want 4", m.ui.Cursor)
	}
}

// --- collapse / expand -------------------------------------------------------

func TestEnterOnEpicHeaderTogglesCollapse(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 2 // header e1

	// Collapse e1: its two children (c1, c2) drop out → 7 rows.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.ui.CollapsedEpics["e1"] {
		t2.Fatal("enter on epic header did not collapse it")
	}
	rows := m.visibleRows()
	if len(rows) != 7 {
		t2.Fatalf("after collapsing e1: %d rows, want 7", len(rows))
	}
	if rows[3].docID != "e2" { // e1 header now immediately followed by e2 header
		t2.Fatalf("row 3 after collapse = %q, want e2 header", rows[3].docID)
	}

	// enter again un-collapses.
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.ui.CollapsedEpics["e1"] {
		t2.Fatal("second enter did not un-collapse the epic")
	}
	if len(m.visibleRows()) != 9 {
		t2.Fatalf("after un-collapse: %d rows, want 9", len(m.visibleRows()))
	}
}

func TestHFoldsAndLUnfoldsDeterministically(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 6 // header e3

	// h folds; a second h is idempotent (NOT a toggle — the help text promises
	// "h / l  fold / unfold", so each key always means the same thing).
	m, _ = step(t2, m, runes("h"))
	if !m.ui.CollapsedEpics["e3"] {
		t2.Fatal("h on epic header did not fold it")
	}
	m, _ = step(t2, m, runes("h"))
	if !m.ui.CollapsedEpics["e3"] {
		t2.Fatal("second h un-folded the epic; h must be idempotent fold")
	}

	// l unfolds; a second l is idempotent.
	m, _ = step(t2, m, runes("l"))
	if m.ui.CollapsedEpics["e3"] {
		t2.Fatal("l on epic header did not unfold it")
	}
	m, _ = step(t2, m, runes("l"))
	if m.ui.CollapsedEpics["e3"] {
		t2.Fatal("second l re-folded the epic; l must be idempotent unfold")
	}
}

// A dormant epic auto-folds, but the user's explicit action must be able to
// wake it — enter (or l) on its header shows the children; enter again folds
// it back. An auto-collapse the user cannot override would be a dead end.
func TestEnterWakesDormantEpic(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 5 // header e2 (dormant, child cx hidden) → 9 rows total

	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	rows := m.visibleRows()
	if len(rows) != 10 {
		t2.Fatalf("enter on a dormant epic did not wake it: %d rows, want 10", len(rows))
	}
	if rows[6].kind != rowChild || rows[6].docID != "cx" {
		t2.Fatalf("row 6 after waking e2 = %+v, want child cx", rows[6])
	}

	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.visibleRows()) != 9 {
		t2.Fatalf("second enter did not fold the woken epic back: %d rows, want 9", len(m.visibleRows()))
	}
}

// Regression: pressing enter on a DORMANT epic means "open it". If that press
// wrote collapsed=true (the old toggle-the-map bug), the flag would stick and
// keep the epic closed even after it wakes up (new activity → Dormant=false).
func TestWakingDormantEpicLeavesNoPhantomCollapse(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 5                                    // header e2 (dormant)
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter}) // user opens it

	// The epic wakes up on the next refetch (same board, e2 no longer dormant).
	b := sampleBoard()
	b.Epics[1].Dormant = false
	m.board = b

	rows := m.visibleRows()
	if len(rows) != 10 {
		t2.Fatalf("woken epic renders folded (phantom collapse): %d rows, want 10", len(rows))
	}
}

func TestHAndLOnTaskAreNoOps(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 0 // now card n1 (a task, not a header)
	m, _ = step(t2, m, runes("l"))
	m, _ = step(t2, m, runes("h"))
	if m.ui.Expanded["n1"] {
		t2.Fatal("h/l on a task row toggled expansion; they should only fold epics")
	}
	if len(m.ui.CollapsedEpics) != 0 {
		t2.Fatalf("h/l on a task row touched CollapsedEpics: %+v", m.ui.CollapsedEpics)
	}
}

func TestEnterOnTaskTogglesExpanded(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 0 // now card n1

	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.ui.Expanded["n1"] {
		t2.Fatal("enter on a NOW card did not expand it")
	}
	// Expanding must NOT change the row count (detail is inline render, not a row).
	if len(m.visibleRows()) != 9 {
		t2.Fatalf("expanding a task changed row count to %d, want 9", len(m.visibleRows()))
	}
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.ui.Expanded["n1"] {
		t2.Fatal("second enter did not collapse the inline detail")
	}

	// enter on a child row expands that child.
	m.ui.Cursor = 3 // child c1
	m, _ = step(t2, m, tea.KeyMsg{Type: tea.KeyEnter})
	if !m.ui.Expanded["c1"] {
		t2.Fatal("enter on a child task did not expand it")
	}
}

// clampCursor keeps the selection valid when a refetch shrinks the board under it.
func TestApplySnapshotClampsCursor(t2 *testing.T) {
	m := testModel(sampleBoard())
	m.ui.Cursor = 8 // last row
	// A refetch that yields a much smaller board.
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Orphans: []Task{t("only")}}
	}
	m.now = func() time.Time { return time.Unix(1000, 0) }
	m, _ = step(t2, m, snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(1000, 0)}})
	if got := len(m.visibleRows()); got != 1 {
		t2.Fatalf("post-refetch rows = %d, want 1", got)
	}
	if m.ui.Cursor != 0 {
		t2.Fatalf("cursor not clamped after shrink: %d, want 0", m.ui.Cursor)
	}
}

// --- resize ------------------------------------------------------------------

func TestWindowResizeStoresDimensions(t2 *testing.T) {
	m := testModel(sampleBoard())
	m, _ = step(t2, m, tea.WindowSizeMsg{Width: 72, Height: 120})
	if m.width != 72 || m.height != 120 {
		t2.Fatalf("resize stored %dx%d, want 72x120", m.width, m.height)
	}
}

// --- act verbs: claim / close / open ----------------------------------------

// readyTask is a claimable row (the board overlays "ready" onto queue-ready
// tasks). claimedTask holds a live claim, so it is closable.
func readyTask(id string) Task { return Task{DocID: id, Title: id, Lifecycle: lifeReady} }

// suggestedTask is an orphan carrying a derived tag suggestion — the only shape
// the `t` verb acts on.
func suggestedTask(id, suggested string) Task {
	return Task{DocID: id, Title: id, Lifecycle: lifeOpen, Suggested: suggested}
}
func claimedTask(id string, epoch int) Task {
	return Task{DocID: id, Title: id, Lifecycle: lifeInProgress,
		Claim: &Claim{Worker: "w", Epoch: epoch, ClaimedAt: time.Unix(1000, 0)}}
}

// c on a ready row fires DoClaim with the resolved worker, then on the OK
// result flashes an ok strip and fires a reconciling refetch.
func TestClaimKeyOnReadyRowFiresClaimAndReconciles(t2 *testing.T) {
	t2.Setenv("BARKPARK_WORKER_ID", "opus-9")
	m := testModel(Board{Orphans: []Task{readyTask("r1")}})
	m.ui.Cursor = 0

	var gotDoc, gotWorker string
	m.doClaim = func(_ *apiclient.Client, docID, worker string) ActionResult {
		gotDoc, gotWorker = docID, worker
		return ActionResult{OK: true, Message: "claimed as opus-9 · epoch 1"}
	}

	m, cmd := step(t2, m, runes("c"))
	if cmd == nil {
		t2.Fatal("c on a ready row did not fire a claim command")
	}
	msg := cmd()
	res, ok := msg.(actionResultMsg)
	if !ok {
		t2.Fatalf("claim command produced %T, want actionResultMsg", msg)
	}
	if gotDoc != "r1" || gotWorker != "opus-9" {
		t2.Fatalf("DoClaim got (%q,%q), want (r1,opus-9)", gotDoc, gotWorker)
	}

	// Feeding the OK result back sets an ok strip AND fires a reconcile refetch.
	m, cmd = step(t2, m, res)
	if m.ui.Strip.Message != "claimed as opus-9 · epoch 1" || m.ui.Strip.Role != RoleOK {
		t2.Fatalf("strip after claim = %+v, want the ok confirmation", m.ui.Strip)
	}
	if cmd == nil {
		t2.Fatal("a successful claim did not trigger a reconciling refetch")
	}
}

// A claim that the server refuses (e.g. a race that returns not_ready) shows the
// server's honest message verbatim in danger, and fires NO refetch.
func TestClaimResultFailureRendersHonestMessage(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{readyTask("r1")}})
	res := actionResultMsg{res: ActionResult{OK: false, Message: "claim failed: task is not ready"}}
	m, cmd := step(t2, m, res)
	if m.ui.Strip.Message != "claim failed: task is not ready" || m.ui.Strip.Role != RoleDanger {
		t2.Fatalf("strip = %+v, want the honest failure in danger", m.ui.Strip)
	}
	if cmd != nil {
		t2.Fatal("a failed claim must not trigger a refetch")
	}
}

// c on a NON-ready row never hits the network — it explains why on the strip.
func TestClaimKeyOnNonReadyRowExplainsInstead(t2 *testing.T) {
	fired := false
	m := testModel(Board{Orphans: []Task{{DocID: "o1", Title: "o1", Lifecycle: lifeOpen}}})
	m.ui.Cursor = 0
	m.doClaim = func(*apiclient.Client, string, string) ActionResult {
		fired = true
		return ActionResult{}
	}
	m, cmd := step(t2, m, runes("c"))
	if cmd != nil || fired {
		t2.Fatal("c on a non-ready row must not fire a claim")
	}
	if m.ui.Strip.Role != RoleWarn || m.ui.Strip.Message == "" {
		t2.Fatalf("strip = %+v, want a warn explanation", m.ui.Strip)
	}
}

// t on a row carrying a derived tag suggestion fires DoRelabel with that row's
// doc id + suggested key, then on the OK result flashes a green strip and fires
// the reconciling refetch (handleActionResult, shared with claim/close).
func TestTagKeyOnSuggestedRowFiresRelabelAndReconciles(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{suggestedTask("s1", "proj:sheets-parity")}})
	m.ui.Cursor = 0

	var gotDoc, gotTag string
	m.doRelabel = func(_ *apiclient.Client, docID, tag string) ActionResult {
		gotDoc, gotTag = docID, tag
		return ActionResult{OK: true, Message: "+proj:sheets-parity applied"}
	}

	m, cmd := step(t2, m, runes("t"))
	if cmd == nil {
		t2.Fatal("t on a suggested row did not fire a relabel command")
	}
	msg := cmd()
	res, ok := msg.(actionResultMsg)
	if !ok {
		t2.Fatalf("relabel command produced %T, want actionResultMsg", msg)
	}
	if gotDoc != "s1" || gotTag != "proj:sheets-parity" {
		t2.Fatalf("DoRelabel got (%q,%q), want (s1,proj:sheets-parity)", gotDoc, gotTag)
	}

	// The OK result lands a green confirmation AND a reconciling refetch.
	m, cmd = step(t2, m, res)
	if m.ui.Strip.Message != "+proj:sheets-parity applied" || m.ui.Strip.Role != RoleOK {
		t2.Fatalf("strip after relabel = %+v, want the ok confirmation", m.ui.Strip)
	}
	if cmd == nil {
		t2.Fatal("a successful relabel did not trigger a reconciling refetch")
	}
}

// t on a row WITHOUT a suggestion never hits the network — the refusal doubles
// as the verb's teaching line (t applies the dim +key? chip). Same for an
// empty cursor.
func TestTagKeyWithoutSuggestionExplainsInstead(t2 *testing.T) {
	fired := false
	seam := func(*apiclient.Client, string, string) ActionResult {
		fired = true
		return ActionResult{}
	}

	// A labeled row with no suggestion.
	m := testModel(Board{Orphans: []Task{{DocID: "o1", Title: "o1", Labels: []string{"area:tui"}}}})
	m.ui.Cursor = 0
	m.doRelabel = seam
	m, cmd := step(t2, m, runes("t"))
	if cmd != nil || fired {
		t2.Fatal("t on a row with no suggestion must not fire a relabel")
	}
	if m.ui.Strip.Role != RoleWarn ||
		m.ui.Strip.Message != "no suggested tag here — t applies a row's dim +key? chip" {
		t2.Fatalf("strip = %+v, want the teaching warn line", m.ui.Strip)
	}

	// An empty cursor (no rows) warns too, and still fires nothing.
	m2 := testModel(Board{})
	m2.doRelabel = seam
	m2, cmd2 := step(t2, m2, runes("t"))
	if cmd2 != nil || fired {
		t2.Fatal("t with no task under the cursor must not fire a relabel")
	}
	if m2.ui.Strip.Role != RoleWarn || m2.ui.Strip.Message == "" {
		t2.Fatalf("empty-cursor strip = %+v, want a warn explanation", m2.ui.Strip)
	}
}

// A relabel result in flight disarms the close guard exactly like a claim/close
// result does — the arm-prompt is the guard's only visible face, so once any
// action result replaces it the guard must not stay silently armed.
func TestTagResultDisarmsCloseGuard(t2 *testing.T) {
	m := testModel(Board{Now: []Task{claimedTask("c1", 7)}})
	m.now = func() time.Time { return time.Unix(10, 0) }
	m.fetch = func(*apiclient.Client) (Snapshot, error) {
		return Snapshot{FetchedAt: time.Unix(10, 0)}, nil
	}
	m.ui.Cursor = 0

	m, _ = step(t2, m, runes("x")) // arm the close guard
	if m.pendingClose != "c1" {
		t2.Fatalf("pendingClose = %q after arming, want c1", m.pendingClose)
	}
	m, _ = step(t2, m, actionResultMsg{res: ActionResult{OK: true, Message: "+area:tui applied"}})
	if m.pendingClose != "" {
		t2.Fatal("a relabel result left the close guard armed")
	}
}

// x is a double-press guard: the first arms (prompt + pendingClose), the second
// consecutive x fires DoClose with the OBSERVED epoch.
func TestCloseKeyDoublePressFiresWithObservedEpoch(t2 *testing.T) {
	t2.Setenv("BARKPARK_WORKER_ID", "opus-9")
	m := testModel(Board{Now: []Task{claimedTask("c1", 7)}})
	m.ui.Cursor = 0

	var gotDoc, gotWorker string
	var gotEpoch int
	m.doClose = func(_ *apiclient.Client, docID, worker string, epoch int) ActionResult {
		gotDoc, gotWorker, gotEpoch = docID, worker, epoch
		return ActionResult{OK: true, Message: "closed · epoch 7"}
	}

	// First x arms — no command, an armed prompt, pendingClose recorded.
	m, cmd := step(t2, m, runes("x"))
	if cmd != nil {
		t2.Fatal("the first x fired a close (should only arm)")
	}
	if m.pendingClose != "c1" {
		t2.Fatalf("pendingClose = %q after first x, want c1", m.pendingClose)
	}
	if !strings.Contains(m.ui.Strip.Message, "press x again") {
		t2.Fatalf("first-x strip = %q, want the confirm prompt", m.ui.Strip.Message)
	}

	// Second consecutive x fires the close with the observed epoch.
	m, cmd = step(t2, m, runes("x"))
	if cmd == nil {
		t2.Fatal("the second x did not fire the close")
	}
	if _, ok := cmd().(actionResultMsg); !ok {
		t2.Fatal("close command did not produce an actionResultMsg")
	}
	if gotDoc != "c1" || gotWorker != "opus-9" || gotEpoch != 7 {
		t2.Fatalf("DoClose got (%q,%q,%d), want (c1,opus-9,7)", gotDoc, gotWorker, gotEpoch)
	}
	if m.pendingClose != "" {
		t2.Fatal("pendingClose not cleared after firing")
	}
}

// Any key other than a repeated x disarms the close guard (and clears the strip).
func TestCloseGuardDisarmsOnOtherKey(t2 *testing.T) {
	fired := false
	m := testModel(Board{Now: []Task{claimedTask("c1", 7)}})
	m.ui.Cursor = 0
	m.doClose = func(*apiclient.Client, string, string, int) ActionResult {
		fired = true
		return ActionResult{}
	}

	m, _ = step(t2, m, runes("x")) // arm
	if m.pendingClose != "c1" {
		t2.Fatalf("pendingClose = %q, want c1", m.pendingClose)
	}
	m, _ = step(t2, m, runes("j")) // any other key disarms + clears the strip
	if m.pendingClose != "" {
		t2.Fatal("j did not disarm the close guard")
	}
	if m.ui.Strip.Message != "" {
		t2.Fatalf("keypress did not clear the strip: %q", m.ui.Strip.Message)
	}

	// A subsequent lone x must RE-ARM (cursor returned to c1), never fire.
	m.ui.Cursor = 0
	_, cmd := step(t2, m, runes("x"))
	if cmd != nil || fired {
		t2.Fatal("x after a disarm fired a close instead of re-arming")
	}
}

// x on a row with no live claim explains instead of arming.
func TestCloseKeyOnUnclaimedRowExplains(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{readyTask("r1")}})
	m.ui.Cursor = 0
	m, cmd := step(t2, m, runes("x"))
	if cmd != nil {
		t2.Fatal("x on an unclaimed row fired a command")
	}
	if m.pendingClose != "" {
		t2.Fatal("x on an unclaimed row armed the guard")
	}
	if m.ui.Strip.Role != RoleWarn || m.ui.Strip.Message == "" {
		t2.Fatalf("strip = %+v, want a warn explanation", m.ui.Strip)
	}
}

// o surfaces the Studio deep link on the strip AND launches it via openURL.
func TestOpenKeySurfacesURLAndLaunches(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{{DocID: "t1", Title: "t1"}}})
	m.cfg.BaseURL = "https://guerrilla.test"
	m.ui.Cursor = 0

	old := openURL
	t2.Cleanup(func() { openURL = old })
	var opened string
	openURL = func(u string) error { opened = u; return nil }

	m, _ = step(t2, m, runes("o"))
	want := "https://guerrilla.test/studio/production/task/t1"
	if opened != want {
		t2.Fatalf("openURL launched %q, want %q", opened, want)
	}
	if !strings.Contains(m.ui.Strip.Message, want) || m.ui.Strip.Role != RoleOK {
		t2.Fatalf("strip = %+v, want the URL in ok", m.ui.Strip)
	}
}

// Even when the browser launch fails, the URL stays on the strip (SSH-friendly).
func TestOpenKeyShowsURLWhenLaunchFails(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{{DocID: "t1", Title: "t1"}}})
	m.cfg.BaseURL = "https://guerrilla.test"
	m.ui.Cursor = 0

	old := openURL
	t2.Cleanup(func() { openURL = old })
	openURL = func(string) error { return errFakeLaunch }

	m, _ = step(t2, m, runes("o"))
	want := "https://guerrilla.test/studio/production/task/t1"
	if !strings.Contains(m.ui.Strip.Message, want) {
		t2.Fatalf("strip = %q, want it to still show %q", m.ui.Strip.Message, want)
	}
}

var errFakeLaunch = fakeErr("no browser")

type fakeErr string

func (e fakeErr) Error() string { return string(e) }

// A successful action's OWN reconciling refetch must not wipe the confirmation
// off the strip — otherwise every success flashes for one network round-trip
// and is unreadable. A later, unrelated snapshot does clear it.
func TestActionReconcileKeepsConfirmationStrip(t2 *testing.T) {
	m := testModel(Board{Orphans: []Task{readyTask("r1")}})
	m.now = func() time.Time { return time.Unix(10, 0) }
	m.fetch = func(*apiclient.Client) (Snapshot, error) {
		return Snapshot{FetchedAt: time.Unix(10, 0)}, nil
	}

	m, cmd := step(t2, m, actionResultMsg{res: ActionResult{OK: true, Message: "claimed as w · epoch 1"}})
	if cmd == nil {
		t2.Fatal("successful action fired no reconcile")
	}
	m, _ = step(t2, m, cmd()) // the reconciling snapshot lands
	if m.ui.Strip.Message != "claimed as w · epoch 1" {
		t2.Fatalf("reconcile wiped the confirmation: %+v", m.ui.Strip)
	}

	// An unrelated snapshot (SSE/backstop-driven) clears the stale strip.
	m, _ = step(t2, m, snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(11, 0)}})
	if m.ui.Strip.Message != "" {
		t2.Fatalf("unrelated snapshot kept a stale strip: %+v", m.ui.Strip)
	}
}

// A landed snapshot disarms the close guard along with clearing the strip: the
// arm-prompt is the guard's only visible face, so an x pressed after the prompt
// was wiped must RE-ARM (with a fresh prompt), never fire invisibly.
func TestSnapshotDisarmsCloseGuard(t2 *testing.T) {
	fired := false
	m := testModel(Board{Now: []Task{claimedTask("c1", 7)}})
	m.now = func() time.Time { return time.Unix(10, 0) }
	m.build = func(Snapshot, RepoContext, time.Time) Board {
		return Board{Now: []Task{claimedTask("c1", 7)}}
	}
	m.doClose = func(*apiclient.Client, string, string, int) ActionResult {
		fired = true
		return ActionResult{}
	}
	m.ui.Cursor = 0

	m, _ = step(t2, m, runes("x")) // arm
	m, _ = step(t2, m, snapshotMsg{snap: Snapshot{FetchedAt: time.Unix(10, 0)}})
	if m.pendingClose != "" {
		t2.Fatal("snapshot cleared the prompt but left the guard armed")
	}
	m, cmd := step(t2, m, runes("x"))
	if cmd != nil || fired {
		t2.Fatal("x after a snapshot-disarm fired the close instead of re-arming")
	}
	if !strings.Contains(m.ui.Strip.Message, "press x again") {
		t2.Fatalf("re-arm did not prompt: %q", m.ui.Strip.Message)
	}
}

// Init fires the initial fetch as a command (async first paint, amendment E):
// the batch it returns includes the refetch that produces a snapshotMsg.
func TestInitFiresInitialFetch(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.backstopEvery = time.Millisecond // so the batched backstop tick returns fast
	m.fetch = func(*apiclient.Client) (Snapshot, error) {
		return Snapshot{FetchedAt: time.Unix(1, 0)}, nil
	}
	cmd := m.Init()
	if cmd == nil {
		t2.Fatal("Init returned no command")
	}
	batch, ok := cmd().(tea.BatchMsg)
	if !ok {
		t2.Fatalf("Init did not return a batch: %T", cmd())
	}
	sawSnapshot := false
	for _, c := range batch {
		if c == nil {
			continue
		}
		if _, ok := c().(snapshotMsg); ok {
			sawSnapshot = true
		}
	}
	if !sawSnapshot {
		t2.Fatal("Init's batch does not include the initial fetch")
	}
}

// applySnapshot recomputes repo correlation from the gathered git subjects
// BEFORE building, so "↳ git" badges track the fresh task set.
func TestApplySnapshotRecomputesRepoBeforeBuild(t2 *testing.T) {
	m := newModel(nil, "", Config{})
	m.now = func() time.Time { return time.Unix(1, 0) }
	m.subjects = []string{"fix (dwb-18) the thing"}
	m.repoName = "barkpark"

	var gotRepo RepoContext
	m.build = func(_ Snapshot, repo RepoContext, _ time.Time) Board {
		gotRepo = repo
		return Board{}
	}
	snap := Snapshot{Tasks: []Task{{DocID: "dwb-18", Title: "x"}}, FetchedAt: time.Unix(1, 0)}
	step(t2, m, snapshotMsg{snap: snap})

	if gotRepo.RepoName != "barkpark" {
		t2.Fatalf("build saw repo %q, want barkpark", gotRepo.RepoName)
	}
	if gotRepo.Mentioned["dwb-18"] == 0 {
		t2.Fatalf("applySnapshot did not correlate dwb-18 before build: %+v", gotRepo.Mentioned)
	}
}

// serverHost reduces the resolved base URL to the host[:port] the header shows.
func TestServerHost(t2 *testing.T) {
	cases := []struct{ in, want string }{
		{"https://guerrilla.barkpark.cloud", "guerrilla.barkpark.cloud"},
		{"http://localhost:4000", "localhost:4000"},
		{"http://localhost:4000/", "localhost:4000"},
		{"guerrilla.test", "guerrilla.test"}, // scheme-less
		{"", "—"},
	}
	for _, tc := range cases {
		if got := serverHost(tc.in); got != tc.want {
			t2.Errorf("serverHost(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// --- quit --------------------------------------------------------------------

func TestQuitKeys(t2 *testing.T) {
	m := testModel(sampleBoard())
	for _, msg := range []tea.Msg{runes("q"), tea.KeyMsg{Type: tea.KeyCtrlC}} {
		_, cmd := step(t2, m, msg)
		if cmd == nil {
			t2.Fatalf("%v did not return a quit command", msg)
		}
		if got := cmd(); got == nil {
			t2.Fatalf("quit cmd for %v produced a nil msg", msg)
		} else if _, ok := got.(tea.QuitMsg); !ok {
			t2.Fatalf("quit cmd for %v produced %T, want tea.QuitMsg", msg, got)
		}
	}
}
