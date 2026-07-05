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

// TestBuildBoard_NowDedup — the D14 de-dup: a claimed task renders ONLY in the
// NOW band, never again as a row in its epic OR as a loose orphan. The epic
// header survives (structure), but its claimed child leaves the spine; a claimed
// loose leaf leaves the orphan pile entirely.
func TestBuildBoard_NowDedup(t *testing.T) {
	claim := &Claim{Worker: "w", Epoch: 1, ClaimedAt: refNow.Add(-time.Minute)}
	s := Snapshot{Tasks: []Task{
		{DocID: "epic", Title: "Epic", Kind: kindGoal, Lifecycle: lifeOpen, UpdatedAt: refNow},
		{DocID: "child-claimed", Title: "claimed child", ParentID: "epic",
			Lifecycle: lifeInProgress, Claim: claim, UpdatedAt: refNow},
		{DocID: "child-ready", Title: "ready child", ParentID: "epic",
			Lifecycle: lifeReady, UpdatedAt: refNow},
		{DocID: "loose-claimed", Title: "claimed orphan",
			Lifecycle: lifeInProgress, Claim: claim, UpdatedAt: refNow},
		{DocID: "loose-ready", Title: "ready orphan", Lifecycle: lifeReady, UpdatedAt: refNow},
	}}
	b := BuildBoard(s, RepoContext{}, refNow)

	if got := docIDs(b.Now); !eq(got, []string{"child-claimed", "loose-claimed"}) {
		t.Fatalf("NOW = %v, want both claimed tasks", got)
	}
	epic := findEpic(t, b.Epics, "epic")
	if got := docIDs(epic.Children); !eq(got, []string{"child-ready"}) {
		t.Fatalf("epic children = %v, want only the ready child (the claimed one is NOW-only)", got)
	}
	if got := docIDs(b.Orphans); !eq(got, []string{"loose-ready"}) {
		t.Fatalf("orphans = %v, want only the ready orphan (the claimed one is NOW-only)", got)
	}
}

// TestBuildBoard_NowDedup_ClusterStable — the de-dup is display-only for the
// derived clusters too: claiming one member of a minimum-size cluster
// (clusterMemberMin == 2) must NOT dissolve the section and reshuffle its
// sibling down into "(no epic)". The claim participates in label frequency,
// membership and freshest-member ranking, and is stripped from the DISPLAYED
// members only afterwards. Its fresh claim also still ranks the cluster: the
// just-claimed sheets cluster must sort ABOVE the older docs cluster even
// though its one visible row is the stalest task on the board.
func TestBuildBoard_NowDedup_ClusterStable(t *testing.T) {
	claim := &Claim{Worker: "w", Epoch: 1, ClaimedAt: refNow.Add(-time.Minute)}
	old := refNow.Add(-3 * 24 * time.Hour)
	s := Snapshot{Tasks: []Task{
		{DocID: "sp1", Title: "Sheets one", Labels: []string{"proj:sheets"},
			Lifecycle: lifeInProgress, Claim: claim, UpdatedAt: refNow},
		{DocID: "sp2", Title: "Sheets two", Labels: []string{"proj:sheets"},
			Lifecycle: lifeOpen, UpdatedAt: old.Add(-time.Hour)},
		{DocID: "dc1", Title: "Docs one", Labels: []string{"proj:docs"},
			Lifecycle: lifeOpen, UpdatedAt: old},
		{DocID: "dc2", Title: "Docs two", Labels: []string{"proj:docs"},
			Lifecycle: lifeOpen, UpdatedAt: old},
	}}
	b := BuildBoard(s, RepoContext{}, refNow)

	if got := docIDs(b.Now); !eq(got, []string{"sp1"}) {
		t.Fatalf("NOW = %v, want the claimed sp1", got)
	}
	if len(b.Clusters) != 2 {
		t.Fatalf("clusters = %d, want 2 — claiming sp1 must not dissolve proj:sheets", len(b.Clusters))
	}
	if b.Clusters[0].Key != "proj:sheets" {
		t.Fatalf("first cluster = %q, want proj:sheets on top (its claim's freshness still ranks it)", b.Clusters[0].Key)
	}
	if got := docIDs(b.Clusters[0].Tasks); !eq(got, []string{"sp2"}) {
		t.Fatalf("sheets members = %v, want only sp2 visible (sp1 is NOW-only)", got)
	}
	if len(b.Orphans) != 0 {
		t.Fatalf("orphans = %v, want none — sp2 must stay clustered", docIDs(b.Orphans))
	}
}

// TestBuildBoard_EpicOrder_NoRepo — with no git context, epics rank
// (Active desc, LastActivity desc) — charter D49 / wave-11. g1 and g2 both own a
// live claim (Active), so they head the list ordered by recency (g2's t9 moved at
// 11:30, g1's t1 at 11:00); the quiet epics follow by recency (g5, t13, g4, g3).
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
// inside each band). G1 has exactly two done children (t5, t6), so both survive
// as the ≤doneCueMax completion cue at the bottom (charter D50 — age no longer
// folds a done row; nothing folds until there are more than doneCueMax done). The
// 48h cancelled row still folds into CancelledFolded (charter wave-10 W10-B). t1
// is a LIVE claim, so the NOW de-dup (charter D14) removes it from the spine
// children — it renders only in the pinned NOW band — while t8 (in_progress but
// unclaimed, worker empty) stays and heads the band.
func TestBuildBoard_ChildrenOrderAndFold(t *testing.T) {
	b := BuildBoard(loadFixtureSnapshot(t), RepoContext{}, refNow)
	g1 := findEpic(t, b.Epics, "g1")

	wantChildren := []string{"t8", "t2", "t3", "t4", "t7", "t5", "t6"}
	if got := docIDs(g1.Children); !eq(got, wantChildren) {
		t.Fatalf("G1 children = %v, want %v", got, wantChildren)
	}
	if g1.DoneFolded != 0 {
		t.Fatalf("G1 DoneFolded = %d, want 0 (t5+t6 both fit the 2-row done cue)", g1.DoneFolded)
	}
	if g1.CancelledFolded != 1 {
		t.Fatalf("G1 CancelledFolded = %d, want 1 (t16 48h cancelled)", g1.CancelledFolded)
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

// TestDoneCueFold — the terminal fold is AGE-INDEPENDENT (charter D50 / wave-11):
// a section keeps at most doneCueMax freshest done rows as a completion cue and
// folds the rest, whether the done rows are minutes or months old. A single done
// never folds; the 3rd folds even when it is fresh (the mass-close pathology).
func TestDoneCueFold(t *testing.T) {
	goal := Task{DocID: "g", Kind: kindGoal, UpdatedAt: refNow}
	mkDone := func(id string, age time.Duration) Task {
		return Task{DocID: id, ParentID: "g", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-age)}
	}
	t.Run("single fresh done stays (1 <= cue)", func(t *testing.T) {
		b := BuildBoard(Snapshot{Tasks: []Task{goal, mkDone("d", time.Minute)}}, RepoContext{}, refNow)
		e := findEpic(t, b.Epics, "g")
		if e.DoneFolded != 0 || len(e.Children) != 1 {
			t.Fatalf("single done: folded=%d kept=%d, want folded=0 kept=1", e.DoneFolded, len(e.Children))
		}
	})
	t.Run("very old single done still stays (age no longer folds)", func(t *testing.T) {
		b := BuildBoard(Snapshot{Tasks: []Task{goal, mkDone("d", 100*24*time.Hour)}}, RepoContext{}, refNow)
		e := findEpic(t, b.Epics, "g")
		if e.DoneFolded != 0 || len(e.Children) != 1 {
			t.Fatalf("ancient single done: folded=%d kept=%d, want folded=0 kept=1", e.DoneFolded, len(e.Children))
		}
	})
	t.Run("three fresh done fold to the 2-row cue, age irrelevant", func(t *testing.T) {
		// All three <24h old — the OLD age gate kept all three; D50 folds one.
		b := BuildBoard(Snapshot{Tasks: []Task{goal,
			mkDone("d1", 1*time.Hour), mkDone("d2", 2*time.Hour), mkDone("d3", 3*time.Hour),
		}}, RepoContext{}, refNow)
		e := findEpic(t, b.Epics, "g")
		if e.DoneFolded != 1 || len(e.Children) != doneCueMax {
			t.Fatalf("three done: folded=%d kept=%d, want folded=1 kept=%d", e.DoneFolded, len(e.Children), doneCueMax)
		}
		if got := docIDs(e.Children); !eq(got, []string{"d1", "d2"}) {
			t.Fatalf("cue = %v, want [d1 d2] (freshest two)", got)
		}
	})
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

// TestBuildBoard_FlatQueue — the orphan policy against the live flat shape: no
// goals means ZERO epics, so the whole board is the loose queue. Under wave-11's
// age-independent fold (charter D50) ALL done orphans fold except the ≤doneCueMax
// (2) freshest, so 56 done fold (the 55 stale-done + the 3rd recent-done) and only
// 2 done survive as the cue. The three live claims pin the NOW band; the NOW
// de-dup (charter D14) keeps those three claimed loose leaves OUT of the orphan
// pile, so 41 survivors remain, band-ordered. TaskCount == the fetched corpus.
func TestBuildBoard_FlatQueue(t *testing.T) {
	b := BuildBoard(loadFlatSnapshot(t), RepoContext{}, refNow)

	if len(b.Epics) != 0 {
		t.Fatalf("flat queue produced %d epics, want 0 (no goals)", len(b.Epics))
	}
	if b.OrphansFolded != 56 {
		t.Fatalf("OrphansFolded = %d, want 56 (all done except the 2 freshest cue)", b.OrphansFolded)
	}
	if len(b.Orphans) != 41 {
		t.Fatalf("visible orphans = %d, want 41 (8 ready + 4 blocked + 27 open + 2 done cue; the 3 claimed in_progress are NOW-only)", len(b.Orphans))
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
		band := childBand(o, refNow)
		if band < prevBand {
			t.Fatalf("orphan %d (%s, %s) breaks band order: band %d after %d",
				i, o.DocID, o.Lifecycle, band, prevBand)
		}
		prevBand = band
		if strings.HasPrefix(o.DocID, "dn") {
			t.Fatalf("stale-done orphan %s survived the fold", o.DocID)
		}
	}
	// The 3 in_progress rows were all claimed, so the NOW de-dup lifts them into
	// the pinned band; the top survivor is now the freshest ready row, and the
	// tail is recent done.
	if b.Orphans[0].Lifecycle != lifeReady {
		t.Fatalf("first survivor = %s, want a ready row on top (the in_progress rows are NOW-only)", b.Orphans[0].Lifecycle)
	}
	if last := b.Orphans[len(b.Orphans)-1]; last.Lifecycle != lifeDone {
		t.Fatalf("last survivor = %s, want a recent-done row at the tail", last.Lifecycle)
	}
}

// TestOrphanDoneCue — the loose-orphan DONE fold is age-independent (charter
// D50): at most doneCueMax freshest done stay as a cue, the rest fold; a single
// done never folds however old. Cancelled orphans fold into their OWN bucket at
// ANY age (charter wave-10 W10-B — abandoned work never renders as a row and
// never joins the done tally). Non-terminal orphans never fold.
func TestOrphanDoneCue(t *testing.T) {
	single := []struct {
		name          string
		life          string
		age           time.Duration
		wantFolded    int
		wantCancelled int
		wantKept      int
	}{
		{"lone done stays, any age", lifeDone, 100 * 24 * time.Hour, 0, 0, 1},
		{"cancelled two days folds", lifeCancelled, 48 * time.Hour, 0, 1, 0},
		{"cancelled fresh (1h) still folds away", lifeCancelled, time.Hour, 0, 1, 0},
		{"open never folds", lifeOpen, 100 * 24 * time.Hour, 0, 0, 1},
		{"blocked never folds", lifeBlocked, 100 * 24 * time.Hour, 0, 0, 1},
	}
	for _, tc := range single {
		t.Run(tc.name, func(t *testing.T) {
			o := Task{DocID: "o", Lifecycle: tc.life, UpdatedAt: refNow.Add(-tc.age)}
			b := BuildBoard(Snapshot{Tasks: []Task{o}}, RepoContext{}, refNow)
			if b.OrphansFolded != tc.wantFolded || b.OrphansCancelledFolded != tc.wantCancelled || len(b.Orphans) != tc.wantKept {
				t.Fatalf("life=%s age=%v -> folded=%d cancelled=%d kept=%d, want folded=%d cancelled=%d kept=%d",
					tc.life, tc.age, b.OrphansFolded, b.OrphansCancelledFolded, len(b.Orphans),
					tc.wantFolded, tc.wantCancelled, tc.wantKept)
			}
		})
	}
	t.Run("three fresh done fold to the 2-row cue, age irrelevant", func(t *testing.T) {
		tasks := []Task{
			{DocID: "d1", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-1 * time.Hour)},
			{DocID: "d2", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-2 * time.Hour)},
			{DocID: "d3", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-3 * time.Hour)},
		}
		b := BuildBoard(Snapshot{Tasks: tasks}, RepoContext{}, refNow)
		if b.OrphansFolded != 1 || len(b.Orphans) != doneCueMax {
			t.Fatalf("three done orphans -> folded=%d kept=%d, want folded=1 kept=%d", b.OrphansFolded, len(b.Orphans), doneCueMax)
		}
		if got := docIDs(b.Orphans); !eq(got, []string{"d1", "d2"}) {
			t.Fatalf("orphan done cue = %v, want [d1 d2] (freshest two)", got)
		}
	})
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

// ---- Wave 3: derived clusters, twins, suggestions, staleness ----

// loadClusterSnapshot decodes the live-shaped labeled fixture through the real
// decode+compose path (so the ready overlay lifts sp2 to "ready", exactly as a
// live server would).
func loadClusterSnapshot(t *testing.T) Snapshot {
	t.Helper()
	raw, err := os.ReadFile("testdata/cluster_fixture.json")
	if err != nil {
		t.Fatalf("read cluster fixture: %v", err)
	}
	var f struct {
		Docs  []taskWire      `json:"docs"`
		Prime json.RawMessage `json:"prime"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode cluster fixture: %v", err)
	}
	tasks := make([]Task, 0, len(f.Docs))
	for _, w := range f.Docs {
		tasks = append(tasks, w.toTask())
	}
	extras, err := decodePrime(f.Prime)
	if err != nil {
		t.Fatalf("decode cluster prime: %v", err)
	}
	return composeSnapshot(tasks, extras, refNow)
}

func clusterKeys(cs []Cluster) []string {
	ks := make([]string, len(cs))
	for i, c := range cs {
		ks[i] = c.Key
	}
	return ks
}

func findCluster(t *testing.T, cs []Cluster, key string) Cluster {
	t.Helper()
	for _, c := range cs {
		if c.Key == key {
			return c
		}
	}
	t.Fatalf("cluster %q not found (have %v)", key, clusterKeys(cs))
	return Cluster{}
}

// TestBuildBoard_ClustersLiveShape — the whole wave-3 policy against the labeled
// loose queue: proj:/area: keys and the deploy-button >=3-share fallback each
// form a section (freshest-first), phase:-only and singleton-proj: tasks stay
// loose, the terminal orphan folds, the stale rows sink and are tallied, the
// unlabeled title-matcher earns a suggestion, and the manifest pair are twins.
func TestBuildBoard_ClustersLiveShape(t *testing.T) {
	b := BuildBoard(loadClusterSnapshot(t), RepoContext{}, refNow)

	// No goals -> no epics; the queue is entirely clusters + orphans.
	if len(b.Epics) != 0 {
		t.Fatalf("expected 0 epics (no goals), got %d", len(b.Epics))
	}

	// Clusters, freshest-member first.
	wantClusters := []string{"proj:sheets-parity", "deploy-button", "proj:living-values", "area:cloud"}
	if got := clusterKeys(b.Clusters); !eq(got, wantClusters) {
		t.Fatalf("clusters = %v, want %v", got, wantClusters)
	}

	// sheets-parity members are band-ordered: ready(overlaid), open, then the
	// 9d-stale open sinks to the stale band at the tail. sp1 is a LIVE claim, so
	// the NOW de-dup (charter D14) keeps it out of the cluster — it renders only in
	// the pinned NOW band.
	sheets := findCluster(t, b.Clusters, "proj:sheets-parity")
	if got := docIDs(sheets.Tasks); !eq(got, []string{"sp2", "sp3", "sp4"}) {
		t.Fatalf("sheets members = %v, want [sp2 sp3 sp4]", got)
	}
	if childBand(sheets.Tasks[2], refNow) != 5 {
		t.Fatalf("sp4 (9d open) should be in the stale band (5), got %d", childBand(sheets.Tasks[2], refNow))
	}

	// Remaining orphans: the two title-untethered opens (updated desc), then the
	// singleton-proj: onix task, the ancient stale row, and finally the lone done
	// orphan dn1 — kept as the ≤doneCueMax cue (charter D50 folds done by count,
	// not age, so a single done orphan stays visible at the band-6 tail).
	if got := docIDs(b.Orphans); !eq(got, []string{"sug1", "ph1", "on1", "st1", "dn1"}) {
		t.Fatalf("orphans = %v, want [sug1 ph1 on1 st1 dn1]", got)
	}
	if b.OrphansFolded != 0 {
		t.Fatalf("OrphansFolded = %d, want 0 (dn1 is the lone done → fits the cue)", b.OrphansFolded)
	}

	// Twins: the two "Bootstrap job manifest" rows point mutually; the third
	// deploy-button row and every sheets row stay untwinned.
	deploy := findCluster(t, b.Clusters, "deploy-button")
	dm := map[string]Task{}
	for _, tk := range deploy.Tasks {
		dm[tk.DocID] = tk
	}
	if dm["db1"].TwinOf != "db2" || dm["db2"].TwinOf != "db1" {
		t.Fatalf("db1/db2 twins = %q/%q, want mutual db2/db1", dm["db1"].TwinOf, dm["db2"].TwinOf)
	}
	if dm["db3"].TwinOf != "" {
		t.Fatalf("db3 should have no twin, got %q", dm["db3"].TwinOf)
	}
	for _, tk := range sheets.Tasks {
		if tk.TwinOf != "" {
			t.Fatalf("sheets row %s unexpectedly twinned to %s", tk.DocID, tk.TwinOf)
		}
	}

	// Staleness: sp4 (9d) + st1 (13d) are the two cold non-terminal rows.
	if b.Stale != 2 {
		t.Fatalf("Board.Stale = %d, want 2 (sp4 + st1)", b.Stale)
	}

	// NOW still holds the single live claim.
	if got := docIDs(b.Now); !eq(got, []string{"sp1"}) {
		t.Fatalf("NOW = %v, want [sp1]", got)
	}
}

// TestClusterKey — table-driven key resolution: proj: beats area: beats the
// >=3-share plain fallback; phase: never keys and is excluded from the fallback;
// a plain label under the share floor yields no key; fallback ties resolve by
// frequency desc then lexically. clusterKey takes the freq map directly.
func TestClusterKey(t *testing.T) {
	freq := map[string]int{"shared": 3, "rare": 2, "alpha": 3, "beta": 3, "high": 4, "low": 3}
	cases := []struct {
		name   string
		labels []string
		want   string
	}{
		{"proj beats plain", []string{"proj:x", "shared"}, "proj:x"},
		{"proj beats area", []string{"area:b", "proj:a"}, "proj:a"},
		{"area when no proj", []string{"area:y", "shared"}, "area:y"},
		{"plain fallback at floor", []string{"shared"}, "shared"},
		{"plain below floor -> none", []string{"rare"}, ""},
		{"phase never keys", []string{"phase:work"}, ""},
		{"phase excluded, plain picked", []string{"phase:work", "shared"}, "shared"},
		{"fallback tie lexical", []string{"beta", "alpha"}, "alpha"},
		{"fallback frequency desc", []string{"low", "high"}, "high"},
		{"no labels -> none", nil, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := clusterKey(Task{Labels: tc.labels}, freq)
			if got != tc.want {
				t.Fatalf("clusterKey(%v) = %q, want %q", tc.labels, got, tc.want)
			}
		})
	}
}

// TestDeriveClusters_MemberThreshold — a key needs >=2 members to form a
// cluster; the plain-label fallback additionally needs >=3 carriers to even be a
// key. proj:x on two rows clusters; proj:one alone stays loose; a plain label on
// three (deploy-button shape) clusters; the same plain on two never keys.
func TestDeriveClusters_MemberThreshold(t *testing.T) {
	mk := func(id string, labels ...string) Task {
		return Task{DocID: id, Lifecycle: lifeOpen, Labels: labels, UpdatedAt: refNow}
	}
	t.Run("proj two members clusters, singleton stays loose", func(t *testing.T) {
		loose := []Task{mk("a", "proj:x"), mk("b", "proj:x"), mk("c", "proj:one")}
		cs, rem := deriveClusters(loose, refNow, nil, nil)
		if got := clusterKeys(cs); !eq(got, []string{"proj:x"}) {
			t.Fatalf("clusters = %v, want [proj:x]", got)
		}
		if got := docIDs(rem); !eq(got, []string{"c"}) {
			t.Fatalf("remaining = %v, want [c] (singleton proj:one)", got)
		}
	})
	t.Run("plain fallback needs three carriers", func(t *testing.T) {
		loose := []Task{mk("a", "deploy-button"), mk("b", "deploy-button"), mk("c", "deploy-button")}
		cs, rem := deriveClusters(loose, refNow, nil, nil)
		if got := clusterKeys(cs); !eq(got, []string{"deploy-button"}) {
			t.Fatalf("clusters = %v, want [deploy-button]", got)
		}
		if len(rem) != 0 {
			t.Fatalf("remaining = %v, want none", docIDs(rem))
		}
	})
	t.Run("plain on two never keys", func(t *testing.T) {
		loose := []Task{mk("a", "twoonly"), mk("b", "twoonly")}
		cs, rem := deriveClusters(loose, refNow, nil, nil)
		if len(cs) != 0 {
			t.Fatalf("clusters = %v, want none (label carried by only 2)", clusterKeys(cs))
		}
		if got := docIDs(rem); !eq(got, []string{"a", "b"}) {
			t.Fatalf("remaining = %v, want [a b]", got)
		}
	})
}

// TestClusterSuggestion_Threshold — the 0.4 title-Jaccard floor is inclusive at
// the boundary and excludes weaker matches.
func TestClusterSuggestion_Threshold(t *testing.T) {
	// Cluster member title "alpha beta gamma" (3 tokens).
	clusters := []Cluster{{Key: "proj:k", Tasks: []Task{{DocID: "m", Title: "alpha beta gamma"}}}}
	cases := []struct {
		name    string
		title   string
		wantKey string
	}{
		// "alpha beta" ∩ member = {alpha,beta}=2, ∪={alpha,beta,gamma}=3 -> 0.667.
		{"strong match suggests", "alpha beta", "proj:k"},
		// "alpha delta epsilon" ∩ = {alpha}=1, ∪ = 5 -> 0.2 -> below floor.
		{"weak match no suggest", "alpha delta epsilon", ""},
		// exactly-0.4 boundary: title {a,b,c,gamma}? craft |∩|/|∪| = 0.4.
		// member has {alpha,beta,gamma}; title {gamma,d,e} -> ∩1 ∪5 = 0.2 (no).
		// title {alpha,beta,x,y} -> ∩2 ∪5 = 0.4 (inclusive -> suggest).
		{"exactly 0.4 suggests", "alpha beta x y", "proj:k"},
		{"empty title no suggest", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			key, ok := bestClusterSuggestion(Task{Title: tc.title}, clusters)
			if tc.wantKey == "" {
				if ok {
					t.Fatalf("title %q suggested %q, want none", tc.title, key)
				}
				return
			}
			if !ok || key != tc.wantKey {
				t.Fatalf("title %q -> (%q,%v), want (%q,true)", tc.title, key, ok, tc.wantKey)
			}
		})
	}
}

// TestDetectTwins_MutualityAndDeterminism — twins are mutual on a reciprocal
// best-match pair, terminal rows never twin, and a tie on Jaccard resolves to
// the smaller doc_id deterministically.
func TestDetectTwins_MutualityAndDeterminism(t *testing.T) {
	t.Run("mutual pair, terminal excluded, third untwinned", func(t *testing.T) {
		tasks := []Task{
			{DocID: "x1", Lifecycle: lifeOpen, Title: "wire the sse bridge"},
			{DocID: "x2", Lifecycle: lifeOpen, Title: "wire the sse bridge again"},
			{DocID: "x3", Lifecycle: lifeOpen, Title: "totally unrelated thing"},
			{DocID: "x4", Lifecycle: lifeDone, Title: "wire the sse bridge again"}, // terminal: ignored
		}
		detectTwins(tasks)
		if tasks[0].TwinOf != "x2" || tasks[1].TwinOf != "x1" {
			t.Fatalf("x1/x2 twins = %q/%q, want mutual x2/x1", tasks[0].TwinOf, tasks[1].TwinOf)
		}
		// TwinTitle is precomputed alongside TwinOf so the expanded row can name
		// the partner in words (not the doc id).
		if tasks[0].TwinTitle != "wire the sse bridge again" || tasks[1].TwinTitle != "wire the sse bridge" {
			t.Fatalf("twin titles = %q/%q, want the partners' titles", tasks[0].TwinTitle, tasks[1].TwinTitle)
		}
		if tasks[2].TwinOf != "" {
			t.Fatalf("x3 should be untwinned, got %q", tasks[2].TwinOf)
		}
		if tasks[3].TwinOf != "" {
			t.Fatalf("terminal x4 must never be twinned, got %q", tasks[3].TwinOf)
		}
	})
	t.Run("tie resolves to smaller doc id", func(t *testing.T) {
		// zctr is equally similar to two identical-title peers; the smaller doc_id
		// (aaa < bbb) must win.
		tasks := []Task{
			{DocID: "zctr", Lifecycle: lifeOpen, Title: "shared duplicate title"},
			{DocID: "bbb", Lifecycle: lifeOpen, Title: "shared duplicate title"},
			{DocID: "aaa", Lifecycle: lifeOpen, Title: "shared duplicate title"},
		}
		detectTwins(tasks)
		if tasks[0].TwinOf != "aaa" {
			t.Fatalf("zctr twin = %q, want aaa (tie broken by smaller doc id)", tasks[0].TwinOf)
		}
	})
	t.Run("groups by parent — cross-parent lookalikes never twin", func(t *testing.T) {
		tasks := []Task{
			{DocID: "p1c", ParentID: "p1", Lifecycle: lifeOpen, Title: "same exact title"},
			{DocID: "p2c", ParentID: "p2", Lifecycle: lifeOpen, Title: "same exact title"},
		}
		detectTwins(tasks)
		if tasks[0].TwinOf != "" || tasks[1].TwinOf != "" {
			t.Fatalf("cross-parent rows must not twin: %q/%q", tasks[0].TwinOf, tasks[1].TwinOf)
		}
	})
}

// TestTitleTokens_Unicode — tokenization is Unicode-aware: non-ASCII letters
// (æ/ø/å…) are word characters, not separators, so Norwegian titles keep whole
// words instead of fragmenting into single-letter noise that skews Jaccard.
func TestTitleTokens_Unicode(t *testing.T) {
	got := titleTokens("Håndter feil-kø: EKSPORT nr. 2")
	want := []string{"håndter", "feil", "kø", "eksport", "nr", "2"}
	if len(got) != len(want) {
		t.Fatalf("tokens = %v, want %v", got, want)
	}
	for _, w := range want {
		if !got[w] {
			t.Fatalf("tokens = %v, missing %q", got, w)
		}
	}
	// And the similarity built on it twins two Norwegian near-duplicates.
	tasks := []Task{
		{DocID: "n1", Lifecycle: lifeOpen, Title: "Håndter feilkø i eksporten"},
		{DocID: "n2", Lifecycle: lifeOpen, Title: "Håndter feilkø i eksporten på nytt"},
	}
	detectTwins(tasks)
	if tasks[0].TwinOf != "n2" || tasks[1].TwinOf != "n1" {
		t.Fatalf("norwegian twins = %q/%q, want mutual n2/n1", tasks[0].TwinOf, tasks[1].TwinOf)
	}
}

// TestChildBand_StaleBoundary — the stale band trips EXCLUSIVELY at >7d for a
// non-terminal row (open); a terminal row is band 6 regardless of age, so a fresh
// done sinks below a stale open.
func TestChildBand_StaleBoundary(t *testing.T) {
	cases := []struct {
		name string
		life string
		age  time.Duration
		want int
	}{
		{"fresh in_progress", lifeInProgress, time.Hour, 0},
		{"fresh ready", lifeReady, time.Hour, 1},
		{"fresh blocked", lifeBlocked, time.Hour, 2},
		{"fresh open", lifeOpen, time.Hour, 3},
		{"unknown status", "weird", time.Hour, 4},
		{"open exactly 7d not yet stale", lifeOpen, 7 * 24 * time.Hour, 3},
		{"open one second past 7d stale", lifeOpen, 7*24*time.Hour + time.Second, 5},
		{"stale in_progress also demotes", lifeInProgress, 8 * 24 * time.Hour, 5},
		{"terminal fresh is band 6", lifeDone, time.Hour, 6},
		{"terminal old still band 6 not stale", lifeDone, 30 * 24 * time.Hour, 6},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			task := Task{Lifecycle: tc.life, UpdatedAt: refNow.Add(-tc.age)}
			if got := childBand(task, refNow); got != tc.want {
				t.Fatalf("band(%s,%v) = %d, want %d", tc.life, tc.age, got, tc.want)
			}
		})
	}
}

// TestBoardStale_Count — Board.Stale counts EVERY non-terminal task older than
// 3d anywhere on the board (epic child, cluster member, orphan, or a claimed
// NOW row), and never a terminal one however old. Exclusive at the boundary.
func TestBoardStale_Count(t *testing.T) {
	old := refNow.Add(-3*24*time.Hour - time.Second) // just past 3d -> counts
	edge := refNow.Add(-3 * 24 * time.Hour)          // exactly 3d -> does NOT count
	fresh := refNow.Add(-time.Hour)
	ancient := refNow.Add(-40 * 24 * time.Hour)
	tasks := []Task{
		{DocID: "g", Kind: kindGoal, Lifecycle: lifeInProgress, UpdatedAt: fresh},
		{DocID: "c1", ParentID: "g", Lifecycle: lifeOpen, UpdatedAt: old},  // stale child
		{DocID: "c2", ParentID: "g", Lifecycle: lifeOpen, UpdatedAt: edge}, // boundary, not stale
		{DocID: "o1", Lifecycle: lifeBlocked, UpdatedAt: ancient},          // stale orphan
		{DocID: "o2", Lifecycle: lifeDone, UpdatedAt: ancient},             // terminal -> never counts
	}
	b := BuildBoard(Snapshot{Tasks: tasks}, RepoContext{}, refNow)
	if b.Stale != 2 {
		t.Fatalf("Board.Stale = %d, want 2 (c1 + o1; c2 at the exclusive edge and terminal o2 excluded)", b.Stale)
	}
}

// TestBuildCluster_DoneCue — buildCluster keeps the ≤doneCueMax FRESHEST done
// members as a completion cue and folds the rest, AGE-INDEPENDENT (charter D50):
// three done all <24h old still fold to one cue+tally, mirroring buildEpic.
func TestBuildCluster_DoneCue(t *testing.T) {
	members := []Task{
		{DocID: "keep", Lifecycle: lifeOpen, UpdatedAt: refNow.Add(-time.Hour)},
		{DocID: "d1", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-1 * time.Hour)},
		{DocID: "d2", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-2 * time.Hour)},
		{DocID: "d3", Lifecycle: lifeDone, UpdatedAt: refNow.Add(-3 * time.Hour)}, // 3rd freshest → folds despite being <24h
	}
	c := buildCluster("proj:k", members, refNow, nil, nil)
	if c.DoneFolded != 1 {
		t.Fatalf("DoneFolded = %d, want 1 (only the 2 freshest done survive as the cue)", c.DoneFolded)
	}
	if got := docIDs(c.Tasks); !eq(got, []string{"keep", "d1", "d2"}) {
		t.Fatalf("kept = %v, want [keep d1 d2] (open first, 2-done cue tail newest-first)", got)
	}
}

// ── Wave-7: fold-by-default Active + claim-forward ready head ─────────────────

// mkT is a compact task builder for the wave-7 tests (updated_at = now - ageH).
func mkT(id, parent, kind, life, pri string, ageH int) Task {
	return Task{DocID: id, ParentID: parent, Kind: kind, Lifecycle: life,
		Priority: pri, UpdatedAt: refNow.Add(-time.Duration(ageH) * time.Hour)}
}

// liveClaim marks a task in_progress with a live claim, so BuildBoard lifts it
// into NOW and its owning section becomes Active.
func liveClaim(t Task) Task {
	t.Lifecycle = lifeInProgress
	t.Claim = &Claim{Worker: "w", Epoch: 1, ClaimedAt: refNow.Add(-time.Minute)}
	return t
}

// TestBuildBoard_ActiveOnNowOwnership — an epic / cluster / loose bucket is
// Active exactly when it owns a NOW task (wave-7 D32): the section holding the
// live claim flags Active; the sibling sections that hold only ready/open work
// do not. Active is the SOLE auto-fold input (proven in the fold tests).
func TestBuildBoard_ActiveOnNowOwnership(t *testing.T) {
	tasks := []Task{
		mkT("g1", "", kindGoal, lifeOpen, "", 1),
		liveClaim(mkT("g1c1", "g1", "", lifeOpen, "", 1)), // NOW → g1 Active
		mkT("g1c2", "g1", "", lifeReady, "2", 2),
		mkT("g2", "", kindGoal, lifeOpen, "", 3),
		mkT("g2c1", "g2", "", lifeReady, "1", 1), // no NOW under g2
		// a derived cluster (>=2 members sharing proj:) that owns a live claim:
		liveClaim(mkT("cl1", "", "", lifeOpen, "", 1)),
		mkT("cl2", "", "", lifeReady, "2", 1),
	}
	tasks[5].Labels = []string{"proj:live"}
	tasks[6].Labels = []string{"proj:live"}
	b := BuildBoard(Snapshot{Tasks: tasks}, RepoContext{}, refNow)

	g1 := findEpic(t, b.Epics, "g1")
	if !g1.Active {
		t.Errorf("epic g1 owns a NOW child but is not Active")
	}
	g2 := findEpic(t, b.Epics, "g2")
	if g2.Active {
		t.Errorf("epic g2 owns no NOW work but is Active")
	}
	if len(b.Clusters) != 1 {
		t.Fatalf("want 1 derived cluster, got %d", len(b.Clusters))
	}
	if !b.Clusters[0].Active {
		t.Errorf("cluster proj:live owns a NOW member but is not Active")
	}
}

// TestBuildBoard_OrphansActive — the loose bucket is OrphansActive iff a loose
// task holds a live claim (wave-7 D33). With the claim present it is Active; with
// only ready/open loose work it is not.
func TestBuildBoard_OrphansActive(t *testing.T) {
	active := BuildBoard(Snapshot{Tasks: []Task{
		liveClaim(mkT("o1", "", "", lifeOpen, "", 1)),
		mkT("o2", "", "", lifeReady, "2", 1),
	}}, RepoContext{}, refNow)
	if !active.OrphansActive {
		t.Errorf("loose bucket owns a live claim but OrphansActive is false")
	}
	quiet := BuildBoard(Snapshot{Tasks: []Task{
		mkT("o1", "", "", lifeReady, "1", 1),
		mkT("o2", "", "", lifeOpen, "", 1),
	}}, RepoContext{}, refNow)
	if quiet.OrphansActive {
		t.Errorf("loose bucket has no NOW work but OrphansActive is true")
	}
}

// TestPriorityRank — numeric priority sorts ascending, a leading P/p is tolerated
// (the corpus mixes "0" and "P0"), and absent/non-numeric sorts last.
func TestPriorityRank(t *testing.T) {
	if priorityRank("0") != 0 || priorityRank("P0") != 0 || priorityRank("p0") != 0 {
		t.Errorf("P0 forms should all rank 0")
	}
	if priorityRank("2") >= priorityRank("3") {
		t.Errorf("P2 must rank before P3")
	}
	if priorityRank("") <= priorityRank("4") || priorityRank("urgent") <= priorityRank("4") {
		t.Errorf("absent/non-numeric priority must rank LAST")
	}
}
