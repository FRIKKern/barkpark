package taskboard

import "testing"

// helper: build the byBare index a couple of the predicate tests need.
func frontierByBare(tasks []Task) map[string]Task {
	byID := make(map[string]Task, len(tasks))
	for _, t := range tasks {
		byID[t.DocID] = t
	}
	return buildByBare(byID)
}

// TestAreasOf — authored labels, phase-band derivation, and the authored-wins
// rule (§2/§3.1).
func TestAreasOf(t *testing.T) {
	cases := []struct {
		name        string
		labels      []string
		wantBare    []string
		wantAuthd   bool
		wantDisplay []string
	}{
		{"none", nil, nil, false, nil},
		{"authored one", []string{"area:studio"}, []string{"studio"}, true, []string{"studio"}},
		{"authored two", []string{"area:studio", "area:api"}, []string{"api", "studio"}, true, []string{"api", "studio"}},
		{"derived band", []string{"phase:2-studio"}, []string{"studio"}, false, []string{"~studio"}},
		{"derived multiword", []string{"phase:5-paper-components"}, []string{"pdrender"}, false, []string{"~pdrender"}},
		{"authored beats derived", []string{"area:studio", "phase:2-studio"}, []string{"studio"}, true, []string{"studio"}},
		{"mix", []string{"area:api", "phase:3-web"}, []string{"api", "web"}, true, []string{"api", "~web"}},
		{"phase goal ignored", []string{"phase:goal"}, nil, false, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ai := areasOf(Task{Labels: c.labels})
			if ai.authored != c.wantAuthd {
				t.Errorf("authored = %v, want %v", ai.authored, c.wantAuthd)
			}
			for _, b := range c.wantBare {
				if !ai.bare[b] {
					t.Errorf("missing bare token %q in %v", b, ai.bare)
				}
			}
			if len(ai.bare) != len(c.wantBare) {
				t.Errorf("bare size = %d, want %d (%v)", len(ai.bare), len(c.wantBare), ai.bare)
			}
			if len(ai.display) != len(c.wantDisplay) {
				t.Fatalf("display = %v, want %v", ai.display, c.wantDisplay)
			}
			for i := range c.wantDisplay {
				if ai.display[i] != c.wantDisplay[i] {
					t.Errorf("display[%d] = %q, want %q", i, ai.display[i], c.wantDisplay[i])
				}
			}
		})
	}
}

// TestInterferesTruthTable — the careful core (§3.1). It must NEVER call a
// HARD-signal pair independent.
func TestInterferesTruthTable(t *testing.T) {
	studio := areasOf(Task{Labels: []string{"area:studio"}})
	studioApi := areasOf(Task{Labels: []string{"area:studio", "area:api"}})
	cli := areasOf(Task{Labels: []string{"area:cli"}})
	none := areasOf(Task{})

	// A real cross-root block edge between bareIDs "a" and "b" (slice-2).
	blockAB := buildCrossAdj(map[string][]string{"a": {"b"}})

	// df-file-edge: declared file blast radii. fileX/fileY are disjoint files,
	// fileDir is a directory prefix that CONTAINS fileX.
	fileX := map[string]bool{"internal/cli/x.go": true}
	fileY := map[string]bool{"internal/cli/y.go": true}
	fileDir := map[string]bool{"internal/cli/": true}

	cases := []struct {
		name        string
		ai, bi      areaInfo
		fa, fb      map[string]bool
		nkA, nkB    string
		cross       crossAdj
		containment bool
		want        interfereTier
	}{
		{"area overlap → HARD", studio, studioApi, nil, nil, "proj:x", "proj:y", nil, false, tierHard},
		{"area disjoint → NONE", studio, cli, nil, nil, "proj:x", "proj:y", nil, false, tierNone},
		{"area disjoint same nbhd → NONE (intra-epic parallel)", studio, cli, nil, nil, "root:e", "root:e", nil, false, tierNone},
		{"one area-less, same nbhd → HARD", studio, none, nil, nil, "root:e", "root:e", nil, false, tierHard},
		{"one area-less, diff nbhd → UNKNOWN", studio, none, nil, nil, "proj:x", "proj:y", nil, false, tierUnknown},
		{"both area-less, same nbhd → HARD", none, none, nil, nil, "root:e", "root:e", nil, false, tierHard},
		{"both area-less, diff nbhd → UNKNOWN (strangers)", none, none, nil, nil, "proj:x", "proj:y", nil, false, tierUnknown},
		// slice-2: a cross-root block edge overrides even disjoint proven areas.
		{"cross edge overrides disjoint areas → HARD", studio, cli, nil, nil, "proj:x", "proj:y", blockAB, false, tierHard},
		{"cross edge overrides area-less diff nbhd → HARD", none, none, nil, nil, "proj:x", "proj:y", blockAB, false, tierHard},
		// df-exclude-epic-roots: a parent↔own-descendant pair in the SAME nbhd is
		// containment, so the area-less proxy is LIFTED (root never displaces child).
		{"area-less parent↔child same nbhd → UNKNOWN (containment lifts)", studio, none, nil, nil, "root:e", "root:e", nil, true, tierUnknown},
		{"both area-less parent↔child same nbhd → UNKNOWN (containment lifts)", none, none, nil, nil, "root:e", "root:e", nil, true, tierUnknown},
		// …but a REAL cross-root block edge still hard-conflicts even under containment.
		{"cross edge beats containment → HARD", none, none, nil, nil, "root:e", "root:e", blockAB, true, tierHard},
		// df-file-edge: both declare + intersecting files ⇒ HARD, overriding
		// disjoint proven areas.
		{"declared intersecting files override disjoint areas → HARD", studio, cli, fileX, fileX, "proj:x", "proj:y", nil, false, tierHard},
		// both declare + DISJOINT files ⇒ NONE, overriding a same-neighborhood
		// area-less proxy that would otherwise be HARD.
		{"declared disjoint files same nbhd → NONE (file truth overrides proxy)", none, none, fileX, fileY, "root:e", "root:e", nil, false, tierNone},
		// both declare + disjoint files ⇒ NONE, overriding an AREA overlap too.
		{"declared disjoint files override area overlap → NONE", studio, studio, fileX, fileY, "proj:x", "proj:y", nil, false, tierNone},
		// dir-prefix containment counts as an intersection.
		{"declared dir-prefix contains file → HARD", none, none, fileDir, fileX, "proj:x", "proj:y", nil, false, tierHard},
		// one side undeclared ⇒ ABSTAIN: fall through to the neighborhood proxy
		// (same nbhd, area-less ⇒ HARD) — undeclared is never silently safe.
		{"one side files-undeclared same nbhd → HARD (abstain, proxy governs)", none, none, fileX, nil, "root:e", "root:e", nil, false, tierHard},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := interferes(c.ai, c.bi, c.fa, c.fb, c.nkA, c.nkB, "a", "b", c.cross, c.containment); got != c.want {
				t.Errorf("interferes = %v, want %v", got, c.want)
			}
			// symmetry — the predicate must not depend on argument order
			if got := interferes(c.bi, c.ai, c.fb, c.fa, c.nkB, c.nkA, "b", "a", c.cross, c.containment); got != c.want {
				t.Errorf("interferes (swapped) = %v, want %v", got, c.want)
			}
		})
	}
}

// TestNeighborhoodKeyProjMerge — proj: label wins over root, so proj:loop's two
// distinct roots MERGE into one blast radius (§3.3, the careful win in the data).
func TestNeighborhoodKeyProjMerge(t *testing.T) {
	tasks := []Task{
		{DocID: "schema-root", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "security-root", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", ParentID: "schema-root", Lifecycle: lifeReady, Labels: []string{"proj:loop"}},
		{DocID: "b", ParentID: "security-root", Lifecycle: lifeReady, Labels: []string{"proj:loop"}},
	}
	byBare := frontierByBare(tasks)
	ka := neighborhoodKey(tasks[2], byBare, nil)
	kb := neighborhoodKey(tasks[3], byBare, nil)
	if ka != kb {
		t.Errorf("proj:loop keys differ (%q vs %q) — the two roots must MERGE", ka, kb)
	}
	if ka != "proj:loop" {
		t.Errorf("neighborhoodKey = %q, want proj:loop", ka)
	}
}

// TestNeighborhoodKeyDesignDocTier — with no proj label, design_doc keys the
// neighborhood; a nil DetailIndex falls back to the root (1:1 on the corpus).
func TestNeighborhoodKeyDesignDocTier(t *testing.T) {
	tasks := []Task{
		{DocID: "r", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "x", ParentID: "r", Lifecycle: lifeReady},
	}
	byBare := frontierByBare(tasks)
	if got := neighborhoodKey(tasks[1], byBare, nil); got != "root:r" {
		t.Errorf("nil details key = %q, want root:r", got)
	}
	details := DetailIndex{"x": TaskDetail{DesignDoc: "airdrop"}}
	if got := neighborhoodKey(tasks[1], byBare, details); got != "doc:airdrop" {
		t.Errorf("design_doc key = %q, want doc:airdrop", got)
	}
}

// TestFrontierProjLoopMerge — end-to-end: two ready tasks sharing proj:loop
// across two roots collapse to ONE frontier pick (D66's root-only key would
// emit both). The loser is listed as the winner's displaced cost.
func TestFrontierProjLoopMerge(t *testing.T) {
	tasks := []Task{
		{DocID: "schema-root", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "security-root", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", Title: "loop A", ParentID: "schema-root", Lifecycle: lifeReady, Labels: []string{"proj:loop"}, Priority: "1"},
		{DocID: "b", Title: "loop B", ParentID: "security-root", Lifecycle: lifeReady, Labels: []string{"proj:loop"}, Priority: "2"},
	}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	if len(picks) != 1 {
		t.Fatalf("frontier = %d picks, want 1 (proj:loop merges the two roots)", len(picks))
	}
	if picks[0].Task.DocID != "a" {
		t.Errorf("winner = %q, want a (higher priority)", picks[0].Task.DocID)
	}
	if len(picks[0].Displaced) != 1 || picks[0].Displaced[0].DocID != "b" {
		t.Errorf("displaced = %+v, want [b]", picks[0].Displaced)
	}
}

// TestFrontierAreaOverlapDropsLower — two tasks in DIFFERENT neighborhoods but
// overlapping areas: the lower-scored is dropped (§3.1 correctness core).
func TestFrontierAreaOverlapDropsLower(t *testing.T) {
	tasks := []Task{
		{DocID: "e1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "e2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "hi", Title: "high", ParentID: "e1", Lifecycle: lifeReady, Priority: "0", Labels: []string{"proj:one", "area:studio"}},
		{DocID: "lo", Title: "low", ParentID: "e2", Lifecycle: lifeReady, Priority: "3", Labels: []string{"proj:two", "area:studio", "area:web"}},
	}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	if len(picks) != 1 {
		t.Fatalf("frontier = %d, want 1 (shared area:studio)", len(picks))
	}
	if picks[0].Task.DocID != "hi" {
		t.Errorf("winner = %q, want hi (P0 beats P3)", picks[0].Task.DocID)
	}
	if len(picks[0].Displaced) != 1 || picks[0].Displaced[0].DocID != "lo" {
		t.Fatalf("displaced = %+v, want [lo]", picks[0].Displaced)
	}
	if got := picks[0].Displaced[0].Reason; got != "shared surface area:studio" {
		t.Errorf("displaced reason = %q, want shared surface area:studio", got)
	}
}

// TestFrontierIntraEpicParallel — two area-DISJOINT tasks in the SAME epic both
// admit: the whole point of area: (the road to 50 agents). (§2, test iv.)
func TestFrontierIntraEpicParallel(t *testing.T) {
	tasks := []Task{
		{DocID: "epic", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "s", Title: "studio bit", ParentID: "epic", Lifecycle: lifeReady, Priority: "1", Labels: []string{"proj:big", "area:studio"}},
		{DocID: "c", Title: "cli bit", ParentID: "epic", Lifecycle: lifeReady, Priority: "1", Labels: []string{"proj:big", "area:cli"}},
	}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	if len(picks) != 2 {
		t.Fatalf("frontier = %d, want 2 (disjoint areas parallelize within one epic)", len(picks))
	}
	for _, p := range picks {
		if p.Risk != RiskIsolated {
			t.Errorf("%s risk = %s, want isolated (authored, disjoint)", p.Task.DocID, p.Risk)
		}
	}
}

// TestFrontierSharedSurfaceSolo — a broad epic (≥3 areas, e.g. the derived
// aesthetic-unification bands) is marked SOLO (§3.3, §4).
func TestFrontierSharedSurfaceSolo(t *testing.T) {
	tasks := []Task{
		{DocID: "au", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "w", Title: "token emitters", ParentID: "au", Lifecycle: lifeReady, Priority: "1",
			Labels: []string{"proj:design-system", "phase:2-studio", "phase:3-web", "phase:4-cli", "phase:5-paper-components"}},
	}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	if len(picks) != 1 {
		t.Fatalf("frontier = %d, want 1", len(picks))
	}
	p := picks[0]
	if p.Risk != RiskSharedSurface || !p.Solo {
		t.Errorf("risk/solo = %s/%v, want shared-surface/true (4 derived surfaces)", p.Risk, p.Solo)
	}
	if len(p.Areas) < 3 {
		t.Errorf("areas = %v, want ≥3 derived surfaces", p.Areas)
	}
}

// TestFrontierRiskClasses — the neighborhood vs unproven distinction.
func TestFrontierRiskClasses(t *testing.T) {
	tasks := []Task{
		{DocID: "e1", Kind: kindGoal, Lifecycle: lifeOpen},
		// two area-less siblings in one epic → the survivor is a neighborhood rep
		{DocID: "n1", ParentID: "e1", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "n2", ParentID: "e1", Lifecycle: lifeReady, Priority: "2"},
		// a lone area-less stranger → unproven
		{DocID: "lone", Kind: kindGoal, Lifecycle: lifeReady, Priority: "1"},
	}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	risk := map[string]RiskClass{}
	for _, p := range picks {
		risk[p.Task.DocID] = p.Risk
	}
	if risk["n1"] != RiskNeighborhood {
		t.Errorf("n1 risk = %s, want neighborhood (it suppressed a sibling)", risk["n1"])
	}
	if risk["lone"] != RiskUnproven {
		t.Errorf("lone risk = %s, want unproven (metadata-thin stranger)", risk["lone"])
	}
}

// TestFrontierDeterministic — the same snapshot yields the same frontier, and
// equal-score ties break on the stable bareID.
func TestFrontierDeterministic(t *testing.T) {
	tasks := []Task{
		{DocID: "e1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "e2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "zeta", ParentID: "e1", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "alpha", ParentID: "e2", Lifecycle: lifeReady, Priority: "1"},
	}
	var first []string
	for i := 0; i < 5; i++ {
		picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
		var order []string
		for _, p := range picks {
			order = append(order, p.Task.DocID)
		}
		if i == 0 {
			first = order
			continue
		}
		if len(order) != len(first) {
			t.Fatalf("run %d length %d != %d", i, len(order), len(first))
		}
		for j := range order {
			if order[j] != first[j] {
				t.Fatalf("run %d order %v != %v (non-deterministic)", i, order, first)
			}
		}
	}
	// equal score → alpha before zeta (bareID asc)
	if len(first) != 2 || first[0] != "alpha" {
		t.Errorf("tie order = %v, want [alpha zeta] (bareID asc)", first)
	}
}

// TestFrontierMaxAndProvenOnly — the two opts (§4, criterion 6).
func TestFrontierMaxAndProvenOnly(t *testing.T) {
	tasks := []Task{
		{DocID: "e1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "e2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "e3", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "proven", ParentID: "e1", Lifecycle: lifeReady, Priority: "0", Labels: []string{"proj:one", "area:studio"}},
		{DocID: "thin1", ParentID: "e2", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "thin2", ParentID: "e3", Lifecycle: lifeReady, Priority: "2"},
	}
	// Unbounded: all three admit (studio disjoint from the area-less strangers).
	all := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	if len(all) != 3 {
		t.Fatalf("unbounded = %d, want 3", len(all))
	}
	// --max 2 caps to the two highest-scored.
	capped := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{Max: 2})
	if len(capped) != 2 {
		t.Fatalf("--max 2 = %d, want 2", len(capped))
	}
	// --proven-only keeps ONLY the area-proven isolated pick.
	proven := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{ProvenOnly: true})
	if len(proven) != 1 || proven[0].Task.DocID != "proven" {
		t.Fatalf("--proven-only = %+v, want just [proven]", proven)
	}
	if proven[0].Risk != RiskIsolated {
		t.Errorf("proven risk = %s, want isolated", proven[0].Risk)
	}
}

// TestFrontierCrossRootBlockEdge — slice-2 (df-graph-crossdep): a REAL cross-
// root `blocks` edge passed in via FrontierOpts.CrossEdges makes two otherwise-
// INDEPENDENT tasks (different roots, disjoint proven areas) INTERFERE, so only
// one is admitted. With empty CrossEdges the pair parallelizes — the regression
// guard that slice-1 behavior is unchanged.
func TestFrontierCrossRootBlockEdge(t *testing.T) {
	tasks := []Task{
		{DocID: "r1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "r2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", Title: "studio bit", ParentID: "r1", Lifecycle: lifeReady, Priority: "0", Labels: []string{"proj:one", "area:studio"}},
		{DocID: "b", Title: "cli bit", ParentID: "r2", Lifecycle: lifeReady, Priority: "3", Labels: []string{"proj:two", "area:cli"}},
	}

	// Baseline (empty CrossEdges): disjoint areas across two roots → BOTH admit.
	base := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	if len(base) != 2 {
		t.Fatalf("baseline (empty CrossEdges) = %d picks, want 2 — slice-1 regression", len(base))
	}

	// A real cross-root block edge a↔b collapses them to one pick.
	opts := FrontierOpts{CrossEdges: map[string][]string{"a": {"b"}}}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, opts)
	if len(picks) != 1 {
		t.Fatalf("with cross edge = %d picks, want 1 (the block edge interferes)", len(picks))
	}
	if picks[0].Task.DocID != "a" {
		t.Errorf("winner = %q, want a (P0 beats P3)", picks[0].Task.DocID)
	}
	if len(picks[0].Displaced) != 1 || picks[0].Displaced[0].DocID != "b" {
		t.Fatalf("displaced = %+v, want [b]", picks[0].Displaced)
	}
	if got := picks[0].Displaced[0].Reason; got != "blocks edge a" {
		t.Errorf("displaced reason = %q, want %q", got, "blocks edge a")
	}
}

// TestFrontierCrossEdgeUndirected — the edge is undirected: supplying it as
// b→a interferes the same pair as a→b.
func TestFrontierCrossEdgeUndirected(t *testing.T) {
	tasks := []Task{
		{DocID: "r1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "r2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", ParentID: "r1", Lifecycle: lifeReady, Priority: "0", Labels: []string{"proj:one", "area:studio"}},
		{DocID: "b", ParentID: "r2", Lifecycle: lifeReady, Priority: "3", Labels: []string{"proj:two", "area:cli"}},
	}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{CrossEdges: map[string][]string{"b": {"a"}}})
	if len(picks) != 1 {
		t.Fatalf("with b→a edge = %d picks, want 1 (undirected)", len(picks))
	}
}

// TestReadyRootSpanGuard — the zero-fetch guard: a single-root ready set spans
// <2 roots (so the CLI makes zero graph.show calls); a multi-root ready set
// spans exactly its distinct roots.
func TestReadyRootSpanGuard(t *testing.T) {
	oneRoot := []Task{
		{DocID: "r1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", ParentID: "r1", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "b", ParentID: "r1", Lifecycle: lifeReady, Priority: "2"},
	}
	if got := ReadyRootSpan(Snapshot{Tasks: oneRoot}); len(got) != 1 {
		t.Errorf("single-root span = %v, want len 1 (< 2 ⇒ zero graph.show calls)", got)
	}
	twoRoots := []Task{
		{DocID: "r1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "r2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", ParentID: "r1", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "c", ParentID: "r2", Lifecycle: lifeReady, Priority: "1"},
	}
	if got := ReadyRootSpan(Snapshot{Tasks: twoRoots}); len(got) != 2 {
		t.Errorf("two-root span = %v, want len 2", got)
	}
}

// TestCrossRootBlockEdgesFold — the fold keeps only cross-root edges between
// ready candidates, drops same-root and non-candidate edges, and is symmetric.
func TestCrossRootBlockEdgesFold(t *testing.T) {
	tasks := []Task{
		{DocID: "r1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "r2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", ParentID: "r1", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "a2", ParentID: "r1", Lifecycle: lifeReady, Priority: "1"}, // same root as a
		{DocID: "b", ParentID: "r2", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "done", ParentID: "r2", Lifecycle: lifeOpen}, // not ready
	}
	edges := []GraphEdge{
		{From: "a", To: "b"},     // cross-root, both ready → KEEP
		{From: "a", To: "a2"},    // same root → drop
		{From: "b", To: "done"},  // endpoint not ready → drop
		{From: "a", To: "ghost"}, // endpoint not a candidate → drop
	}
	got := CrossRootBlockEdges(Snapshot{Tasks: tasks}, edges)
	if len(got) != 2 { // symmetric: a↔b appears under both keys
		t.Fatalf("fold = %+v, want 2 keys (a and b)", got)
	}
	if len(got["a"]) != 1 || got["a"][0] != "b" {
		t.Errorf("got[a] = %v, want [b]", got["a"])
	}
	if len(got["b"]) != 1 || got["b"][0] != "a" {
		t.Errorf("got[b] = %v, want [a]", got["b"])
	}
	// No qualifying edge ⇒ nil (slice-1 behavior).
	if CrossRootBlockEdges(Snapshot{Tasks: tasks}, []GraphEdge{{From: "a", To: "a2"}}) != nil {
		t.Errorf("same-root-only fold should be nil")
	}
}

// TestFrontierEpicRootDoesNotDisplaceChildren — the load-bearing fixture for
// df-exclude-epic-roots. An area-less epic ROOT that is itself READY (and thus a
// high-scored candidate) used to share its children's neighborhood key and, via
// the area-less proxy, HARD-conflict — and displace — every disjoint-area child,
// pinning proven at 0 and the frontier at 1 pick. The containment lift makes the
// three children run in parallel: proven climbs 0 → 3.
func TestFrontierEpicRootDoesNotDisplaceChildren(t *testing.T) {
	tasks := []Task{
		{DocID: "epic", Title: "epic root", Kind: kindGoal, Lifecycle: lifeReady, Priority: "0"},
		{DocID: "s", Title: "studio bit", ParentID: "epic", Lifecycle: lifeReady, Priority: "1", Labels: []string{"area:studio"}},
		{DocID: "c", Title: "cli bit", ParentID: "epic", Lifecycle: lifeReady, Priority: "1", Labels: []string{"area:cli"}},
		{DocID: "w", Title: "web bit", ParentID: "epic", Lifecycle: lifeReady, Priority: "1", Labels: []string{"area:web"}},
	}

	// BEFORE/AFTER at the predicate: the SAME root↔child pair is tierHard without
	// containment (the mechanism that displaced children) and tierUnknown with it.
	byBare := frontierByBare(tasks)
	rootAI, kidAI := areasOf(tasks[0]), areasOf(tasks[1])
	if got := interferes(rootAI, kidAI, nil, nil, "root:epic", "root:epic", "epic", "s", nil, false); got != tierHard {
		t.Fatalf("precondition: root↔child WITHOUT containment = %v, want tierHard (the bug)", got)
	}
	if got := interferes(rootAI, kidAI, nil, nil, "root:epic", "root:epic", "epic", "s", nil, true); got != tierUnknown {
		t.Fatalf("fix: root↔child WITH containment = %v, want tierUnknown (no displacement)", got)
	}
	if !isAncestorBare(byBare, "epic", "s") {
		t.Fatal("epic must be detected as an ancestor of s")
	}

	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	proven := 0
	for _, p := range picks {
		if p.Proven() {
			proven++
		}
		if p.Task.DocID == "epic" && len(p.Displaced) != 0 {
			t.Errorf("root displaced %+v — it must NEVER displace its own children", p.Displaced)
		}
	}
	// BEFORE the fix: 1 pick (the root), proven 0. AFTER: the three disjoint-area
	// children parallelize, proven 0 → 3.
	if proven != 3 {
		t.Errorf("proven = %d, want 3 (children parallelize; was 0 before the fix)", proven)
	}
	if len(picks) < 2 {
		t.Fatalf("frontier = %d picks, want >1 (root no longer displaces its children)", len(picks))
	}
}

// TestFrontierAreaLessSiblingsStillConflict — the peer guard: two area-less
// NON-parent siblings must STILL hard-conflict via the conservative proxy. The
// containment lift is strictly parent↔own-descendant; it must not leak to peers.
func TestFrontierAreaLessSiblingsStillConflict(t *testing.T) {
	tasks := []Task{
		{DocID: "epic", Kind: kindGoal, Lifecycle: lifeOpen}, // parent, not a candidate
		{DocID: "a", Title: "a", ParentID: "epic", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "b", Title: "b", ParentID: "epic", Lifecycle: lifeReady, Priority: "2"},
	}
	picks := Frontier(Snapshot{Tasks: tasks}, nil, nil, refNow, FrontierOpts{})
	if len(picks) != 1 {
		t.Fatalf("frontier = %d, want 1 (area-less siblings still conflict — proxy intact for peers)", len(picks))
	}
}

// TestFrontierEqualsIndependentReady — the shared-model invariant: the board's
// capacity read IS len(Frontier) with the default opts (T2).
func TestFrontierEqualsIndependentReady(t *testing.T) {
	tasks := []Task{
		{DocID: "e1", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "e2", Kind: kindGoal, Lifecycle: lifeOpen},
		{DocID: "a", ParentID: "e1", Lifecycle: lifeReady, Priority: "1"},
		{DocID: "b", ParentID: "e1", Lifecycle: lifeReady, Priority: "2"},
		{DocID: "c", ParentID: "e2", Lifecycle: lifeReady, Priority: "1"},
	}
	b := BuildBoard(Snapshot{Tasks: tasks}, RepoContext{}, refNow)
	want := len(Frontier(Snapshot{Tasks: tasks}, nil, b.Now, refNow, FrontierOpts{}))
	if b.IndependentReady != want {
		t.Errorf("IndependentReady = %d, len(Frontier) = %d — they must be equal", b.IndependentReady, want)
	}
	if b.IndependentReady != 2 {
		t.Errorf("IndependentReady = %d, want 2 (two epics, one pick each)", b.IndependentReady)
	}
}

// TestFilesOf — the files: label parser (df-file-edge): one path per label,
// leading "./" and "/" and whitespace normalized, trailing "/" preserved as the
// dir-prefix marker, undeclared ⇒ empty set.
func TestFilesOf(t *testing.T) {
	cases := []struct {
		name   string
		labels []string
		want   []string
	}{
		{"none", nil, nil},
		{"one", []string{"files:internal/cli/x.go"}, []string{"internal/cli/x.go"}},
		{"two", []string{"files:a.go", "files:b.go"}, []string{"a.go", "b.go"}},
		{"dir prefix preserved", []string{"files:internal/taskboard/"}, []string{"internal/taskboard/"}},
		{"leading ./ stripped", []string{"files:./internal/x.go"}, []string{"internal/x.go"}},
		{"leading / stripped", []string{"files:/internal/x.go"}, []string{"internal/x.go"}},
		{"whitespace trimmed", []string{"files: internal/x.go "}, []string{"internal/x.go"}},
		{"empty label ignored", []string{"files:"}, nil},
		{"non-files labels ignored", []string{"area:cli", "phase:2-cli"}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := FilesOf(Task{Labels: c.labels})
			if len(got) != len(c.want) {
				t.Fatalf("FilesOf = %v, want %v", got, c.want)
			}
			for _, p := range c.want {
				if !got[p] {
					t.Errorf("missing %q in %v", p, got)
				}
			}
		})
	}
}

// TestFilesIntersect — exact equality and dir-prefix containment both intersect
// and name the shared path; unrelated paths do not.
func TestFilesIntersect(t *testing.T) {
	cases := []struct {
		name       string
		a, b       map[string]bool
		wantShared string
		wantHit    bool
	}{
		{"exact", map[string]bool{"a.go": true}, map[string]bool{"a.go": true}, "a.go", true},
		{"disjoint", map[string]bool{"a.go": true}, map[string]bool{"b.go": true}, "", false},
		{"dir contains file", map[string]bool{"internal/cli/": true}, map[string]bool{"internal/cli/x.go": true}, "internal/cli/", true},
		{"file under dir (swapped)", map[string]bool{"internal/cli/x.go": true}, map[string]bool{"internal/cli/": true}, "internal/cli/", true},
		{"sibling dir no match", map[string]bool{"internal/cli/": true}, map[string]bool{"internal/tui/x.go": true}, "", false},
		{"prefix-but-not-dir no match", map[string]bool{"internal/cli": true}, map[string]bool{"internal/cli/x.go": true}, "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			shared, hit := filesIntersect(c.a, c.b)
			if hit != c.wantHit || shared != c.wantShared {
				t.Errorf("filesIntersect = (%q, %v), want (%q, %v)", shared, hit, c.wantShared, c.wantHit)
			}
		})
	}
}

// TestFrontierFileEdgeOnrampsDenyPath — the onramps-w2 collision reconstructed
// (provenance: merge 56b144f6, bp-agent-onramps-w2-charter.md:48). Three ready
// tasks in THREE DIFFERENT epic roots, NO area: labels, each declaring
// files:internal/cli/onramp_cmd.go. The file edge is the SOLE catcher: the
// frontier admits exactly ONE and every displaced reason names the shared file.
// The CONTROL (same trio WITHOUT files: labels) co-admits all three — deleting
// the file edge turns THIS test red.
func TestFrontierFileEdgeOnrampsDenyPath(t *testing.T) {
	mk := func(withFiles bool) []Task {
		var labels []string
		if withFiles {
			labels = []string{"files:internal/cli/onramp_cmd.go"}
		}
		return []Task{
			{DocID: "hub-root", Kind: kindGoal, Lifecycle: lifeOpen},
			{DocID: "verb-root", Kind: kindGoal, Lifecycle: lifeOpen},
			{DocID: "doc-root", Kind: kindGoal, Lifecycle: lifeOpen},
			{DocID: "hub", Title: "onramp hub", ParentID: "hub-root", Lifecycle: lifeReady, Priority: "0", Labels: labels},
			{DocID: "verb", Title: "onramp verb", ParentID: "verb-root", Lifecycle: lifeReady, Priority: "1", Labels: labels},
			{DocID: "doc", Title: "onramp docs", ParentID: "doc-root", Lifecycle: lifeReady, Priority: "2", Labels: labels},
		}
	}

	picks := Frontier(Snapshot{Tasks: mk(true)}, nil, nil, refNow, FrontierOpts{})
	if len(picks) != 1 {
		t.Fatalf("file-edge frontier = %d picks, want 1 (all three share onramp_cmd.go)", len(picks))
	}
	if picks[0].Task.DocID != "hub" {
		t.Errorf("winner = %q, want hub (P0 beats P1/P2)", picks[0].Task.DocID)
	}
	if len(picks[0].Displaced) != 2 {
		t.Fatalf("displaced = %d, want 2", len(picks[0].Displaced))
	}
	for _, d := range picks[0].Displaced {
		if d.Reason != "files internal/cli/onramp_cmd.go" {
			t.Errorf("displaced reason = %q, want %q (must name the shared file)", d.Reason, "files internal/cli/onramp_cmd.go")
		}
	}
	// the admitted pick is file-proven isolated (strongest tag), so it is proven.
	if picks[0].Risk != RiskFileIsolated {
		t.Errorf("risk = %s, want file-isolated", picks[0].Risk)
	}
	if !picks[0].Proven() {
		t.Errorf("a file-isolated pick must count as proven")
	}

	// CONTROL: strip the files: labels — three area-less strangers in three roots
	// are unproven independents, so ALL THREE co-admit. This proves the file edge
	// is the SOLE catcher.
	ctrl := Frontier(Snapshot{Tasks: mk(false)}, nil, nil, refNow, FrontierOpts{})
	if len(ctrl) != 3 {
		t.Fatalf("control (no files:) = %d picks, want 3 — the file edge is the sole catcher", len(ctrl))
	}
}
