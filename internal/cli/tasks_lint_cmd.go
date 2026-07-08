package cli

// tasks_lint_cmd.go — `bp task lint`: an advisory metadata NUDGE (df-lint-area-nudge).
// It points at every WORKABLE LEAF task carrying no authored `area:` label — the
// exact metadata gap that starves the dispatch frontier's interference model
// (bp task frontier). The frontier proves two tasks can run in parallel by their
// `area:` surfaces; a leaf with none is admitted only as an UNPROVEN stranger, so
// tagging these leaves is what turns "independent by assumption" into "proven".
//
// It is a NUDGE, not a gate: it ALWAYS returns exitOK, even when it finds
// untagged tasks. A CLI built-in intercepted before manifest dispatch (the
// manifest `task` noun carries no `lint` verb), reading the SAME taskboard
// snapshot the board and `bp task frontier` read (FetchSnapshotFull) and reusing
// the same area derivation (taskboard.AreaLintOf), so it can never drift.

import (
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// areaLintFinding is one nudge row: a ready LEAF task with no authored `area:`
// label. Suggested is a phase-band-DERIVED surface hint ("studio") when the
// task's bands already name a known surface, else "" (nothing to infer).
type areaLintFinding struct {
	ID        string
	Title     string
	Suggested string
}

// runTaskLint handles `bp task lint [-o table|json|yaml]`. Advisory: it returns
// exitOK whether or not it finds area-less tasks — the whole point is a nudge,
// never an error. Only an operational failure (fetch) yields a non-OK code.
func runTaskLint(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskLintHelp(out)
		return exitOK
	}
	if len(tail) > 0 {
		return usageErrf(out, func() { printTaskLintHelp(out) },
			"unknown flag %q (lint accepts only -o table|json|yaml)", tail[0])
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts", // tasks live as drafts; the board reads the same view
	})

	snap, _, err := taskboard.FetchSnapshotFull(client)
	if err != nil {
		out.userErr("lint: %v", err)
		return exitGeneric
	}

	findings, readyLeaves := areaLintFindings(snap)

	if out.machineOut() {
		return emitAreaLintJSON(out, findings, readyLeaves)
	}
	return renderAreaLintTable(out, findings, readyLeaves)
}

// areaLintFindings scans a snapshot for WORKABLE LEAVES carrying no authored
// `area:` label — the nudge targets — and returns them id-sorted plus the count
// of ready leaves scanned (the summary denominator).
//
//   - workable = ready (t.Lifecycle == "ready"): the SAME pool Frontier's
//     candidate loop admits.
//   - leaf = no other task names it as a parent. Goals/epics carry children and
//     are EXCLUDED: an area label on a container says nothing about where its
//     children touch code.
//   - area-less = no AUTHORED area: label. A phase-band-derived "~" hint does
//     NOT count as authored — it becomes the suggestion instead.
func areaLintFindings(s taskboard.Snapshot) (findings []areaLintFinding, readyLeaves int) {
	// A task is a parent iff some other task points its ParentID at it (bareID-
	// normalized, so a drafts.* id joins a bare parent slug — the same join
	// buildByBare uses on the board side).
	parent := map[string]bool{}
	for _, t := range s.Tasks {
		if t.ParentID == "" {
			continue
		}
		parent[taskboard.BareID(t.ParentID)] = true
	}

	for _, t := range s.Tasks {
		if t.Lifecycle != "ready" {
			continue // not workable right now
		}
		if parent[taskboard.BareID(t.DocID)] {
			continue // a goal/epic — carries children, not a workable leaf
		}
		readyLeaves++
		al := taskboard.AreaLintOf(t)
		if al.Authored {
			continue // already carries an authored area: label — nothing to nudge
		}
		findings = append(findings, areaLintFinding{
			ID:        taskboard.BareID(t.DocID),
			Title:     t.Title,
			Suggested: suggestArea(al),
		})
	}
	sort.SliceStable(findings, func(i, j int) bool { return findings[i].ID < findings[j].ID })
	return findings, readyLeaves
}

// suggestArea returns a phase-band-derived surface hint (stripped of the "~"
// provisional marker) when the task's bands name a known surface, else "".
// Because the task carries no authored area, every display token is derived.
func suggestArea(al taskboard.AreaLint) string {
	if len(al.Display) == 0 {
		return ""
	}
	return strings.TrimPrefix(al.Display[0], "~")
}

func renderAreaLintTable(out *writer, findings []areaLintFinding, readyLeaves int) int {
	out.outf("LINT · %d of %d ready leaves carry no area: label  (advisory — a nudge, never a gate)",
		len(findings), readyLeaves)

	if len(findings) == 0 {
		out.outf("(every workable leaf is area-tagged — the frontier can model interference fully)")
		return exitOK
	}

	idW := 0
	for _, f := range findings {
		if len(f.ID) > idW {
			idW = len(f.ID)
		}
	}
	const titleCap = 48
	for _, f := range findings {
		title := f.Title
		if len(title) > titleCap {
			title = title[:titleCap-1] + "…"
		}
		hint := "—"
		if f.Suggested != "" {
			hint = "~" + f.Suggested + " ?" // derived guess, still needs a human's yes
		}
		out.outf("· %-*s  %-*s  suggest: %s", idW, f.ID, titleCap, title, hint)
	}
	out.outf("")
	out.outf("Add `area:<surface>` (see docs/contracts/dispatch-areas.md) so `bp task")
	out.outf("frontier` can PROVE these run in parallel instead of dispatching them blind.")
	return exitOK
}

// areaLintFindingJSON is the machine-readable shape of one nudge row.
// suggested_area is "" when no phase-band hint is available.
type areaLintFindingJSON struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Suggested string `json:"suggested_area"`
}

func emitAreaLintJSON(out *writer, findings []areaLintFinding, readyLeaves int) int {
	rows := make([]areaLintFindingJSON, 0, len(findings))
	for _, f := range findings {
		rows = append(rows, areaLintFindingJSON{ID: f.ID, Title: f.Title, Suggested: f.Suggested})
	}
	payload := map[string]any{
		"ok":           true,
		"advisory":     true, // findings never make this a failure
		"ready_leaves": readyLeaves,
		"area_less":    len(findings),
		"findings":     rows,
	}
	if out.output == "yaml" {
		out.renderYAML(payload)
	} else {
		out.renderJSON(payload)
	}
	return exitOK
}

func printTaskLintHelp(out *writer) {
	out.outf("usage: bp task lint [-o table|json|yaml]")
	out.outf("")
	out.outf("Advisory metadata NUDGE: every workable LEAF task (ready, no children)")
	out.outf("that carries NO authored area: label. The dispatch frontier (bp task")
	out.outf("frontier) proves two tasks run in parallel by their area: surfaces; a leaf")
	out.outf("with none is dispatched only as an UNPROVEN stranger. This verb points at")
	out.outf("exactly those gaps so a human can tag them.")
	out.outf("")
	out.outf("It is a NUDGE, not a gate: it exits 0 even when it finds untagged tasks.")
	out.outf("Goals/epics (tasks that carry children) are excluded — an area label on a")
	out.outf("container says nothing about where its children touch code. When a task's")
	out.outf("phase: bands already name a surface, that derived hint is SUGGESTED (\"~studio\").")
	out.outf("")
	out.outf("flags:")
	out.outf("  -o json|yaml    machine-readable findings (id, title, suggested_area)")
	out.outf("")
	out.outf("See also: docs/contracts/dispatch-areas.md (the area: vocabulary),")
	out.outf("`bp task frontier` (the interference model this metadata feeds).")
}
