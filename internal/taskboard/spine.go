package taskboard

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// spine.go — the ONE ordered spine producer (charter D42). Both the shell's
// visibleRows (the cursor index space) and the renderer's flattenSpine (the
// painted lines) consume spineRows, so cursor-parity is STRUCTURAL: they can no
// longer drift because they read the SAME ordered list. The spine IS the whole
// cursor space (Amendment 7 / commit 92a618f8 — the pinned NOW/NEXT band and its
// renderNowBand producer are retired): spineRows owns every cursor index, in
// emission order (epics → clusters → the loose bucket). A separator/phase-band is
// Selectable:false — display-only, never a cursor stop — while headers, tasks
// AND "+N more" fold lines (D57) are selectable: the fold line is the
// affordance for "open and see the rest". Both consumers read this ONE list,
// so the index space cannot desync.

// spineKind discriminates a spine row for the renderer.
type spineKind int

const (
	spineSep           spineKind = iota // blank separator (display-only)
	spineEpicHeader                     // authored-epic section header (selectable)
	spineClusterHeader                  // derived-cluster section header (selectable)
	spineOrphanHeader                   // the loose "(no epic)" header (selectable)
	spinePhaseBand                      // a named phase sub-band header inside an epic (display-only, W10-A)
	spineTask                           // a task row — epic child / cluster member / orphan (selectable)
	spineMore                           // "+K more" / "+N done · M cancelled" fold line (SELECTABLE, D57: enter expands)
	spineDeadEpic                       // a cancelled-root epic collapsed to one dim tombstone line (display-only, W10-B)
	spineEmpty                          // the syncing / all-clear fallback (display-only)
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
	// Outline is the exact section/tree prefix (├─, └─, and │ continuation
	// rails). It already includes any phase-band offset, so rendering performs no
	// second topology guess.
	Outline string

	task Task          // spineTask
	hdr  spineHeader   // *Header
	more spineMoreInfo // spineMore
	text string        // spineEmpty
}

type spineMoreInfo struct{ hidden, done, cancelled int }

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

	// emitNested renders a task subtree in parent-before-child tree order, each row
	// offset by `depthOffset` indent levels before its exact branch outline. No cap:
	// the caller has already narrowed the
	// slice to the focus neighborhood (modeFocus) or is showing all of it
	// (modeExpanded), and the section-level trailing line owns every fold count.
	emitNested := func(tasks []Task, depthOffset int, shellRK rowKind) {
		for _, nt := range nestTasks(tasks) {
			rows = append(rows, SpineRow{
				Kind: spineTask, Depth: nt.depth + depthOffset, Ref: nt.task.DocID, Selectable: true,
				RK: shellRK, task: nt.task, Outline: strings.Repeat("  ", depthOffset) + nt.outline,
			})
		}
	}

	// Each section: header (selectable), then — per mode (charter D51 / wave-11) —
	// its child rows. modeCollapsed/modeHeader emit the header ONLY (the dotted-
	// leader done/total rollup IS the big-picture summary). modeExpanded shows the
	// FULL kept set; modeFocus shows only the focus neighborhood. Rollups (the
	// header count and every phase-band count) ALWAYS run over the WHOLE `tasks` —
	// a band appears iff the window picks a row from it, but its rollup stays
	// whole-band. The trailing "+N more · M done · K cancelled" line is honest
	// about everything the window hid.
	section := func(rk spineKind, shellRK rowKind, foldKey, title, code string, derived bool,
		tasks []Task, mode sectionMode, focus map[string]bool, doneFolded, cancelledFolded int, allowBands bool) {
		sep()
		rows = append(rows, SpineRow{
			Kind: rk, Ref: foldKey, Selectable: true, RK: headerRowKind(rk),
			hdr: spineHeader{title: title, code: code, derived: derived, counts: countSection(tasks, doneFolded)},
		})
		emitted = true

		// Header-only modes (charter D51): the rollup line above IS the summary.
		if mode == modeCollapsed || mode == modeHeader {
			return
		}

		// The row set the window shows: the full kept children when expanded, the
		// focus neighborhood when active. hidden counts the kept rows the window
		// dropped (0 when expanded), surfaced honestly in the trailing line.
		show := func(ts []Task) []Task {
			if mode == modeFocus {
				return filterToFocus(ts, focus)
			}
			return ts
		}
		shownTasks := show(tasks)
		hidden := len(tasks) - len(shownTasks)

		// W10-A: named phase bands. When an epic's children carry >=2
		// phase:<n>-<slug> labels, group them into ordered, named sub-bands, each a
		// display-only dotted-leader header with its own Wcode·done/total rollup
		// (computed over the WHOLE band). Unphased children go FIRST, directly under
		// the epic header. In modeFocus a band appears only when the window picked at
		// least one of its rows; its rollup stays whole-band regardless.
		var bands []phaseBand
		var unphased []Task
		if allowBands && len(shownTasks) > 0 {
			bands, unphased = phaseBands(tasks)
		}
		if len(bands) > 0 {
			emitNested(show(unphased), 0, shellRK) // phase-less children first
			for _, bd := range bands {
				shownBand := show(bd.tasks)
				if len(shownBand) == 0 {
					continue // the window picked nothing from this band — skip its header
				}
				rows = append(rows, SpineRow{
					Kind: spinePhaseBand, Depth: 1, Selectable: false,
					hdr: spineHeader{title: bd.name, code: bd.code, counts: countSection(bd.tasks, 0)},
				})
				emitNested(shownBand, 1, shellRK)
			}
			if hidden > 0 || doneFolded > 0 || cancelledFolded > 0 {
				rows = append(rows, SpineRow{Kind: spineMore, Ref: foldKey, Selectable: true, RK: rowMore, more: spineMoreInfo{hidden: hidden, done: doneFolded, cancelled: cancelledFolded}})
			}
			return
		}

		// Flat (non-banded) section — nest the shown set in parent-before-child order.
		emitNested(shownTasks, 0, shellRK)
		if hidden > 0 || doneFolded > 0 || cancelledFolded > 0 {
			rows = append(rows, SpineRow{Kind: spineMore, Ref: foldKey, Selectable: true, RK: rowMore, more: spineMoreInfo{hidden: hidden, done: doneFolded, cancelled: cancelledFolded}})
		}
	}

	// W10-B: a cancelled-root epic is a tombstone — it collapses to ONE dim line
	// at the very BOTTOM of the board (after clusters/orphans), so dead epics stop
	// occupying prime space. Partition them out of the in-place epic loop here.
	// D64 (Amendment 5 — completion ≠ activity): a FINISHED section past its
	// grace window (Demoted) relocates to the finished shelf just above those
	// tombstones — still a normal, selectable, expandable section (h/l/enter and
	// explicit overrides all work), just no longer occupying prime space.
	var deadEpics, finishedEpics []Epic
	for _, e := range b.Epics {
		if e.Root.Lifecycle == lifeCancelled {
			deadEpics = append(deadEpics, e)
			continue
		}
		if e.Demoted {
			finishedEpics = append(finishedEpics, e)
			continue
		}
		section(spineEpicHeader, rowChild, e.Root.DocID, e.Root.Title, phaseCodeOf(e.Root), false,
			e.Children, epicMode(st, e), e.FocusSet, e.DoneFolded, e.CancelledFolded, true)
	}
	var finishedClusters []Cluster
	for _, cl := range b.Clusters {
		if cl.Demoted {
			finishedClusters = append(finishedClusters, cl)
			continue
		}
		section(spineClusterHeader, rowClusterMember, clusterFoldKey(cl.Key),
			clusterDisplayName(cl.Key), "", true, cl.Tasks, clusterMode(st, cl), cl.FocusSet, cl.DoneFolded, cl.CancelledFolded, false)
	}
	if len(b.Orphans) > 0 || b.OrphansFolded > 0 || b.OrphansCancelledFolded > 0 {
		title := "(no epic)"
		if len(b.Epics) == 0 {
			title = "tasks"
		}
		section(spineOrphanHeader, rowOrphan, orphansFoldKey, title, "", false,
			b.Orphans, orphansMode(st, b), b.OrphansFocusSet, b.OrphansFolded, b.OrphansCancelledFolded, false)
	}
	// The finished shelf (D64): decayed sections, newest completion first.
	for _, e := range finishedEpics {
		section(spineEpicHeader, rowChild, e.Root.DocID, e.Root.Title, phaseCodeOf(e.Root), false,
			e.Children, epicMode(st, e), e.FocusSet, e.DoneFolded, e.CancelledFolded, true)
	}
	for _, cl := range finishedClusters {
		section(spineClusterHeader, rowClusterMember, clusterFoldKey(cl.Key),
			clusterDisplayName(cl.Key), "", true, cl.Tasks, clusterMode(st, cl), cl.FocusSet, cl.DoneFolded, cl.CancelledFolded, false)
	}
	for _, e := range deadEpics {
		sep()
		rows = append(rows, SpineRow{Kind: spineDeadEpic, Ref: e.Root.DocID, Selectable: false,
			hdr: spineHeader{title: e.Root.Title}})
		emitted = true
	}

	if !emitted {
		text := "All clear — no open tasks."
		if st.ConnProblem != "" {
			text = "Unable to load tasks — " + st.ConnProblem + "."
		} else if isSyncing(st) {
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
	task    Task
	depth   int
	outline string
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
	var walkSiblings func(siblings []Task, depth int, ancestorContinues []bool)
	walkSiblings = func(siblings []Task, depth int, ancestorContinues []bool) {
		for i, t := range siblings {
			id := bareID(t.DocID)
			if seen[id] {
				continue
			}
			hasNext := i < len(siblings)-1
			var prefix strings.Builder
			for _, continues := range ancestorContinues {
				if continues {
					prefix.WriteString("│ ")
				} else {
					prefix.WriteString("  ")
				}
			}
			if hasNext {
				prefix.WriteString("├─")
			} else {
				prefix.WriteString("└─")
			}
			seen[id] = true
			out = append(out, nestedTask{task: t, depth: depth, outline: prefix.String()})
			walkSiblings(childrenOf[id], depth+1, append(ancestorContinues, hasNext))
		}
	}
	walkSiblings(roots, 0, nil)
	// Any task orphaned by a cycle (never reached from a root) is appended flat,
	// so the count stays exactly len(tasks) — the head-cap math depends on it.
	for _, t := range tasks {
		if !seen[bareID(t.DocID)] {
			walkSiblings([]Task{t}, 0, nil)
		}
	}
	return out
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

// ── Named phase bands (charter wave-10 W10-A) ────────────────────────────────

// phaseBand is one named phase sub-band inside an epic: the children sharing a
// phase:<n>-<slug> label, ordered by the leading ordinal.
type phaseBand struct {
	order string // the leading ordinal, e.g. "1" (string-sortable, <=7 phases)
	name  string // title-cased slug — phase:5-paper-components → "Paper Components"
	code  string // Wcode derived from the children's title prefixes ("" when none)
	tasks []Task
}

// phaseNumSlugRe matches a phase:<n>-<slug> label VALUE: a 1-based ordinal, a
// hyphen, then a kebab slug. It deliberately does NOT match the structural
// sentinels (phase:goal / phase:build / phase:work …) or the bare W-code phases
// (phase:W1) — only the wave-10 named form drives banding.
var phaseNumSlugRe = regexp.MustCompile(`^(\d+)-(.+)$`)

// phaseLabelOf returns a task's phase ordinal + slug when it carries exactly one
// phase:<n>-<slug> label, else ok=false. The first matching label wins (tasks
// carry exactly one by the authoring contract).
func phaseLabelOf(t Task) (ord, slug string, ok bool) {
	for _, l := range t.Labels {
		if !strings.HasPrefix(l, labelPhasePrefix) {
			continue
		}
		v := strings.TrimSpace(l[len(labelPhasePrefix):])
		if m := phaseNumSlugRe.FindStringSubmatch(v); m != nil {
			return m[1], m[2], true
		}
	}
	return "", "", false
}

// phaseBands groups an epic's children into ordered, named phase bands from their
// phase:<n>-<slug> labels (charter W10-A). It bands ONLY when >=2 children carry
// such a label (else it returns nil bands + every task as unphased, so an epic
// with no phase metadata renders exactly as before — regression-neutral for the
// uncurated majority). Bands sort by ordinal (then slug); children keep their
// input (policy/band) order within a band.
func phaseBands(tasks []Task) (bands []phaseBand, unphased []Task) {
	type acc struct {
		order, slug string
		tasks       []Task
	}
	groups := map[string]*acc{}
	var order []string
	phased := 0
	for _, t := range tasks {
		ord, slug, ok := phaseLabelOf(t)
		if !ok {
			unphased = append(unphased, t)
			continue
		}
		phased++
		key := ord + "-" + slug
		g, seen := groups[key]
		if !seen {
			g = &acc{order: ord, slug: slug}
			groups[key] = g
			order = append(order, key)
		}
		g.tasks = append(g.tasks, t)
	}
	if phased < 2 {
		return nil, tasks
	}
	sort.SliceStable(order, func(i, j int) bool {
		a, b := groups[order[i]], groups[order[j]]
		if a.order != b.order {
			return a.order < b.order
		}
		return a.slug < b.slug
	})
	for _, k := range order {
		g := groups[k]
		bands = append(bands, phaseBand{
			order: g.order, name: titleCaseSlug(g.slug), code: deriveBandCode(g.tasks), tasks: g.tasks,
		})
	}
	return bands, unphased
}

// acronymAllowlist upper-cases known initialisms when title-casing a slug; every
// other kebab word is plain Title Case (phase:3-web → "Web").
var acronymAllowlist = map[string]string{
	"tui": "TUI", "cli": "CLI", "ui": "UI", "api": "API", "sdk": "SDK",
	"cf": "CF", "dr": "DR", "sso": "SSO", "saml": "SAML", "dpa": "DPA",
}

// titleCaseSlug renders a phase slug as a band name: split on "-", title-case
// each kebab word (acronyms upper-cased). phase:5-paper-components → "Paper
// Components"; phase:1-feel-alive → "Feel Alive".
func titleCaseSlug(slug string) string {
	parts := strings.Split(slug, "-")
	for i, p := range parts {
		if p == "" {
			continue
		}
		if a, ok := acronymAllowlist[strings.ToLower(p)]; ok {
			parts[i] = a
			continue
		}
		parts[i] = strings.ToUpper(p[:1]) + p[1:]
	}
	return strings.Join(parts, " ")
}

// wMajorRe captures the MAJOR wave number from a title's W-code (W1.2 → 1,
// W3–4 → 3). Used to derive a band's rollup code from its children's titles.
var wMajorRe = regexp.MustCompile(`\bW(\d+)`)

// deriveBandCode derives a band's Wcode from its children's title prefixes: one
// distinct major → "W<n>"; a span → "W<min>–<max>" (en-dash, the mockup's
// "W3–4"); none derivable → "" (the rollup renders alone). It reads the titles,
// NOT the phase label, so a band whose members span waves 3 and 4 merges into one
// honest "W3–4" range.
func deriveBandCode(tasks []Task) string {
	lo, hi, found := 0, 0, false
	for _, t := range tasks {
		m := wMajorRe.FindStringSubmatch(t.Title)
		if m == nil {
			continue
		}
		n, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		if !found {
			lo, hi, found = n, n, true
			continue
		}
		if n < lo {
			lo = n
		}
		if n > hi {
			hi = n
		}
	}
	if !found {
		return ""
	}
	if lo == hi {
		return fmt.Sprintf("W%d", lo)
	}
	return fmt.Sprintf("W%d–%d", lo, hi) // en-dash range
}
