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
		out.userErr("frontier: %v", err)
		return exitGeneric
	}

	now := time.Now().UTC()
	// board.Now is the live in_progress claim set — the continuity anchor the
	// D65 scorer boosts against. Reuse the board's derivation rather than
	// re-deriving "what is running" here.
	board := taskboard.BuildBoard(snap, taskboard.RepoContext{}, now)
	picks := taskboard.Frontier(snap, details, board.Now, now, opts)

	// The honest capacity is the FULL frontier (unbounded, all classes) — the
	// same number the TUI prints — regardless of a --max display cap or a
	// --proven-only filter. Compute it once for the summary line.
	capacity := board.IndependentReady
	proven, unproven := frontierTally(taskboard.Frontier(snap, details, board.Now, now, taskboard.FrontierOpts{}))

	if out.machineOut() {
		return emitFrontierJSON(out, picks, capacity, proven, unproven)
	}
	return renderFrontierTable(out, picks, capacity, proven, unproven, opts)
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

func emitFrontierJSON(out *writer, picks []taskboard.Pick, capacity, proven, unproven int) int {
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
	payload := map[string]any{
		"ok":          true,
		"independent": capacity,
		"proven":      proven,
		"unproven":    unproven,
		"picks":       rows,
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
	out.outf("class: isolated (area-proven disjoint), nbhd (sole rep of its epic),")
	out.outf("unproven (a metadata-thin stranger, independent by assumption), or SOLO (a")
	out.outf("broad epic that should run alone).")
	out.outf("")
	out.outf("flags:")
	out.outf("  --max N         cap the emitted picks (0 / omitted = the full capacity)")
	out.outf("  --proven-only   the maximally-careful set: only area-proven isolated picks")
	out.outf("  -o json|yaml    machine-readable picks (id, score, reason, conflicts_with[])")
	out.outf("")
	out.outf("See also: `bp tasks` (the live board), `bp task next` (claim one).")
}
