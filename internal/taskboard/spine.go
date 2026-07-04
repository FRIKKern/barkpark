package taskboard

import (
	"regexp"
	"strings"
)

// spine.go — the ONE ordered spine producer (charter D42). Both the shell's
// visibleRows (the cursor index space) and the renderer's flattenSpine (the
// painted lines) consume spineRows, so cursor-parity is STRUCTURAL: they can no
// longer drift because they read the SAME ordered list. spineRows covers only
// the SCROLLING spine (epics → clusters → the loose bucket); the pinned band
// (NOW cards / READY head) owns the first cursor indices and is produced by
// render.go's renderNowBand, exactly as before. A header/more-line/separator/
// phase-band is Selectable:false — the display-only set whose count the cursor
// never touches — so nested subtasks and phase bands add depth without shifting
// the index space (the parity guards hold trivially on the phase-less fixtures).

// spineKind discriminates a spine row for the renderer.
type spineKind int

const (
	spineSep          spineKind = iota // blank separator (display-only)
	spineEpicHeader                    // authored-epic section header (selectable)
	spineClusterHeader                 // derived-cluster section header (selectable)
	spineOrphanHeader                  // the loose "(no epic)" header (selectable)
	spineTask                          // a task row — epic child / cluster member / orphan (selectable)
	spineMore                          // "+K more" / "+N done" fold line (display-only)
	spinePhaseBand                     // a phase sub-band label (display-only)
	spineEmpty                         // the syncing / all-clear fallback (display-only)
)

// spineHeader carries a section (or phase-band) header's render inputs.
type spineHeader struct {
	title   string
	code    string
	derived bool
	counts  sectionCounts
}

// SpineRow is one ordered spine element. Kind + Depth + Ref + Selectable are the
// D42 contract; the unexported payloads carry what the renderer needs so it
// re-resolves nothing.
type SpineRow struct {
	Kind       spineKind
	Depth      int
	Ref        string // task doc id, or a header fold key
	Selectable bool
	RK         rowKind // the shell rowKind for a selectable row

	task Task          // spineTask
	hdr  spineHeader   // *Header / spinePhaseBand
	more spineMoreInfo // spineMore
	text string        // spineEmpty
}

type spineMoreInfo struct{ hidden, done int }

// spineRows is the whole spine order+fold rule in one place (charter D42). It
// mirrors the pre-refactor flattenSpine/visibleRows structure exactly for a flat
// section (so the cursor-parity guards hold unweakened) and adds nesting + phase
// bands as additive, display-only structure.
func spineRows(b Board, st UIState) []SpineRow {
	var rows []SpineRow
	emitted := false
	sep := func() {
		if emitted {
			rows = append(rows, SpineRow{Kind: spineSep})
		}
	}

	// Each section: header (selectable), then its nested+capped children with
	// optional phase sub-bands, then the "+K more"/"+N done" fold line.
	section := func(rk spineKind, shellRK rowKind, foldKey, title, code string, derived bool,
		tasks []Task, shown, doneFolded int) {
		sep()
		rows = append(rows, SpineRow{
			Kind: rk, Ref: foldKey, Selectable: true, RK: headerRowKind(rk),
			hdr: spineHeader{title: title, code: code, derived: derived, counts: countSection(tasks, doneFolded)},
		})
		emitted = true
		// Nest the FULL child set, then cap to the shown head — capping in tree
		// order shows a coherent top-down slice (charter D42 head-of-5 cap).
		nested := nestTasks(tasks)
		if shown > len(nested) {
			shown = len(nested)
		}
		nested = nested[:shown]
		var bandCode string
		haveBands := sectionHasPhase(nested)
		for _, nt := range nested {
			if haveBands && nt.depth == 0 {
				if c := phaseCodeOf(nt.task); c != bandCode {
					bandCode = c
					if c != "" {
						rows = append(rows, SpineRow{
							Kind: spinePhaseBand, Depth: 0, Selectable: false,
							hdr: spineHeader{title: phaseName(nt.task, c), code: c},
						})
					}
				}
			}
			rows = append(rows, SpineRow{
				Kind: spineTask, Depth: nt.depth, Ref: nt.task.DocID, Selectable: true,
				RK: shellRK, task: nt.task,
			})
		}
		if hidden := len(tasks) - shown; hidden > 0 {
			rows = append(rows, SpineRow{Kind: spineMore, more: spineMoreInfo{hidden: hidden, done: doneFolded}})
		} else if doneFolded > 0 {
			rows = append(rows, SpineRow{Kind: spineMore, more: spineMoreInfo{done: doneFolded}})
		}
	}

	for _, e := range b.Epics {
		section(spineEpicHeader, rowChild, e.Root.DocID, e.Root.Title, phaseCodeOf(e.Root), false,
			e.Children, epicShown(st, e), e.DoneFolded)
	}
	for _, cl := range b.Clusters {
		section(spineClusterHeader, rowClusterMember, clusterFoldKey(cl.Key),
			clusterDisplayName(cl.Key), "", true, cl.Tasks, clusterShown(st, cl), cl.DoneFolded)
	}
	if len(b.Orphans) > 0 || b.OrphansFolded > 0 {
		title := "(no epic)"
		if len(b.Epics) == 0 {
			title = "tasks"
		}
		section(spineOrphanHeader, rowOrphan, orphansFoldKey, title, "", false,
			b.Orphans, orphansShown(st, b), b.OrphansFolded)
	}

	if !emitted {
		text := "All clear — no open tasks."
		if isSyncing(st) {
			text = "syncing…"
		}
		rows = append(rows, SpineRow{Kind: spineEmpty, text: text})
	}
	return rows
}

// headerRowKind maps a header spineKind to the shell rowKind the cursor uses.
func headerRowKind(k spineKind) rowKind {
	switch k {
	case spineClusterHeader:
		return rowClusterHeader
	case spineOrphanHeader:
		return rowOrphanHeader
	default:
		return rowEpicHeader
	}
}

// nestedTask is a task plus its tree depth within a section.
type nestedTask struct {
	task  Task
	depth int
}

// nestTasks arranges a flat, band-ordered section task slice into parent-before-
// child TREE order (charter D42), assigning each row a depth. Siblings keep
// their input (band) order; a task whose parent is not in the section set is a
// root at depth 0. For a FLAT section (no task is another's parent) this is the
// identity — same tasks, same order, all depth 0 — so the phase-less fixtures
// (and the cursor-parity guards) are unaffected. A cycle in bad data is broken
// by a visited set so the walk always terminates.
func nestTasks(tasks []Task) []nestedTask {
	inSet := make(map[string]bool, len(tasks))
	for _, t := range tasks {
		inSet[bareID(t.DocID)] = true
	}
	childrenOf := make(map[string][]Task)
	var roots []Task
	for _, t := range tasks {
		p := bareID(t.ParentID)
		if t.ParentID != "" && inSet[p] {
			childrenOf[p] = append(childrenOf[p], t)
		} else {
			roots = append(roots, t)
		}
	}
	out := make([]nestedTask, 0, len(tasks))
	seen := make(map[string]bool, len(tasks))
	var walk func(t Task, depth int)
	walk = func(t Task, depth int) {
		id := bareID(t.DocID)
		if seen[id] {
			return
		}
		seen[id] = true
		out = append(out, nestedTask{task: t, depth: depth})
		for _, c := range childrenOf[id] {
			walk(c, depth+1)
		}
	}
	for _, r := range roots {
		walk(r, 0)
	}
	// Any task orphaned by a cycle (never reached from a root) is appended flat,
	// so the count stays exactly len(tasks) — the head-cap math depends on it.
	for _, t := range tasks {
		if !seen[bareID(t.DocID)] {
			out = append(out, nestedTask{task: t, depth: 0})
			seen[bareID(t.DocID)] = true
		}
	}
	return out
}

// sectionHasPhase reports whether a section should split into display-only phase
// sub-bands (charter D41): only when its top-level rows carry at least TWO
// distinct phase codes. A section whose tasks all share one phase (or carry
// none) gains nothing from a band that just restates the section header, so it
// stays a plain restyled list — never a fabricated or redundant band.
func sectionHasPhase(nested []nestedTask) bool {
	seen := make(map[string]bool)
	for _, nt := range nested {
		if nt.depth == 0 {
			if c := phaseCodeOf(nt.task); c != "" {
				seen[c] = true
			}
		}
	}
	return len(seen) >= 2
}

// wCodeRe matches a phase W-code in a title: W1, W3-4, W3–4, W5.2 (ASCII hyphen
// or the en-dash the design uses).
var wCodeRe = regexp.MustCompile(`\bW\d+(?:[–-]\d+)?(?:\.\d+)?\b`)

// structuralPhaseValues are `phase:*` values that name a NODE KIND (the task's
// place in the tree), not a wave/phase. `phase:goal` / `phase:epic` mark the
// root of a goal or epic — they are not a rollup code, so they must never leak
// into the header's phase slot (the mockup shows a W-code or a bare fraction
// there, never "goal"). The live guerrilla goal roots carry `kind:task` +
// `phase:goal`, so the earlier `v == t.Kind` guard alone let "goal" through.
var structuralPhaseValues = map[string]bool{"goal": true, "epic": true, "task": true, "subtask": true}

// phaseCodeOf derives a task's phase code (charter D41): an explicit `phase:*`
// label wins (its value, W-code-ish), else a W-code parsed from the title, else
// "" (no phase — the guerrilla reality). Never invents a code. A structural
// `phase:goal`/`phase:epic` marker (or one that just echoes the task's own kind)
// is a node-type tag, not a phase, so it is skipped.
func phaseCodeOf(t Task) string {
	for _, l := range t.Labels {
		if strings.HasPrefix(l, labelPhasePrefix) {
			v := strings.TrimSpace(l[len(labelPhasePrefix):])
			if v != "" && v != t.Kind && !structuralPhaseValues[v] {
				return v
			}
		}
	}
	if m := wCodeRe.FindString(t.Title); m != "" {
		return m
	}
	return ""
}

// phaseName is the human label for a phase sub-band: the phase: label's value
// title-cased when it is descriptive, else the bare code (W5) — honest, never
// fabricated beyond what the data carries.
func phaseName(t Task, code string) string {
	for _, l := range t.Labels {
		if strings.HasPrefix(l, labelPhasePrefix) {
			v := strings.TrimSpace(l[len(labelPhasePrefix):])
			if v != "" && v != code {
				return v
			}
		}
	}
	return code
}
