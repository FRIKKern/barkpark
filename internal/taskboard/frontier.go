package taskboard

// frontier.go — the dispatch-frontier model (task-TUI epic, wave 13).
//
// The wish (2026-07-06, verbatim): "The system should typically always figure
// out how many tasks we can take on at once … base next on all the different
// spots not impacting each other bad — maybe sometimes even sending out 50
// agents … we must know when impact blast radius each other and ruin it — we
// must be careful but ambitious."
//
// D65/D66 shipped the crude version: the NEXT strip is curated and takes at
// most one pick per ROOT. This file is the REAL interference model both the
// TUI count (Board.IndependentReady) and the CLI verb (`bp task frontier`)
// read — ONE function, so the two surfaces can never drift.
//
// The model is CONSERVATIVE by construction: it never calls two tasks that
// share a HARD signal independent. Missing metadata always buys LESS
// parallelism, never more. Where it is honest about its own blind spot is the
// `unproven` risk class (§4 of the design) — a stranger pair with no `area:`
// label is dispatched but FLAGGED, never silently upgraded to "safe".
//
// Slice 1: the pure predicate + greedy MWIS over ready tasks, with NO graph I/O.
//
// Slice 2 (df-graph-crossdep): cross-root block-edge PRECISION. The function
// stays PURE — it never calls `graph.show`. Instead the caller fetches the
// real cross-root `blocks` edges from the graph API OUTSIDE this function and
// folds them into FrontierOpts.CrossEdges. `interferes` then consults that
// edge set and returns tierHard for any candidate pair joined by a real block
// edge, overriding the counts-only neighborhood proxy. A cross-root block edge
// is the hardest signal there is: the two tasks have a genuine dependency, so
// they must never both be dispatched — regardless of disjoint `area:` surfaces
// that would otherwise clear them to run in parallel. Empty/nil CrossEdges ⇒
// exact slice-1 behavior (the board path, and any caller that supplies none).

import (
	"sort"
	"strings"
	"time"
)

// FrontierOpts tunes the dispatch frontier. The zero value is the honest,
// ambitious default: unbounded capacity, all risk classes emitted.
type FrontierOpts struct {
	// Max caps the number of emitted picks (highest-scored first). Zero or
	// negative means unbounded — the true capacity, which is what
	// Board.IndependentReady reads.
	Max int
	// ProvenOnly is the maximally-careful dial (§4): emit ONLY `isolated`
	// picks — the set whose surface disjointness is PROVEN by authored `area:`
	// labels. Everything metadata-thin is withheld. This is the "safe set" the
	// table footer points an orchestrator at.
	ProvenOnly bool
	// CrossEdges carries the REAL cross-root `blocks` edges (slice-2), fetched
	// from the graph API OUTSIDE this pure function and passed in. It is keyed by
	// bareID → the bareIDs it shares a `blocks` dependency with across root
	// trees. The direction of the edge is irrelevant to interference, so the
	// map need not be symmetric — Frontier symmetrises it internally. An edge
	// here forces tierHard interference between the two candidates, overriding
	// the counts-only neighborhood proxy. Empty/nil ⇒ exact slice-1 behavior.
	CrossEdges map[string][]string
}

// RiskClass stamps each pick with how safe it is to batch (§4 of the design).
type RiskClass string

const (
	// RiskIsolated — carries an authored `area:` label and is provably disjoint
	// from every other admitted pick. Batch freely. The only class ProvenOnly
	// emits, and the only class counted "proven".
	RiskIsolated RiskClass = "isolated"
	// RiskNeighborhood — no authored `area:`; admitted as its neighborhood's
	// sole representative (it suppressed ≥1 same-neighborhood sibling). Safe by
	// the conservative proxy, but cannot parallelize WITHIN its own epic until
	// `area:` labels land.
	RiskNeighborhood RiskClass = "neighborhood"
	// RiskUnproven — no authored `area:`, a lone stranger coexisting with other
	// area-less strangers. Independent by assumption, FLAGGED. The model never
	// silently upgrades it to safe.
	RiskUnproven RiskClass = "unproven"
	// RiskSharedSurface — a broad epic (≥3 areas across the shared token
	// manifest). Emitted solo:true; an orchestrator honoring solo runs it alone.
	RiskSharedSurface RiskClass = "shared-surface"
)

// Displaced is one candidate a pick knocked out of the frontier — the
// blast-radius COST the orchestrator sees: dispatching this pick means these
// tasks cannot run alongside it.
type Displaced struct {
	DocID  string
	Title  string
	Reason string // "same neighborhood <key>" | "shared surface area:<x>"
}

// Pick is one admitted dispatch-frontier entry — a spot an agent can take
// right now without its blast radius colliding with the others.
type Pick struct {
	Task            Task
	Score           int
	Reason          string   // dominant D65 reason ("continues <root>", "unblocks N", "")
	NeighborhoodKey string   // the blast-radius key: proj: else design_doc else root
	Areas           []string // surface tokens; a "~" prefix marks a phase-band-DERIVED (provisional) area
	Risk            RiskClass
	Solo            bool        // an orchestrator honoring solo runs this alone (broad epic)
	Displaced       []Displaced // what this pick displaced (its blast-radius cost)
}

// Proven reports whether the pick's surface disjointness is PROVEN (an
// authored `area:` label), the footer's proven/unproven tally key.
func (p Pick) Proven() bool { return p.Risk == RiskIsolated }

// phaseBandArea maps a phase-band slug (`phase:<n>-<slug>`) to the code surface
// it implies (§2 of the design). It lets a broad epic whose bands already NAME
// its surfaces become partly-parallelizable before a single `area:` label is
// authored by hand. Derived areas are always marked provisional ("~") so the
// reader knows the surface was inferred, not declared.
var phaseBandArea = map[string]string{
	"studio":           "studio",
	"web":              "web",
	"cli":              "cli",
	"tui":              "tui",
	"api":              "api",
	"sdk":              "sdk",
	"sheets":           "sheets",
	"onix":             "onix",
	"docs":             "docs",
	"infra":            "infra",
	"pdrender":         "pdrender",
	"paper-components": "pdrender",
	"paper":            "pdrender",
}

// areaInfo is the resolved surface footprint of one task: the bare surface
// tokens it touches, whether ANY of them was authored (vs phase-band-derived),
// and the sorted display forms ("~" prefix on a derived-only token).
type areaInfo struct {
	bare     map[string]bool // surface token -> present (studio, api, …)
	authored bool            // ≥1 token came from an explicit area: label
	display  []string        // sorted display forms; "~studio" = derived
}

func (a areaInfo) empty() bool { return len(a.bare) == 0 }

// areasOf resolves a task's surface footprint (§2/§3.1): authored `area:`
// labels first (real, human-declared), then a provisional `~` derivation from
// any `phase:<n>-<slug>` band whose slug names a known surface. A token that is
// authored wins over its derived form (no "~" on an authored surface).
func areasOf(t Task) areaInfo {
	ai := areaInfo{bare: map[string]bool{}}
	authoredTok := map[string]bool{}
	for _, l := range t.Labels {
		if !strings.HasPrefix(l, labelAreaPrefix) {
			continue
		}
		tok := strings.TrimSpace(strings.TrimPrefix(l, labelAreaPrefix))
		if tok == "" {
			continue
		}
		ai.bare[tok] = true
		authoredTok[tok] = true
		ai.authored = true
	}
	derived := map[string]bool{}
	for _, l := range t.Labels {
		if !strings.HasPrefix(l, labelPhasePrefix) {
			continue
		}
		slug := phaseBandSlug(l)
		tok, ok := phaseBandArea[slug]
		if !ok {
			continue
		}
		if authoredTok[tok] {
			continue // an authored area already covers this surface
		}
		if !ai.bare[tok] {
			ai.bare[tok] = true
			derived[tok] = true
		}
	}
	for tok := range ai.bare {
		if derived[tok] && !authoredTok[tok] {
			ai.display = append(ai.display, "~"+tok)
		} else {
			ai.display = append(ai.display, tok)
		}
	}
	sort.Slice(ai.display, func(i, j int) bool {
		// sort on the bare token so "~web" and "web" order naturally
		return strings.TrimPrefix(ai.display[i], "~") < strings.TrimPrefix(ai.display[j], "~")
	})
	return ai
}

// AreaLint is the lint-facing surface summary of one task (df-lint-area-nudge):
// whether it carries an AUTHORED area: label, whether it names any surface at
// all, and the sorted display forms (a "~" prefix marks a phase-band-DERIVED
// provisional area). It exists so `bp task lint` reads the SAME surface
// derivation the frontier's interference model reads — no reimplementation of
// area: parsing. See docs/contracts/dispatch-areas.md for the vocabulary.
type AreaLint struct {
	Authored bool     // ≥1 authored area: label
	HasAny   bool     // any surface token at all (authored OR phase-band-derived)
	Display  []string // sorted display forms; "~studio" = phase-band-derived
}

// AreaLintOf resolves a task's lint-facing surface summary by delegating to the
// canonical areasOf, so the nudge can never drift from the frontier's model.
func AreaLintOf(t Task) AreaLint {
	ai := areasOf(t)
	return AreaLint{
		Authored: ai.authored,
		HasAny:   !ai.empty(),
		Display:  ai.display,
	}
}

// phaseBandSlug extracts the surface slug from a `phase:<n>-<slug>` label:
// "phase:2-studio" -> "studio", "phase:5-paper-components" -> "paper-components".
// A band with no numeric-dash prefix ("phase:goal") yields the whole tail,
// which simply won't match phaseBandArea.
func phaseBandSlug(label string) string {
	tail := strings.TrimSpace(strings.TrimPrefix(label, labelPhasePrefix))
	if i := strings.IndexByte(tail, '-'); i >= 0 {
		// only strip a leading numeric band ("2-studio"), not a hyphen inside
		// the slug ("paper-components")
		if isAllDigits(tail[:i]) {
			return tail[i+1:]
		}
	}
	return tail
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// areasOverlap reports whether two footprints share a surface token — the
// PRECISE interference test that enables intra-epic parallelism (two tasks in
// the same epic touching disjoint surfaces can run at once).
func areasOverlap(a, b areaInfo) bool {
	// iterate the smaller set
	small, large := a.bare, b.bare
	if len(large) < len(small) {
		small, large = large, small
	}
	for tok := range small {
		if large[tok] {
			return true
		}
	}
	return false
}

// neighborhoodKey is the conservative blast-radius key: the first `proj:`
// label (so `proj:loop`'s two roots MERGE into one radius — strictly more
// careful than D66's root-only key), else the task's `design_doc` paper, else
// its epic root. Namespaced so a proj/paper/root value can never collide.
// A nil DetailIndex (the board path) skips the design_doc tier — on the live
// corpus design_doc is 1:1 with root, so the key is unchanged.
func neighborhoodKey(t Task, byBare map[string]Task, details DetailIndex) string {
	for _, l := range t.Labels {
		if strings.HasPrefix(l, labelProjPrefix) {
			return "proj:" + strings.TrimPrefix(l, labelProjPrefix)
		}
	}
	if details != nil {
		if d, ok := details[t.DocID]; ok && d.DesignDoc != "" {
			return "doc:" + bareID(d.DesignDoc)
		}
	}
	return "root:" + rootOfBare(byBare, t.DocID)
}

// interfereTier is the interference verdict between two candidates.
type interfereTier int

const (
	tierNone    interfereTier = iota // provably independent (disjoint areas)
	tierUnknown                      // strangers, ≥1 area-less — independent BY ASSUMPTION
	tierHard                         // never dispatch both: same neighborhood or overlapping areas
)

// crossAdj is the symmetric adjacency built from FrontierOpts.CrossEdges: a
// bareID maps to the set of bareIDs it shares a real cross-root `blocks` edge
// with. Nil (no edges supplied) short-circuits every lookup to false, so the
// slice-1 path pays nothing.
type crossAdj map[string]map[string]bool

// buildCrossAdj symmetrises the pass-in edge map into a set-of-sets. A nil or
// empty input yields nil, which linked/has() treat as "no cross edges" — the
// regression-safe default.
func buildCrossAdj(edges map[string][]string) crossAdj {
	if len(edges) == 0 {
		return nil
	}
	adj := make(crossAdj, len(edges))
	link := func(a, b string) {
		if a == "" || b == "" || a == b {
			return
		}
		if adj[a] == nil {
			adj[a] = map[string]bool{}
		}
		adj[a][b] = true
	}
	for a, bs := range edges {
		for _, b := range bs {
			link(a, b)
			link(b, a) // interference is undirected
		}
	}
	if len(adj) == 0 {
		return nil
	}
	return adj
}

// has reports whether a and b are joined by a real cross-root block edge.
func (c crossAdj) has(a, b string) bool {
	if c == nil {
		return false
	}
	n, ok := c[a]
	return ok && n[b]
}

// interferes is the careful core (§3.1). It NEVER returns tierNone/tierUnknown
// for a pair that shares a HARD signal. Slice 2 (df-graph-crossdep) adds the
// cross-root block-edge consult FIRST: a real `blocks` dependency between two
// candidates (idA, idB are bareIDs) is the hardest signal — it overrides even
// the precise area-disjoint test that would otherwise clear two tasks with
// non-overlapping surfaces to run in parallel. With a nil/empty edge set the
// consult is a no-op and behavior is identical to slice 1.
func interferes(ai, bi areaInfo, nkA, nkB, idA, idB string, cross crossAdj) interfereTier {
	// A real cross-root block edge trumps everything below.
	if cross.has(idA, idB) {
		return tierHard
	}
	if !ai.empty() && !bi.empty() {
		// both self-declare a surface (authored or derived) — PRECISE test
		if areasOverlap(ai, bi) {
			return tierHard
		}
		return tierNone
	}
	// at least one is area-less — conservative neighborhood proxy
	if nkA == nkB {
		return tierHard
	}
	return tierUnknown
}

// admitted is the internal working record for one frontier pick, carrying the
// areaInfo the display Pick drops and the suppressed-sibling count the risk
// classification needs.
type admitted struct {
	pick       Pick
	ai         areaInfo
	suppressed int // same-neighborhood candidates this pick knocked out
}

// Frontier is the dispatch-frontier model: the maximal set of ready tasks that
// can run in parallel right now without their blast radii colliding. Both the
// TUI capacity count and `bp task frontier` read THIS function.
//
// Algorithm (§3.2): candidates are the ready tasks; each is scored with the
// D65 curation (one scorer, shared with resolveNext); the interference graph is
// built with §3.1; a greedy maximal-weight independent set walks the
// score-sorted candidates admitting one iff it does not HARD-interfere with any
// already-admitted pick. Greedy-by-score is deterministic, explains itself, and
// NEVER admits a conflicting pair (exact MWIS is NP-hard but the graph is tiny
// and near-disjoint).
//
// Determinism: candidates sort by (score desc, bareID asc); ties break on the
// stable doc-id, so the same snapshot always yields the same frontier.
func Frontier(s Snapshot, details DetailIndex, now []Task, nowT time.Time, opts FrontierOpts) []Pick {
	byID := make(map[string]Task, len(s.Tasks))
	for _, t := range s.Tasks {
		byID[t.DocID] = t
	}
	byBare := buildByBare(byID)
	evAt := buildEvAt(s.Events)
	resumables := computeResumables(s, byBare)
	contRoots := continuityRoots(byBare, now, resumables)
	// Slice-2 seam: the real cross-root block edges the caller fetched from the
	// graph API (nil on the board path → zero cost).
	cross := buildCrossAdj(opts.CrossEdges)

	// Candidates = the ready pool (the SAME set the old independentReady counted
	// roots over), refined by the interference model below.
	type cand struct {
		t      Task
		score  int
		reason string
		nk     string
		ai     areaInfo
	}
	var cands []cand
	for _, t := range s.Tasks {
		if t.Lifecycle != lifeReady {
			continue
		}
		sc, why := scoreReadyTask(t, contRoots, byBare, evAt, nowT)
		cands = append(cands, cand{
			t:      t,
			score:  sc,
			reason: why,
			nk:     neighborhoodKey(t, byBare, details),
			ai:     areasOf(t),
		})
	}
	sort.SliceStable(cands, func(i, j int) bool {
		if cands[i].score != cands[j].score {
			return cands[i].score > cands[j].score
		}
		return bareID(cands[i].t.DocID) < bareID(cands[j].t.DocID)
	})

	// Greedy MWIS: admit a candidate iff it HARD-interferes with no admitted
	// pick. A rejected candidate is recorded under the winner it collided with
	// (the blast-radius cost) and, if same-neighborhood, bumps the winner's
	// suppressed count (→ RiskNeighborhood).
	var picks []*admitted
	for _, c := range cands {
		cID := bareID(c.t.DocID)
		winner := -1
		for k := range picks {
			wID := bareID(picks[k].pick.Task.DocID)
			if interferes(c.ai, picks[k].ai, c.nk, picks[k].pick.NeighborhoodKey, cID, wID, cross) == tierHard {
				winner = k // first hard conflict owns the displacement
				break
			}
		}
		if winner >= 0 {
			w := picks[winner]
			wID := bareID(w.pick.Task.DocID)
			// The hard conflict is a cross-root block edge, an area overlap (both
			// self-declare a surface), or a same-neighborhood collision — in that
			// priority. A cross-edge conflict does NOT cap a neighborhood, so it
			// never bumps `suppressed`.
			var reason string
			switch {
			case cross.has(cID, wID):
				reason = "blocks edge " + wID
			case !c.ai.empty() && !w.ai.empty():
				reason = "shared surface " + areaOverlapLabel(c.ai, w.ai)
			default:
				reason = "same neighborhood " + c.nk
				w.suppressed++ // it capped its neighborhood to one pick
			}
			w.pick.Displaced = append(w.pick.Displaced, Displaced{
				DocID:  c.t.DocID,
				Title:  c.t.Title,
				Reason: reason,
			})
			continue
		}
		picks = append(picks, &admitted{
			pick: Pick{
				Task:            c.t,
				Score:           c.score,
				Reason:          c.reason,
				NeighborhoodKey: c.nk,
				Areas:           c.ai.display,
			},
			ai: c.ai,
		})
	}

	// Classify risk (§4) now that the admitted set is known.
	for _, a := range picks {
		classifyRisk(a)
	}

	// Assemble, honoring ProvenOnly (the safe set) then Max (a display cap).
	out := make([]Pick, 0, len(picks))
	for _, a := range picks {
		if opts.ProvenOnly && a.pick.Risk != RiskIsolated {
			continue
		}
		out = append(out, a.pick)
	}
	if opts.Max > 0 && len(out) > opts.Max {
		out = out[:opts.Max]
	}
	return out
}

// classifyRisk stamps one admitted pick with its risk class (§4). A broad epic
// (≥3 surfaces) is solo; an authored-area pick that survived admission is
// isolated (disjointness is guaranteed — an area overlap would have been HARD);
// an area-less pick that suppressed a sibling represents its neighborhood; a
// lone area-less stranger is unproven.
func classifyRisk(a *admitted) {
	switch {
	case len(a.ai.bare) >= 3:
		a.pick.Risk = RiskSharedSurface
		a.pick.Solo = true
	case a.ai.authored:
		a.pick.Risk = RiskIsolated
	case a.suppressed > 0:
		a.pick.Risk = RiskNeighborhood
	default:
		a.pick.Risk = RiskUnproven
	}
}

// GraphEdge is one block edge as fetched from GET /v1/graph/:id (slice-2),
// reduced to its two endpoints in bareID space. Direction is not carried:
// interference is undirected.
type GraphEdge struct {
	From string
	To   string
}

// ReadyRootSpan returns the distinct epic roots that own a READY task in the
// snapshot. It is the ZERO-FETCH guard for the slice-2 enrichment: a cross-ROOT
// block edge is impossible unless the ready set spans ≥2 roots, so the CLI
// fetches graph.show ONLY when len(ReadyRootSpan(s)) >= 2 — a single-root ready
// set makes zero graph.show calls. Roots are returned sorted for determinism.
func ReadyRootSpan(s Snapshot) []string {
	byBare := readySnapshotByBare(s)
	seen := map[string]bool{}
	var roots []string
	for _, t := range s.Tasks {
		if t.Lifecycle != lifeReady {
			continue
		}
		r := rootOfBare(byBare, t.DocID)
		if !seen[r] {
			seen[r] = true
			roots = append(roots, r)
		}
	}
	sort.Strings(roots)
	return roots
}

// CrossRootBlockEdges folds fetched block edges into the CrossEdges map the
// Frontier consults. It keeps ONLY edges whose BOTH endpoints are READY
// candidates AND live in DIFFERENT epic roots — a same-root edge is already
// merged by the neighborhood key, so it would add nothing (and an edge touching
// a non-ready task can never displace a candidate). Keyed by bareID → sorted
// bareIDs; the result is exactly what FrontierOpts.CrossEdges wants. Nil when no
// edge qualifies (⇒ slice-1 behavior).
func CrossRootBlockEdges(s Snapshot, edges []GraphEdge) map[string][]string {
	byBare := readySnapshotByBare(s)
	readyRoot := make(map[string]string) // ready bareID -> its root
	for _, t := range s.Tasks {
		if t.Lifecycle != lifeReady {
			continue
		}
		readyRoot[bareID(t.DocID)] = rootOfBare(byBare, t.DocID)
	}
	set := map[string]map[string]bool{}
	link := func(a, b string) {
		if set[a] == nil {
			set[a] = map[string]bool{}
		}
		set[a][b] = true
	}
	for _, e := range edges {
		a, b := bareID(e.From), bareID(e.To)
		ra, oka := readyRoot[a]
		rb, okb := readyRoot[b]
		if !oka || !okb { // both endpoints must be ready candidates
			continue
		}
		if ra == rb { // same root — already merged by the neighborhood key
			continue
		}
		link(a, b)
		link(b, a)
	}
	if len(set) == 0 {
		return nil
	}
	out := make(map[string][]string, len(set))
	for a, nbrs := range set {
		list := make([]string, 0, len(nbrs))
		for b := range nbrs {
			list = append(list, b)
		}
		sort.Strings(list)
		out[a] = list
	}
	return out
}

// readySnapshotByBare builds the bareID task index the root walk needs.
func readySnapshotByBare(s Snapshot) map[string]Task {
	byID := make(map[string]Task, len(s.Tasks))
	for _, t := range s.Tasks {
		byID[t.DocID] = t
	}
	return buildByBare(byID)
}

// areaOverlapLabel names the first shared surface for a displaced reason.
func areaOverlapLabel(a, b areaInfo) string {
	small, large := a.bare, b.bare
	if len(large) < len(small) {
		small, large = large, small
	}
	var toks []string
	for tok := range small {
		if large[tok] {
			toks = append(toks, tok)
		}
	}
	sort.Strings(toks)
	if len(toks) == 0 {
		return "area"
	}
	return "area:" + toks[0]
}
