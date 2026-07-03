package taskboard

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// refNow is the reference clock the fixture's timestamps are laid out against:
// t5 is exactly 24h old (fold boundary), g4 is exactly 7d idle (dormancy
// boundary), t9/t1 are the two live claims.
var refNow = time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)

func mustParse(t *testing.T, s string) time.Time {
	t.Helper()
	ts, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("parse time %q: %v", s, err)
	}
	return ts
}

// loadFixtureSnapshot decodes testdata/tasks_fixture.json into a Snapshot
// through the SAME decode + compose pipeline the live fetch path uses — so the
// board tests also exercise the derived-ready overlay (the fixture stores
// t2/t12/t13 as "open"; prime.ready is what makes them ready).
func loadFixtureSnapshot(t *testing.T) Snapshot {
	t.Helper()
	raw, err := os.ReadFile("testdata/tasks_fixture.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f struct {
		Docs  []taskWire      `json:"docs"`
		Prime json.RawMessage `json:"prime"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	tasks := make([]Task, 0, len(f.Docs))
	for _, w := range f.Docs {
		tasks = append(tasks, w.toTask())
	}
	extras, err := decodePrime(f.Prime)
	if err != nil {
		t.Fatalf("decode fixture prime: %v", err)
	}
	return composeSnapshot(tasks, extras, refNow)
}

func docIDs(ts []Task) []string {
	ids := make([]string, len(ts))
	for i, t := range ts {
		ids[i] = t.DocID
	}
	return ids
}

func epicRootIDs(es []Epic) []string {
	ids := make([]string, len(es))
	for i, e := range es {
		ids[i] = e.Root.DocID
	}
	return ids
}

func findEpic(t *testing.T, es []Epic, rootID string) Epic {
	t.Helper()
	for _, e := range es {
		if e.Root.DocID == rootID {
			return e
		}
	}
	t.Fatalf("epic rooted at %q not found (have %v)", rootID, epicRootIDs(es))
	return Epic{}
}

func eq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestBuildBoard_Now — only LIVE claims that are still in_progress land in NOW,
// newest first. t9 (11:30) leads t1 (11:00); t8 (in_progress but worker "") and
// t7 (claim present but swept: worker null, lifecycle reverted to open) are
// both excluded — the expired-vs-live claim race.
func TestBuildBoard_Now(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	if got, want := docIDs(b.Now), []string{"t9", "t1"}; !eq(got, want) {
		t.Fatalf("NOW = %v, want %v", got, want)
	}
}

// TestBuildBoard_EpicOrder_NoRepo — with no git context, epics rank purely by
// freshest member updated desc.
func TestBuildBoard_EpicOrder_NoRepo(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	got := epicRootIDs(b.Epics)
	want := []string{"g2", "g1", "g5", "t13", "g4", "g3"}
	if !eq(got, want) {
		t.Fatalf("epic order = %v, want %v", got, want)
	}
}

// TestBuildBoard_RepoBoost — a git mention of t3 (a G1 child) floats G1 above
// the objectively-fresher G2, proving the boost changes epic order.
func TestBuildBoard_RepoBoost(t *testing.T) {
	repo := RepoContext{RepoName: "barkpark", Branch: "feat/x", Mentioned: map[string]int{"t3": 1}}
	b := BuildBoard(loadFixtureSnapshot(t), repo, refNow)
	got := epicRootIDs(b.Epics)
	want := []string{"g1", "g2", "g5", "t13", "g4", "g3"}
	if !eq(got, want) {
		t.Fatalf("boosted epic order = %v, want %v", got, want)
	}
}

// TestBuildBoard_ChildrenOrderAndFold — within G1, children order
// in_progress -> ready -> blocked -> open -> recent-terminal (updated desc
// inside each band); the 25h done row and the 48h cancelled row fold into
// DoneFolded, while the exactly-24h done row stays visible at the bottom.
func TestBuildBoard_ChildrenOrderAndFold(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	g1 := findEpic(t, b.Epics, "g1")

	wantChildren := []string{"t1", "t8", "t2", "t3", "t4", "t7", "t5"}
	if got := docIDs(g1.Children); !eq(got, wantChildren) {
		t.Fatalf("G1 children = %v, want %v", got, wantChildren)
	}
	if g1.DoneFolded != 2 {
		t.Fatalf("G1 DoneFolded = %d, want 2 (t6 25h + t16 48h)", g1.DoneFolded)
	}
	if g1.Dormant {
		t.Fatalf("G1 dormant, want active (t1 updated 1h ago)")
	}
}

// TestBuildBoard_Dormancy — the >7d rule is exclusive at the boundary: G3 (8d)
// is dormant, G4 (exactly 7d) is not.
func TestBuildBoard_Dormancy(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	if g3 := findEpic(t, b.Epics, "g3"); !g3.Dormant {
		t.Fatalf("G3 (8d idle) should be dormant")
	}
	if g4 := findEpic(t, b.Epics, "g4"); g4.Dormant {
		t.Fatalf("G4 (exactly 7d idle) should NOT be dormant — boundary is exclusive")
	}
}

// TestBuildBoard_ChildlessGoalIsEpic — a goal with no children is still an epic
// (empty children, nothing folded), not an orphan.
func TestBuildBoard_ChildlessGoalIsEpic(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	g5 := findEpic(t, b.Epics, "g5")
	if len(g5.Children) != 0 || g5.DoneFolded != 0 || g5.Dormant {
		t.Fatalf("G5 = %+v, want empty active epic", g5)
	}
}

// TestBuildBoard_MissingParentSubtree — a non-goal task whose parent is absent
// from the snapshot but which itself heads a subtree becomes an epic root; its
// child is attached.
func TestBuildBoard_MissingParentSubtree(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	e := findEpic(t, b.Epics, "t13")
	if got := docIDs(e.Children); !eq(got, []string{"t14"}) {
		t.Fatalf("t13 epic children = %v, want [t14]", got)
	}
}

// TestBuildBoard_Orphans — parentless (or dangling-parent) non-goal leaves with
// no children gather in Orphans, newest first, and never leak into Epics.
func TestBuildBoard_Orphans(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	if got, want := docIDs(b.Orphans), []string{"t12", "t15"}; !eq(got, want) {
		t.Fatalf("orphans = %v, want %v", got, want)
	}
	for _, e := range b.Epics {
		if e.Root.DocID == "t12" || e.Root.DocID == "t15" {
			t.Fatalf("orphan %s leaked into epics", e.Root.DocID)
		}
	}
}

// TestBuildBoard_CriteriaOmission — criteria_progress present decodes to a
// Criteria; omitted stays nil (never a misleading 0/0).
func TestBuildBoard_CriteriaOmission(t *testing.T) {
	s := loadFixtureSnapshot(t)
	byID := map[string]Task{}
	for _, t := range s.Tasks {
		byID[t.DocID] = t
	}
	if c := byID["t1"].Criteria; c == nil || c.Met != 2 || c.Total != 3 {
		t.Fatalf("t1 criteria = %+v, want {2 3}", c)
	}
	if c := byID["t2"].Criteria; c != nil {
		t.Fatalf("t2 criteria = %+v, want nil (omitted)", c)
	}
}

// TestBuildBoard_CountsEventsPassthrough — prime counts and the activity ticker
// events ride through onto the Board untouched.
func TestBuildBoard_CountsEventsPassthrough(t *testing.T) {
	s := loadFixtureSnapshot(t)
	b := BuildBoard(s, RepoContext{}, refNow)
	if b.Counts["in_progress"] != 5 || b.Counts["open"] != 12 {
		t.Fatalf("counts = %v, want prime counts passed through", b.Counts)
	}
	if _, hasReady := b.Counts["ready"]; hasReady {
		t.Fatalf("counts = %v: the server never emits a 'ready' count (readiness is derived) — a fixture drifted", b.Counts)
	}
	if len(b.Events) != 2 || b.Events[1].DocID != "t9" {
		t.Fatalf("events = %+v, want the fixture's two events", b.Events)
	}
}

// TestBuildBoard_Empty — an empty queue yields an empty, non-panicking board.
func TestBuildBoard_Empty(t *testing.T) {
	b := BuildBoard(Snapshot{}, RepoContext{}, refNow)
	if len(b.Now) != 0 || len(b.Epics) != 0 || len(b.Orphans) != 0 {
		t.Fatalf("empty snapshot produced non-empty board: %+v", b)
	}
}

// TestFoldBoundary — table-driven exactness of the 24h done-fold: an age of
// exactly 24h stays visible, one second past it folds.
func TestFoldBoundary(t *testing.T) {
	goal := Task{DocID: "g", Kind: kindGoal, UpdatedAt: refNow}
	cases := []struct {
		name       string
		childAge   time.Duration
		wantFolded int
		wantKept   int
	}{
		{"exactly 24h stays", 24 * time.Hour, 0, 1},
		{"one second past folds", 24*time.Hour + time.Second, 1, 0},
		{"one second under stays", 24*time.Hour - time.Second, 0, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			child := Task{DocID: "c", ParentID: "g", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-tc.childAge)}
			b := BuildBoard(Snapshot{Tasks: []Task{goal, child}}, RepoContext{}, refNow)
			e := findEpic(t, b.Epics, "g")
			if e.DoneFolded != tc.wantFolded || len(e.Children) != tc.wantKept {
				t.Fatalf("age %v -> folded=%d kept=%d, want folded=%d kept=%d",
					tc.childAge, e.DoneFolded, len(e.Children), tc.wantFolded, tc.wantKept)
			}
		})
	}
}

// loadFlatSnapshot decodes the flat-queue fixture (live guerrilla shape: ~100
// loose tasks, 0 goals, ~half stale-done) through the real decode+compose path.
func loadFlatSnapshot(t *testing.T) Snapshot {
	t.Helper()
	raw, err := os.ReadFile("testdata/flat_queue_fixture.json")
	if err != nil {
		t.Fatalf("read flat fixture: %v", err)
	}
	var f struct {
		Docs  []taskWire      `json:"docs"`
		Prime json.RawMessage `json:"prime"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode flat fixture: %v", err)
	}
	tasks := make([]Task, 0, len(f.Docs))
	for _, w := range f.Docs {
		tasks = append(tasks, w.toTask())
	}
	extras, err := decodePrime(f.Prime)
	if err != nil {
		t.Fatalf("decode flat prime: %v", err)
	}
	return composeSnapshot(tasks, extras, refNow)
}

// TestBuildBoard_FlatQueue — the wave-2 orphan policy against the live flat
// shape: no goals means ZERO epics, so the whole board is the loose queue. The
// 55 stale-done orphans fold to a single count, the 45 survivors are
// band-ordered (in_progress -> ready -> blocked -> open -> recent-terminal), and
// the three live claims still pin the NOW band. TaskCount == the fetched corpus.
func TestBuildBoard_FlatQueue(t *testing.T) {
	b := BuildBoard(loadFlatSnapshot(t), RepoContext{}, refNow)

	if len(b.Epics) != 0 {
		t.Fatalf("flat queue produced %d epics, want 0 (no goals)", len(b.Epics))
	}
	if b.OrphansFolded != 55 {
		t.Fatalf("OrphansFolded = %d, want 55 (the stale-done pile)", b.OrphansFolded)
	}
	if len(b.Orphans) != 45 {
		t.Fatalf("visible orphans = %d, want 45 (3 in_progress + 8 ready + 4 blocked + 27 open + 3 recent done)", len(b.Orphans))
	}
	if b.TaskCount != 100 {
		t.Fatalf("TaskCount = %d, want 100 (fetched corpus)", b.TaskCount)
	}
	if b.ReadyHeadClamped {
		t.Fatalf("ReadyHeadClamped = true, want false (8 ready < clamp)")
	}
	if got := docIDs(b.Now); !eq(got, []string{"ip001", "ip002", "ip003"}) {
		t.Fatalf("NOW = %v, want the three live claims newest-first", got)
	}

	// Band order: the lifecycle band is non-decreasing down the survivors, and
	// no folded row (stale done, dn*) leaked in.
	prevBand := -1
	for i, o := range b.Orphans {
		band := childBand(o.Lifecycle)
		if band < prevBand {
			t.Fatalf("orphan %d (%s, %s) breaks band order: band %d after %d",
				i, o.DocID, o.Lifecycle, band, prevBand)
		}
		prevBand = band
		if strings.HasPrefix(o.DocID, "dn") {
			t.Fatalf("stale-done orphan %s survived the fold", o.DocID)
		}
	}
	// The very first survivors are the in_progress claims, the tail is recent done.
	if b.Orphans[0].Lifecycle != lifeInProgress {
		t.Fatalf("first survivor = %s, want an in_progress row on top", b.Orphans[0].Lifecycle)
	}
	if last := b.Orphans[len(b.Orphans)-1]; last.Lifecycle != lifeDone {
		t.Fatalf("last survivor = %s, want a recent-done row at the tail", last.Lifecycle)
	}
}

// TestOrphanFoldBoundary — the loose-orphan fold uses the SAME exclusive 24h
// boundary as epic children: a done orphan at exactly 24h stays visible, one a
// second older folds, and a non-terminal orphan never folds however old.
func TestOrphanFoldBoundary(t *testing.T) {
	cases := []struct {
		name       string
		life       string
		age        time.Duration
		wantFolded int
		wantKept   int
	}{
		{"done exactly 24h stays", lifeDone, 24 * time.Hour, 0, 1},
		{"done one second past folds", lifeDone, 24*time.Hour + time.Second, 1, 0},
		{"cancelled two days folds", lifeCancelled, 48 * time.Hour, 1, 0},
		{"open never folds", lifeOpen, 100 * 24 * time.Hour, 0, 1},
		{"blocked never folds", lifeBlocked, 100 * 24 * time.Hour, 0, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			o := Task{DocID: "o", Lifecycle: tc.life, UpdatedAt: refNow.Add(-tc.age)}
			b := BuildBoard(Snapshot{Tasks: []Task{o}}, RepoContext{}, refNow)
			if b.OrphansFolded != tc.wantFolded || len(b.Orphans) != tc.wantKept {
				t.Fatalf("life=%s age=%v -> folded=%d kept=%d, want folded=%d kept=%d",
					tc.life, tc.age, b.OrphansFolded, len(b.Orphans), tc.wantFolded, tc.wantKept)
			}
		})
	}
}

// TestOrphanBandOrder — scrambled loose tasks land band-ordered
// (in_progress -> ready -> blocked -> open -> recent-terminal, updated desc
// within a band), replacing the old raw updated-desc mix.
func TestOrphanBandOrder(t *testing.T) {
	mk := func(id, life string, hoursAgo int) Task {
		return Task{DocID: id, Lifecycle: life, UpdatedAt: refNow.Add(-time.Duration(hoursAgo) * time.Hour)}
	}
	// Deliberately out of order on the wire; two open rows test in-band desc.
	tasks := []Task{
		mk("recentdone", lifeDone, 2), // terminal but <24h -> stays, sinks to bottom
		mk("openold", lifeOpen, 5),
		mk("blk", lifeBlocked, 1),
		mk("ready1", lifeReady, 9),
		mk("opennew", lifeOpen, 3),
		mk("ip", lifeInProgress, 4),
	}
	b := BuildBoard(Snapshot{Tasks: tasks}, RepoContext{}, refNow)
	want := []string{"ip", "ready1", "blk", "opennew", "openold", "recentdone"}
	if got := docIDs(b.Orphans); !eq(got, want) {
		t.Fatalf("orphan band order = %v, want %v", got, want)
	}
	if b.OrphansFolded != 0 {
		t.Fatalf("OrphansFolded = %d, want 0 (nothing stale)", b.OrphansFolded)
	}
}

// TestBuildBoard_ThreadsSnapshotFlags — ReadyHeadClamped and TaskCount ride from
// the Snapshot onto the Board so the header can be honest about clamp/truncation.
func TestBuildBoard_ThreadsSnapshotFlags(t *testing.T) {
	s := Snapshot{
		Tasks:            []Task{{DocID: "a", Lifecycle: lifeOpen}, {DocID: "b", Lifecycle: lifeOpen}},
		ReadyHeadClamped: true,
	}
	b := BuildBoard(s, RepoContext{}, refNow)
	if !b.ReadyHeadClamped {
		t.Fatalf("ReadyHeadClamped did not thread onto the board")
	}
	if b.TaskCount != 2 {
		t.Fatalf("TaskCount = %d, want 2 (len snapshot tasks)", b.TaskCount)
	}
}

// TestDormancyBoundary — table-driven exactness of the 7d dormancy rule.
func TestDormancyBoundary(t *testing.T) {
	cases := []struct {
		name        string
		freshestAge time.Duration
		wantDormant bool
	}{
		{"exactly 7d active", 7 * 24 * time.Hour, false},
		{"one second past dormant", 7*24*time.Hour + time.Second, true},
		{"fresh active", time.Hour, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			at := refNow.Add(-tc.freshestAge)
			goal := Task{DocID: "g", Kind: kindGoal, UpdatedAt: at}
			child := Task{DocID: "c", ParentID: "g", Lifecycle: lifeOpen, UpdatedAt: at}
			b := BuildBoard(Snapshot{Tasks: []Task{goal, child}}, RepoContext{}, refNow)
			if e := findEpic(t, b.Epics, "g"); e.Dormant != tc.wantDormant {
				t.Fatalf("freshest age %v -> dormant=%v, want %v", tc.freshestAge, e.Dormant, tc.wantDormant)
			}
		})
	}
}
