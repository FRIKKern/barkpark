package cli

// tasks_lint_cmd.go — `bp task lint`: an advisory metadata NUDGE (df-lint-area-nudge,
// df-lint-files-nudge). It points at every WORKABLE LEAF task carrying no authored
// `area:` label — AND, separately, no authored `files:` label — the exact metadata
// gaps that starve the dispatch frontier's interference model (bp task frontier).
// The frontier proves two tasks can run in parallel by their `area:` surfaces and,
// more precisely, by their `files:` blast radius; a leaf with neither is admitted
// only as an UNPROVEN stranger, so tagging these leaves is what turns "independent
// by assumption" into "proven". `files:` is the file-truth bottleneck — coverage
// starts at 0%, so this nudge measures adoption (files_less) as it climbs.
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

// runTaskLint handles `bp task lint [<id>] [-o table|json|yaml]`. With an id it
// reports the canonical seven-field completeness read; without one it preserves
// the global area/files metadata nudge. Advisory: it returns
// exitOK whether or not it finds area-less tasks — the whole point is a nudge,
// never an error. Only an operational failure (fetch) yields a non-OK code.
func runTaskLint(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskLintHelp(out)
		return exitOK
	}
	if len(tail) > 1 {
		return usageErrf(out, func() { printTaskLintHelp(out) },
			"expected at most one task id")
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
		return fetchSnapshotErr(out, "lint", err)
	}
	if len(tail) == 1 {
		return renderCompletenessLint(out, snap, tail[0])
	}

	findings, readyLeaves := areaLintFindings(snap)
	filesFindings, _ := filesLintFindings(snap) // same ready-leaf pool; denominator matches

	if out.machineOut() {
		return emitLintJSON(out, findings, filesFindings, readyLeaves)
	}
	if code := renderAreaLintTable(out, findings, readyLeaves); code != exitOK {
		return code
	}
	return renderFilesLintTable(out, filesFindings, readyLeaves)
}

func renderCompletenessLint(out *writer, snap taskboard.Snapshot, id string) int {
	want := taskboard.BareID(id)
	for _, t := range snap.Tasks {
		if taskboard.BareID(t.DocID) != want {
			continue
		}
		c := t.Completeness
		if out.machineOut() {
			payload := map[string]any{
				"ok": true, "advisory": true, "id": want, "title": t.Title,
				"score": c.Score, "total": c.Total, "gaps": c.Gaps,
			}
			if out.output == "yaml" {
				out.renderYAML(payload)
			} else {
				out.renderJSON(payload)
			}
			return exitOK
		}
		out.outf("COMPLETENESS · %s · %d/%d", want, c.Score, c.Total)
		if len(c.Gaps) == 0 {
			out.outf("gaps: none")
		} else {
			out.outf("gaps: %s", strings.Join(c.Gaps, ", "))
		}
		return exitOK
	}
	out.userErr("lint: task %q not found", id)
	return exitGeneric
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

// filesLintFinding is one files-nudge row: a ready LEAF task carrying no authored
// `files:` label. There is no per-row suggestion — the syntax hint (files:<path>)
// is shown once in the table footer — because we cannot infer which files a task
// will touch without a human authoring them.
type filesLintFinding struct {
	ID    string
	Title string
}

// hasFilesLabel reports whether a task carries at least one authored `files:`
// label. Presence-only, by design: lint needs to know a task DECLARED a blast
// radius, not to parse it — so it does a local strings.HasPrefix scan rather than
// importing taskboard.FilesOf (the frontier's file-set parser), which may not be
// merged yet and would couple this nudge to that slice's landing.
func hasFilesLabel(t taskboard.Task) bool {
	for _, l := range t.Labels {
		if strings.HasPrefix(l, "files:") {
			return true
		}
	}
	return false
}

// filesLintFindings scans a snapshot for WORKABLE LEAVES carrying no authored
// `files:` label — the file-truth adoption gap — and returns them id-sorted plus
// the count of ready leaves scanned. The leaf/ready/parent classification is the
// SAME as areaLintFindings: workable = ready, leaf = no task names it as parent,
// so both nudges denominate against the identical pool.
func filesLintFindings(s taskboard.Snapshot) (findings []filesLintFinding, readyLeaves int) {
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
			continue // a goal/epic — a files: label on a container says nothing
		}
		readyLeaves++
		if hasFilesLabel(t) {
			continue // already declares a blast radius — nothing to nudge
		}
		findings = append(findings, filesLintFinding{
			ID:    taskboard.BareID(t.DocID),
			Title: t.Title,
		})
	}
	sort.SliceStable(findings, func(i, j int) bool { return findings[i].ID < findings[j].ID })
	return findings, readyLeaves
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

// renderFilesLintTable prints the files: adoption nudge: every ready leaf missing
// an authored files: label. Always exitOK — a nudge, never a gate.
func renderFilesLintTable(out *writer, findings []filesLintFinding, readyLeaves int) int {
	out.outf("LINT · %d of %d ready leaves carry no files: label  (advisory — a nudge, never a gate)",
		len(findings), readyLeaves)

	if len(findings) == 0 {
		out.outf("(every workable leaf declares a files: blast radius — the frontier can prove overlap exactly)")
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
		out.outf("· %-*s  %s", idW, f.ID, title)
	}
	out.outf("")
	out.outf("Add `files:<repo-relative-path>` (one path per label; trailing / for a")
	out.outf("directory) so `bp task frontier` can PROVE these run in parallel by their")
	out.outf("file blast radius instead of admitting them as unproven strangers.")
	return exitOK
}

// areaLintFindingJSON is the machine-readable shape of one nudge row.
// suggested_area is "" when no phase-band hint is available.
type areaLintFindingJSON struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Suggested string `json:"suggested_area"`
}

// filesLintFindingJSON is the machine-readable shape of one files-nudge row.
type filesLintFindingJSON struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

// emitLintJSON renders BOTH nudges in one payload: area_less / files_less counts
// beside their finding rows, so an adoption dashboard can track file-truth
// coverage (files_less → 0) as it climbs. Always exitOK — advisory.
func emitLintJSON(out *writer, area []areaLintFinding, files []filesLintFinding, readyLeaves int) int {
	areaRows := make([]areaLintFindingJSON, 0, len(area))
	for _, f := range area {
		areaRows = append(areaRows, areaLintFindingJSON{ID: f.ID, Title: f.Title, Suggested: f.Suggested})
	}
	filesRows := make([]filesLintFindingJSON, 0, len(files))
	for _, f := range files {
		filesRows = append(filesRows, filesLintFindingJSON{ID: f.ID, Title: f.Title})
	}
	payload := map[string]any{
		"ok":             true,
		"advisory":       true, // findings never make this a failure
		"ready_leaves":   readyLeaves,
		"area_less":      len(area),
		"files_less":     len(files),
		"findings":       areaRows,  // area nudge (backward-compatible key)
		"files_findings": filesRows, // files nudge
	}
	if out.output == "yaml" {
		out.renderYAML(payload)
	} else {
		out.renderJSON(payload)
	}
	return exitOK
}

func printTaskLintHelp(out *writer) {
	out.outf("usage: bp task lint [<id>] [-o table|json|yaml]")
	out.outf("")
	out.outf("With <id>, reports the task's 0-7 authoring completeness score and named")
	out.outf("gaps: title, description, criteria, placement, priority, deps, paper.")
	out.outf("")
	out.outf("Advisory metadata NUDGE: every workable LEAF task (ready, no children)")
	out.outf("that carries NO authored area: label — and, separately, no files: label.")
	out.outf("The dispatch frontier (bp task frontier) proves two tasks run in parallel")
	out.outf("by their area: surfaces and, more precisely, their files: blast radius; a")
	out.outf("leaf with neither is dispatched only as an UNPROVEN stranger. This verb")
	out.outf("points at exactly those gaps so a human can tag them.")
	out.outf("")
	out.outf("It is a NUDGE, not a gate: it exits 0 even when it finds untagged tasks.")
	out.outf("Goals/epics (tasks that carry children) are excluded — a label on a")
	out.outf("container says nothing about where its children touch code. When a task's")
	out.outf("phase: bands already name a surface, that derived hint is SUGGESTED (\"~studio\").")
	out.outf("For files:, add one path per label (files:internal/cli/foo.go), trailing /")
	out.outf("for a directory.")
	out.outf("")
	out.outf("flags:")
	out.outf("  -o json|yaml    machine-readable findings; counts area_less + files_less")
	out.outf("")
	out.outf("See also: docs/contracts/dispatch-areas.md (the area: vocabulary),")
	out.outf("`bp task frontier` (the interference model this metadata feeds).")
}
