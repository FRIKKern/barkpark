package cli

// tasks_frontier_cmd.go — `bp task frontier`: the dispatch surface (task-TUI
// epic, wave 13). It prints the maximal set of ready tasks that can run in
// parallel RIGHT NOW without their blast radii colliding — the honest answer to
// the wish's "how many agents can we send out". It is a CLI built-in
// intercepted before manifest dispatch (the manifest `task` noun has no
// `frontier` verb), reading the SAME taskboard.Frontier model the TUI's
// "NEXT · N independent" count reads, so the two surfaces never drift.
//
// No server change: it fetches the one /v1/tasks snapshot the board already
// makes (FetchSnapshotFull) and computes the frontier client-side.

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// runTaskFrontier handles `bp task frontier [--max N] [--proven-only]`. Output
// shape (table default, json/yaml via -o) follows the resolved writer.
func runTaskFrontier(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskFrontierHelp(out)
		return exitOK
	}

	opts, err := parseFrontierFlags(tail)
	if err != nil {
		return usageErrf(out, func() { printTaskFrontierHelp(out) }, "%v", err)
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts", // tasks live as drafts; the board reads the same view
	})

	snap, details, err := taskboard.FetchSnapshotFull(client)
	if err != nil {
		return fetchSnapshotErr(out, "frontier", err)
	}

	now := time.Now().UTC()
	// board.Now is the live in_progress claim set — the continuity anchor the
	// D65 scorer boosts against. Reuse the board's derivation rather than
	// re-deriving "what is running" here.
	board := taskboard.BuildBoard(snap, taskboard.RepoContext{}, now)

	// Slice-2 (df-graph-crossdep): enrich the frontier with REAL cross-root
	// block edges fetched from the graph API — OUTSIDE the pure Frontier model.
	// The fetch is guarded (zero graph.show calls unless the ready set spans ≥2
	// roots) and best-effort (a fetch error just leaves the frontier at its
	// slice-1 precision).
	opts.CrossEdges = fetchCrossEdges(client, snap)

	picks := taskboard.Frontier(snap, details, board.Now, now, opts)

	// The honest capacity is the FULL frontier (unbounded, all classes) on the
	// SAME enriched edge set — regardless of a --max display cap or a
	// --proven-only filter. With no cross edges this equals board.IndependentReady.
	full := taskboard.Frontier(snap, details, board.Now, now, taskboard.FrontierOpts{CrossEdges: opts.CrossEdges})
	capacity := len(full)
	proven, unproven := frontierTally(full)

	// The claimed-collision report (df-file-edge): of the tasks ALREADY in flight,
	// which two share a declared surface? Surfaced HERE, not at merge time.
	overlaps := taskboard.ClaimOverlaps(board.Now)

	if out.machineOut() {
		return emitFrontierJSON(out, picks, capacity, proven, unproven, overlaps)
	}
	rc := renderFrontierTable(out, picks, capacity, proven, unproven, opts)
	renderOverlaps(out, overlaps)
	return rc
}

// parseFrontierFlags reads the command-local flags out of tail: --max N (cap
// the emitted picks) and --proven-only (the maximally-careful safe set).
func parseFrontierFlags(tail []string) (taskboard.FrontierOpts, error) {
	var opts taskboard.FrontierOpts
	for i := 0; i < len(tail); i++ {
		a := tail[i]
		switch {
		case a == "--proven-only":
			opts.ProvenOnly = true
		case a == "--max" || strings.HasPrefix(a, "--max="):
			var val string
			if strings.HasPrefix(a, "--max=") {
				val = strings.TrimPrefix(a, "--max=")
			} else {
				if i+1 >= len(tail) {
					return opts, fmt.Errorf("flag --max needs a value")
				}
				val = tail[i+1]
				i++
			}
			n, err := strconv.Atoi(val)
			if err != nil || n < 0 {
				return opts, fmt.Errorf("invalid --max %q (want a non-negative integer)", val)
			}
			opts.Max = n
		default:
			return opts, fmt.Errorf("unknown flag %q (frontier accepts --max N, --proven-only)", a)
		}
	}
	return opts, nil
}

// graphShower is the one method fetchCrossEdges needs — an interface so the
// zero-fetch guard is unit-testable with a call-counting fake (no network).
// *apiclient.Client satisfies it.
type graphShower interface {
	GraphShow(id string) (*apiclient.GraphResult, error)
}

// Bounds for the cross-edge fan-out (charter D12). GET /v1/graph/:root can be
// pathologically slow live (~10s/call), and a board can span dozens of ready
// roots — an unbounded sequential fan-out stalled the CLI for minutes. The
// enrichment therefore runs on a small concurrent worker pool under ONE total
// wall-clock deadline; whatever arrived by the deadline is used, the rest is
// dropped. Fewer cross edges only costs cross-root PRECISION (the frontier
// keeps its slice-1 proxies), never correctness.
const (
	crossEdgeWorkers  = 8
	crossEdgeDeadline = 4 * time.Second
)

// fetchCrossEdges enriches the dispatch frontier with REAL cross-root `blocks`
// edges (df-graph-crossdep). The ZERO-FETCH GUARD: it makes NO GraphShow calls
// unless the ready set spans ≥2 roots — a single-root ready set can carry no
// cross-ROOT dependency, so there is nothing to fetch. When it does fetch, it
// pulls graph.show once per candidate root (bounded pool + total deadline, see
// fetchCrossEdgesBounded), keeps the `blocks` edges (resolving each endpoint
// from node-id space into doc_id space), and folds them into the
// FrontierOpts.CrossEdges shape via taskboard.CrossRootBlockEdges (which drops
// same-root and non-candidate edges). Best-effort: a per-root fetch error is
// skipped, never fatal — the frontier simply keeps its slice-1 precision.
func fetchCrossEdges(gs graphShower, snap taskboard.Snapshot) map[string][]string {
	return fetchCrossEdgesBounded(gs, snap, crossEdgeWorkers, crossEdgeDeadline)
}

// fetchCrossEdgesBounded is fetchCrossEdges with the pool width and the TOTAL
// wall-clock deadline injectable (tests use a short deadline against a blocking
// fake). On deadline it returns the edges collected so far — never an error,
// never a hang. A worker still stuck inside a hung GraphShow when the deadline
// fires is abandoned; its eventual send lands in the buffered results channel
// (capacity = all roots), so no goroutine ever blocks forever on a send.
func fetchCrossEdgesBounded(gs graphShower, snap taskboard.Snapshot, workers int, deadline time.Duration) map[string][]string {
	roots := taskboard.ReadyRootSpan(snap)
	if len(roots) < 2 {
		return nil // no cross-root dependency possible → zero graph.show calls
	}

	jobs := make(chan string, len(roots))
	for _, root := range roots {
		jobs <- root
	}
	close(jobs)
	results := make(chan *apiclient.GraphResult, len(roots))
	if workers > len(roots) {
		workers = len(roots)
	}
	if workers < 1 {
		workers = 1
	}
	for i := 0; i < workers; i++ {
		go func() {
			for root := range jobs {
				res, err := gs.GraphShow(root)
				if err != nil {
					res = nil // best-effort — a missing root just under-enriches
				}
				results <- res
			}
		}()
	}

	timer := time.NewTimer(deadline)
	defer timer.Stop()
	var edges []taskboard.GraphEdge
	for done := 0; done < len(roots); {
		select {
		case res := <-results:
			done++
			edges = append(edges, blockEdgesOf(res)...)
		case <-timer.C:
			// Total deadline hit: fold what arrived, drop the rest.
			return taskboard.CrossRootBlockEdges(snap, edges)
		}
	}
	return taskboard.CrossRootBlockEdges(snap, edges)
}

// blockEdgesOf extracts one graph result's `blocks` edges, resolving each
// endpoint from node-id space into doc_id space. Nil-safe (a failed fetch
// contributes nothing).
func blockEdgesOf(res *apiclient.GraphResult) []taskboard.GraphEdge {
	if res == nil {
		return nil
	}
	id2doc := make(map[string]string, len(res.Nodes))
	for _, n := range res.Nodes {
		id2doc[n.ID] = n.DocID
	}
	var edges []taskboard.GraphEdge
	for _, e := range res.Edges {
		if e.Kind != "blocks" {
			continue
		}
		from, to := e.FromID, e.ToID
		if d := id2doc[from]; d != "" {
			from = d
		}
		if d := id2doc[to]; d != "" {
			to = d
		}
		edges = append(edges, taskboard.GraphEdge{From: from, To: to})
	}
	return edges
}

// frontierTally counts proven (isolated) vs the metadata-thin remainder across
// a full frontier — the footer's honesty line.
func frontierTally(picks []taskboard.Pick) (proven, unproven int) {
	for _, p := range picks {
		if p.Proven() {
			proven++
		} else {
			unproven++
		}
	}
	return proven, unproven
}

// riskTag renders a compact risk label for the table's [risk] column.
func riskTag(p taskboard.Pick) string {
	switch p.Risk {
	case taskboard.RiskFileIsolated:
		return "file-iso"
	case taskboard.RiskIsolated:
		return "isolated"
	case taskboard.RiskNeighborhood:
		return "nbhd"
	case taskboard.RiskSharedSurface:
		return "SOLO"
	default:
		return "unproven"
	}
}

// areaText renders a pick's surface footprint (a "~" already marks a derived
// area); an em dash for none.
func areaText(p taskboard.Pick) string {
	if len(p.Areas) == 0 {
		return "—"
	}
	return strings.Join(p.Areas, ",")
}

// reasonText composes the human reason cell: the priority band + the dominant
// D65 reason ("P0 · continues airdrop"), falling back to the bare band.
func reasonText(p taskboard.Pick) string {
	band := "P" + strings.TrimPrefix(strings.TrimPrefix(p.Task.Priority, "P"), "p")
	if strings.TrimSpace(p.Task.Priority) == "" {
		band = "P?"
	}
	if p.Reason != "" {
		return band + " · " + p.Reason
	}
	return band
}

func renderFrontierTable(out *writer, picks []taskboard.Pick, capacity, proven, unproven int, opts taskboard.FrontierOpts) int {
	// Header line: the honest capacity + proven/unproven tally.
	hint := "  (--proven-only for the safe set)"
	if opts.ProvenOnly {
		hint = "  (--proven-only: the safe set)"
	}
	out.outf("FRONTIER · %d independent · %d proven · %d unproven%s",
		capacity, proven, unproven, hint)

	if len(picks) == 0 {
		out.outf("(no ready tasks — nothing to dispatch)")
		return exitOK
	}

	// Column widths on the bare strings so alignment survives.
	idW, titleW := 0, 0
	const titleCap = 44
	for _, p := range picks {
		id := taskboard.BareID(p.Task.DocID)
		if len(id) > idW {
			idW = len(id)
		}
		tl := len(p.Task.Title)
		if tl > titleCap {
			tl = titleCap
		}
		if tl > titleW {
			titleW = tl
		}
	}
	for _, p := range picks {
		id := taskboard.BareID(p.Task.DocID)
		title := p.Task.Title
		if len(title) > titleCap {
			title = title[:titleCap-1] + "…"
		}
		solo := ""
		if p.Solo {
			solo = " ⚑solo"
		}
		out.outf("○ %-*s  %-*s  %4d  %-22s  [%-8s] %s%s",
			idW, id,
			titleW, title,
			p.Score,
			reasonText(p),
			riskTag(p),
			areaText(p),
			solo,
		)
		// One indented line per displaced candidate — the blast-radius cost.
		for _, d := range p.Displaced {
			dt := d.Title
			if len(dt) > titleCap {
				dt = dt[:titleCap-1] + "…"
			}
			out.outf("    ↳ displaces %-*s  %s (%s)", idW, taskboard.BareID(d.DocID), dt, d.Reason)
		}
	}
	return exitOK
}

// renderOverlaps prints the OVERLAP section: the in_progress claims whose
// declared blast radii already collide (df-file-edge). Silent when none — a
// clean claim set prints nothing, so the section only ever signals real trouble.
func renderOverlaps(out *writer, overlaps []taskboard.OverlapPair) {
	if len(overlaps) == 0 {
		return
	}
	out.outf("")
	out.outf("OVERLAP · %d claimed pair(s) share a surface — resolve before merge:", len(overlaps))
	for _, o := range overlaps {
		aw := o.AWorker
		if aw == "" {
			aw = "?"
		}
		bw := o.BWorker
		if bw == "" {
			bw = "?"
		}
		out.outf("  ⚠ %s (%s) ⋈ %s (%s) — %s %s", o.AID, aw, o.BID, bw, o.Kind, o.Shared)
	}
}

// frontierOverlapJSON is the machine-readable shape of one claimed collision.
type frontierOverlapJSON struct {
	A       string `json:"a"`
	B       string `json:"b"`
	AWorker string `json:"a_worker"`
	BWorker string `json:"b_worker"`
	Kind    string `json:"kind"`
	Shared  string `json:"shared"`
}

// frontierPickJSON is the machine-readable shape of one pick. conflicts_with is
// the blast-radius cost (the candidates this pick displaced).
type frontierPickJSON struct {
	ID              string             `json:"id"`
	Title           string             `json:"title"`
	Score           int                `json:"score"`
	Reason          string             `json:"reason"`
	Priority        string             `json:"priority"`
	NeighborhoodKey string             `json:"neighborhood_key"`
	Areas           []string           `json:"areas"`
	Risk            string             `json:"risk"`
	Solo            bool               `json:"solo"`
	Proven          bool               `json:"proven"`
	ConflictsWith   []frontierConflict `json:"conflicts_with"`
}

type frontierConflict struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Reason string `json:"reason"`
}

func emitFrontierJSON(out *writer, picks []taskboard.Pick, capacity, proven, unproven int, overlaps []taskboard.OverlapPair) int {
	rows := make([]frontierPickJSON, 0, len(picks))
	for _, p := range picks {
		conf := make([]frontierConflict, 0, len(p.Displaced))
		for _, d := range p.Displaced {
			conf = append(conf, frontierConflict{
				ID:     taskboard.BareID(d.DocID),
				Title:  d.Title,
				Reason: d.Reason,
			})
		}
		// Stable order for deterministic output.
		sort.SliceStable(conf, func(i, j int) bool { return conf[i].ID < conf[j].ID })
		areas := append([]string(nil), p.Areas...)
		if areas == nil {
			areas = []string{}
		}
		rows = append(rows, frontierPickJSON{
			ID:              taskboard.BareID(p.Task.DocID),
			Title:           p.Task.Title,
			Score:           p.Score,
			Reason:          p.Reason,
			Priority:        p.Task.Priority,
			NeighborhoodKey: p.NeighborhoodKey,
			Areas:           areas,
			Risk:            string(p.Risk),
			Solo:            p.Solo,
			Proven:          p.Proven(),
			ConflictsWith:   conf,
		})
	}
	orows := make([]frontierOverlapJSON, 0, len(overlaps))
	for _, o := range overlaps {
		orows = append(orows, frontierOverlapJSON{
			A:       o.AID,
			B:       o.BID,
			AWorker: o.AWorker,
			BWorker: o.BWorker,
			Kind:    o.Kind,
			Shared:  o.Shared,
		})
	}
	payload := map[string]any{
		"ok":          true,
		"independent": capacity,
		"proven":      proven,
		"unproven":    unproven,
		"picks":       rows,
		"overlaps":    orows,
	}
	if out.output == "yaml" {
		out.renderYAML(payload)
	} else {
		out.renderJSON(payload)
	}
	return exitOK
}

func printTaskFrontierHelp(out *writer) {
	out.outf("usage: bp task frontier [--max N] [--proven-only] [-o table|json|yaml]")
	out.outf("")
	out.outf("The dispatch frontier: the maximal set of ready tasks that can run in")
	out.outf("parallel right now WITHOUT their blast radii colliding — the honest answer")
	out.outf("to \"how many agents can we send out\". Two tasks interfere when they share a")
	out.outf("code surface (area: labels), a project/paper/epic neighborhood, or a")
	out.outf("dependency; the frontier admits at most one from each conflicting group.")
	out.outf("")
	out.outf("Every pick carries a dominant reason, its neighborhood key, its area set")
	out.outf("(a \"~\" marks a surface DERIVED from a phase band, not authored), and a risk")
	out.outf("class: file-iso (files: blast radius declared and path-disjoint — the")
	out.outf("strongest proof), isolated (area-proven disjoint), nbhd (sole rep of its")
	out.outf("epic), unproven (a metadata-thin stranger, independent by assumption), or")
	out.outf("SOLO (a broad epic that should run alone).")
	out.outf("")
	out.outf("An OVERLAP section follows when two ALREADY-CLAIMED tasks share a declared")
	out.outf("surface — a collision to resolve before merge, not discover at merge time.")
	out.outf("")
	out.outf("flags:")
	out.outf("  --max N         cap the emitted picks (0 / omitted = the full capacity)")
	out.outf("  --proven-only   the maximally-careful set: only area-proven isolated picks")
	out.outf("  -o json|yaml    machine-readable picks (id, score, reason, conflicts_with[])")
	out.outf("")
	out.outf("See also: `bp tasks` (the live board), `bp task next` (claim one).")
}
