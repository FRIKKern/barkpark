package pdrender

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// ── task widgets: task-list / task-detail / task-board / roadmap ─────────────
//
// These four blocks are the terminal counterparts of the PortableDoc task
// widgets the web/Studio reader draws (Render.Components.tasks_html /
// task_detail_html / task_board_html / roadmap_html). Before this file they fell
// through to the "unknown block" fallback box in the TUI/CLI while the web reader
// rendered them fully — a cross-surface divergence this closes
// (pdrender-block-parity: task-* family).
//
// RESOLVED-DATA CONTRACT: these blocks arrive PRE-RESOLVED. The paper resolver
// replaces the authored `query` with literal data in Attrs — a `snapshot` list
// for task-list/task-board/roadmap, a `task` map for task-detail. pdrender draws
// WHATEVER is in Attrs; it never fetches. When the resolved key is ABSENT (only
// `query` present — e.g. an offline/wasm render), the widget degrades HONESTLY
// to a short dim placeholder line rather than pretending. The status vocabulary
// (role/glyph/color) is the SHARED source in gridblocks.go (roleForStatus /
// glyphForRole / glyphForStatus / statusGlyphStyle).
//
// Import discipline holds: only lipgloss + the stdlib, styles come from the
// injected Theme, every document-controlled string passes through sanitizeText
// before display, and each renderer degrades (never panics) on absent/empty
// attrs, an empty row/criterion, a sub-MinWidth column, or an out-of-range bar.

// resolvedKeyPresent reports whether the resolver has stamped `key` onto the
// block. attrSlice can't distinguish "absent" from "present but empty", so the
// unresolved degrade path keys off raw map membership.
func resolvedKeyPresent(b Block, key string) bool {
	if b.Attrs == nil {
		return false
	}
	_, ok := b.Attrs[key]
	return ok
}

// ── task-list (aliases: tasks + task-list) ───────────────────────────────────
// {snapshot: [row], title?}. row: {title, status, priority, criteria:{met,total},
// blocked_by, worker, phase, depth}. Stacked ROWS (not boxes): an optional bold
// title, a momentum header derived from role counts, then phase groups — each a
// `name ──── done/total` header line — with rows `glyph  title   P2 · m/n ·
// worker` (dim metadata). Absent snapshot → dim placeholder; empty → "No tasks
// yet."
type taskListRenderer struct{}

func (taskListRenderer) Render(b Block, ctx RenderCtx) []string {
	if !resolvedKeyPresent(b, "snapshot") {
		return []string{unresolvedPlaceholder(ctx, "task-list")}
	}
	rows := itemMaps(b.Attrs, "snapshot")
	if len(rows) == 0 {
		return []string{ctx.Theme.Dim.Render("No tasks yet.")}
	}

	// layout:{mode:"tree"} switches to the dependency-tree axis (├─ └─ │ rails +
	// a right-aligned worker/priority meta grid). Any other/absent layout falls
	// through to the byte-identical legacy phase-grouped rendering below.
	if layout, ok := b.Attrs["layout"].(map[string]any); ok && attrStr(layout, "mode") == "tree" {
		return taskTreeLines(b, rows, ctx)
	}

	w := clampWidth(ctx.Width)
	var out []string

	if title := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "title"))); title != "" {
		out = append(out, wrapLines(ctx.Theme.Body.Bold(true).Render(title), w)...)
	}
	out = append(out, momentumLine(rows, ctx, w))
	out = append(out, momentumBar(rows, ctx, w))

	order, byPhase := groupRowsByPhase(rows)
	for _, phase := range order {
		prs := byPhase[phase]
		if phase != "" {
			out = append(out, phaseHeader(phase, prs, ctx, w))
		}
		for _, r := range prs {
			out = append(out, taskRowLines(r, ctx, w)...)
		}
	}
	return out
}

// momentumLine is the "always feel progress" header: in-flight / ready / done
// counts and a done-percentage, on one wrapped line.
func momentumLine(rows []map[string]any, ctx RenderCtx, w int) string {
	total := len(rows)
	prog := countRole(rows, "progress")
	ready := countRole(rows, "ready")
	done := countRole(rows, "done")
	pct := 0
	if total > 0 {
		pct = int(math.Round(float64(done) / float64(total) * 100))
	}
	seg := func(status, label string, n int) string {
		return glyphForStatus(ctx.Theme, status) + " " +
			ctx.Theme.Body.Bold(true).Render(strconv.Itoa(n)) + " " +
			ctx.Theme.Dim.Render(label)
	}
	line := seg("in_progress", "in flight", prog) + "   " +
		seg("ready", "ready", ready) + "   " +
		seg("done", "done", done) + "   " +
		ctx.Theme.Dim.Render(strconv.Itoa(pct)+"%")
	// The line is a single visual row; a narrow surface wraps it, first line wins.
	return firstLine(wrapLines(line, w))
}

// momentumBar is the proportional progress bar paired with the momentum counts —
// the house standard (internal/taskboard progressBar pairs momentumLine with a
// bar). fill = done/total * w cells of ▓ in the done tone, the remainder ░ in
// Dim, so the two pdrender task widgets (task-list here + roadmap) share the same
// ▓ fill glyph. Exactly one full-width line, drawn directly under the counts.
func momentumBar(rows []map[string]any, ctx RenderCtx, w int) string {
	w = clampWidth(w)
	total := len(rows)
	done := countRole(rows, "done")
	fill := 0
	if total > 0 {
		fill = done * w / total
	}
	if fill > w {
		fill = w
	}
	if fill < 0 {
		fill = 0
	}
	return statusGlyphStyle(ctx.Theme, "done").Render(strings.Repeat("▓", fill)) +
		ctx.Theme.Dim.Render(strings.Repeat("░", w-fill))
}

// phaseHeader is a `name ──── done/total` band separating phase groups.
func phaseHeader(name string, rows []map[string]any, ctx RenderCtx, w int) string {
	name = sanitizeText(name)
	done := countRole(rows, "done")
	count := fmt.Sprintf("%d/%d", done, len(rows))
	fill := w - runeWidth(name) - runeWidth(count) - 2 // two joining spaces
	if fill < 1 {
		fill = 1
	}
	return ctx.Theme.Body.Bold(true).Render(name) + " " +
		ctx.Theme.Rule.Render(strings.Repeat("─", fill)) + " " +
		ctx.Theme.Dim.Render(count)
}

// taskRowLines renders one snapshot row: `[indent][↳] glyph title   meta`. depth
// (0..5) indents by two spaces per level and prefixes a dim ↳; metadata (P·m/n·
// !blocked·worker) trails in Dim.
func taskRowLines(r map[string]any, ctx RenderCtx, w int) []string {
	title := sanitizeText(strings.TrimSpace(attrStr(r, "title")))
	glyph := glyphForStatus(ctx.Theme, attrStr(r, "status"))

	depth := attrInt(r, "depth", 0)
	if depth < 0 {
		depth = 0
	}
	if depth > 5 {
		depth = 5
	}
	indent := strings.Repeat("  ", depth)
	arrow := ""
	if depth > 0 {
		arrow = ctx.Theme.Dim.Render("↳") + " "
	}

	line := indent + arrow + glyph + " " + ctx.Theme.Body.Render(title)
	if meta := rowMeta(r); len(meta) > 0 {
		line += "  " + ctx.Theme.Dim.Render(strings.Join(meta, " · "))
	}
	return wrapLines(line, w)
}

// rowMeta assembles the trailing metadata cells of a task row / board card:
// P<n> · <met>/<total> · ! <blocked_by> · <worker>. Absent cells are dropped.
func rowMeta(r map[string]any) []string {
	var meta []string
	if p := priorityLabel(attrStr(r, "priority")); p != "" {
		meta = append(meta, p)
	}
	if c := criteriaLabel(r["criteria"]); c != "" {
		meta = append(meta, c)
	}
	if n := attrInt(r, "blocked_by", 0); n > 0 {
		meta = append(meta, "! "+strconv.Itoa(n))
	}
	if wk := sanitizeText(strings.TrimSpace(attrStr(r, "worker"))); wk != "" {
		meta = append(meta, wk)
	}
	return meta
}

// ── task-list layout:{mode:"tree"} ───────────────────────────────────────────
//
// The dependency-tree axis: the SAME bold-title + momentum header as the flat
// list, then one row per snapshot entry drawn as a ├─ └─ │ tree whose rails are
// derived PURELY from the consecutive `depth` sequence of the author-literal
// rows. parent_id is a QUERY filter, never on the row wire (row_from_task emits
// only title/status/priority/worker/criteria/phase/depth — the D6 precedent), so
// this renderer NEVER reads or invents it: a row at depth d is the child of the
// nearest preceding depth d-1 row, and the rails fall straight out of that
// sequence. A right-aligned worker/priority meta grid trails every row with its
// two columns padded to a shared width so they line up down the surface.

// clampDepth clamps an author-literal `depth` into the supported 0..5 band (the
// same band taskRowLines uses for its indent).
func clampDepth(d int) int {
	if d < 0 {
		return 0
	}
	if d > 5 {
		return 5
	}
	return d
}

func taskTreeLines(b Block, rows []map[string]any, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	var out []string

	if title := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "title"))); title != "" {
		out = append(out, wrapLines(ctx.Theme.Body.Bold(true).Render(title), w)...)
	}
	out = append(out, momentumLine(rows, ctx, w))
	out = append(out, momentumBar(rows, ctx, w))

	// Snapshot the depth sequence once (rails are a pure function of it), and
	// measure the meta grid's two columns across every row so they align.
	depths := make([]int, len(rows))
	workers := make([]string, len(rows))
	pris := make([]string, len(rows))
	workerW, priW := 0, 0
	for i, r := range rows {
		depths[i] = clampDepth(attrInt(r, "depth", 0))
		workers[i] = sanitizeText(strings.TrimSpace(attrStr(r, "worker")))
		pris[i] = priorityLabel(attrStr(r, "priority"))
		if n := runeWidth(workers[i]); n > workerW {
			workerW = n
		}
		if n := runeWidth(pris[i]); n > priW {
			priW = n
		}
	}
	metaW := 0
	if workerW > 0 {
		metaW += workerW
	}
	if priW > 0 {
		if metaW > 0 {
			metaW++ // the single space joining the two meta columns
		}
		metaW += priW
	}

	for i, r := range rows {
		out = append(out, treeRow(r, ctx, w, depths, i, workers[i], pris[i], workerW, priW, metaW))
	}
	return out
}

// treeRow renders one tree row: `<dim rails><glyph> <title>   <worker> <pri>`.
// The label is house-ellipsis truncated to whatever the rails and the meta grid
// leave (so a deep row — depth≥3 — clamps its label instead of shoving the meta
// grid off the right edge), then the meta grid is padded flush-right.
func treeRow(r map[string]any, ctx RenderCtx, w int, depths []int, i int, worker, pri string, workerW, priW, metaW int) string {
	prefix := treeRailPrefix(depths, i)
	prefixW := runeWidth(prefix)
	glyph := glyphForStatus(ctx.Theme, attrStr(r, "status"))
	title := sanitizeText(strings.TrimSpace(attrStr(r, "title")))

	// Title budget = surface − rails − (glyph+space) − meta grid − a 2-col gutter.
	const gutter = 2
	budget := w - prefixW - 2 - metaW
	if metaW > 0 {
		budget -= gutter
	}
	if budget < 1 {
		budget = 1
	}
	if runeWidth(title) > budget {
		title = padOrTruncate(title, budget) // house-ellipsis, exactly `budget` wide
	}

	left := ctx.Theme.Dim.Render(prefix) + glyph + " " + ctx.Theme.Body.Render(title)
	leftW := prefixW + 2 + runeWidth(title)
	if metaW == 0 {
		return left
	}
	pad := w - metaW - leftW
	if pad < 1 {
		pad = 1
	}
	return left + strings.Repeat(" ", pad) + treeMetaCell(ctx, worker, pri, workerW, priW)
}

// treeMetaCell builds the dim two-column meta grid: worker LEFT-aligned in its
// column, priority RIGHT-aligned in its own, joined by one space. An empty cell
// pads to spaces so the columns stay aligned down the tree.
func treeMetaCell(ctx RenderCtx, worker, pri string, workerW, priW int) string {
	var parts []string
	if workerW > 0 {
		parts = append(parts, padOrTruncate(worker, workerW))
	}
	if priW > 0 {
		parts = append(parts, leftPad(pri, priW))
	}
	return ctx.Theme.Dim.Render(strings.Join(parts, " "))
}

// treeRailPrefix builds the (plain — the caller renders it dim) ├─ └─ │ rail
// prefix for row i from the depth sequence. Depth-0 rows are forest roots and
// carry no prefix. A row at depth d≥1 gets (d-1) ancestor-continuation cells
// (│ where that ancestor still has a later sibling, blank where it was the last
// child) then its own connector (└─ when it is the last child at its depth, ├─
// otherwise). Every cell is exactly 3 display columns so labels align by depth.
func treeRailPrefix(depths []int, i int) string {
	d := depths[i]
	if d <= 0 {
		return ""
	}
	var sb strings.Builder
	for l := 1; l < d; l++ {
		if ancestorHasLaterSibling(depths, i, l) {
			sb.WriteString("│  ")
		} else {
			sb.WriteString("   ")
		}
	}
	if isLastSibling(depths, i) {
		sb.WriteString("└─ ")
	} else {
		sb.WriteString("├─ ")
	}
	return sb.String()
}

// isLastSibling reports whether row i is the last row at its depth within its
// parent group: scanning forward, the first row at depth ≤ d(i) is SHALLOWER (we
// left the subtree) or the list ends — no later sibling at the same depth.
func isLastSibling(depths []int, i int) bool {
	d := depths[i]
	for j := i + 1; j < len(depths); j++ {
		if depths[j] < d {
			return true
		}
		if depths[j] == d {
			return false
		}
	}
	return true
}

// ancestorHasLaterSibling reports whether row i's ancestor at level l still has a
// sibling coming after i — i.e. whether the │ continuation must be drawn at
// column l. The ancestor at level l is the nearest preceding row at depth l; it
// has a later sibling exactly when it is NOT itself a last sibling.
func ancestorHasLaterSibling(depths []int, i, l int) bool {
	a := ancestorAt(depths, i, l)
	if a < 0 {
		return false
	}
	return !isLastSibling(depths, a)
}

// ancestorAt returns the index of row i's ancestor at depth level l — the nearest
// preceding row at depth exactly l — or -1 when the sequence has no proper
// ancestor there (a malformed depth jump degrades to a blank rail column).
func ancestorAt(depths []int, i, l int) int {
	for j := i - 1; j >= 0; j-- {
		if depths[j] == l {
			return j
		}
		if depths[j] < l {
			return -1
		}
	}
	return -1
}

// ── task-detail ──────────────────────────────────────────────────────────────
// {task: map} (or the block Attrs itself when `task` is absent — a thin inline
// task). ONE bordered card: bold title · meta line (glyph + status·P·kind·worker)
// · created/updated stamp · description · `Criteria · m/total` + per-item rows
// (met→✓ done / unmet→○ ready) with evidence · dependencies in words · children /
// papers / labels rails. Every absent section is omitted; below MinWidth the box
// is dropped and the stack renders flat. No title → dim placeholder.
type taskDetailRenderer struct{}

func (taskDetailRenderer) Render(b Block, ctx RenderCtx) []string {
	t := b.Attrs
	if m, ok := b.Attrs["task"].(map[string]any); ok {
		t = m
	}
	title := sanitizeText(strings.TrimSpace(attrStr(t, "title")))
	if title == "" {
		return []string{unresolvedPlaceholder(ctx, "task-detail")}
	}

	const chrome = 4 // rounded border (2) + padding (2)
	inner := ctx.Width - chrome
	flat := inner < MinWidth
	cw := inner
	if flat {
		cw = ctx.Width
	}
	cw = clampWidth(cw)

	var lines []string
	add := func(ls ...string) { lines = append(lines, ls...) }

	add(wrapLines(ctx.Theme.Body.Bold(true).Render(title), cw)...)
	add(detailMeta(t, ctx, cw)...)
	add(detailStamp(t, ctx, cw)...)
	add(detailTimeline(t, ctx, cw)...)
	add(detailDesc(t, ctx, cw)...)
	add(detailCriteria(t, ctx, cw)...)
	add(detailDeps(t, ctx, cw)...)
	add(detailChildren(t, ctx, cw)...)
	add(detailPapers(t, ctx, cw)...)
	add(detailLabels(t, ctx, cw)...)

	if flat {
		return lines
	}
	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ruleColor(ctx.Theme)).
		Padding(0, 1).
		// lipgloss Width INCLUDES the padding (border excluded): inner+2 gives the
		// children their full `inner` columns and lands the border on ctx.Width.
		// Width(inner) left inner-2 for content, force-wrapping bordered children.
		Width(clampWidth(inner + 2)).
		Render(body)
	return strings.Split(box, "\n")
}

func detailMeta(t map[string]any, ctx RenderCtx, cw int) []string {
	glyph := glyphForStatus(ctx.Theme, attrStr(t, "status"))
	var parts []string
	if s := strings.TrimSpace(attrStr(t, "status")); s != "" {
		parts = append(parts, s)
	}
	if p := priorityLabel(attrStr(t, "priority")); p != "" {
		parts = append(parts, p)
	}
	if k := strings.TrimSpace(attrStr(t, "kind")); k != "" {
		parts = append(parts, k)
	}
	if wk := strings.TrimSpace(attrStr(t, "worker")); wk != "" {
		parts = append(parts, wk)
	}
	if len(parts) == 0 {
		return wrapLines(glyph, cw)
	}
	return wrapLines(glyph+" "+ctx.Theme.Dim.Render(sanitizeText(strings.Join(parts, " · "))), cw)
}

func detailStamp(t map[string]any, ctx RenderCtx, cw int) []string {
	var st []string
	if c := strings.TrimSpace(attrStr(t, "created")); c != "" {
		st = append(st, "created "+c)
	}
	if u := strings.TrimSpace(attrStr(t, "updated")); u != "" {
		st = append(st, "updated "+u)
	}
	if len(st) == 0 {
		return nil
	}
	return wrapLines(ctx.Theme.Dim.Render(sanitizeText(strings.Join(st, " · "))), cw)
}

// detailTimeline renders the task's lifecycle timeline — one glyph+label cell
// per status transition, joined by a dim arrow — mirroring the Elixir emitter's
// detail_timeline/1 (components.ex). Conditional-nil when absent/empty so a
// task-detail with no "timeline" key emits nothing (keeps sample_m6 frozen).
// Reuses the shared white-ladder status vocab (glyphForStatus → roleForStatus →
// statusGlyphStyle) so each Go glyph matches its Elixir glyph_html(role_of(...)).
func detailTimeline(t map[string]any, ctx RenderCtx, cw int) []string {
	segs := itemMaps(t, "timeline")
	if len(segs) == 0 {
		return nil
	}
	cells := make([]string, 0, len(segs))
	for _, s := range segs {
		glyph := glyphForStatus(ctx.Theme, attrStr(s, "status"))
		cells = append(cells, glyph+" "+sanitizeText(attrStr(s, "label")))
	}
	return wrapLines(strings.Join(cells, ctx.Theme.Dim.Render(" → ")), cw)
}

func detailDesc(t map[string]any, ctx RenderCtx, cw int) []string {
	d := sanitizeText(strings.TrimSpace(attrStr(t, "description")))
	if d == "" {
		return nil
	}
	return wrapLines(ctx.Theme.Body.Render(d), cw)
}

func detailCriteria(t map[string]any, ctx RenderCtx, cw int) []string {
	items := itemMaps(t, "criteria")
	if len(items) == 0 {
		return nil
	}
	met := 0
	for _, c := range items {
		if isTruthy(c["met"]) {
			met++
		}
	}
	done := statusGlyphStyle(ctx.Theme, "done")
	ready := statusGlyphStyle(ctx.Theme, "ready")

	out := []string{ctx.Theme.FieldLabel.Render(fmt.Sprintf("Criteria · %d/%d", met, len(items)))}
	for _, c := range items {
		txt := strings.TrimSpace(attrStr(c, "text"))
		if txt == "" {
			txt = strings.TrimSpace(attrStr(c, "criterion"))
		}
		txt = sanitizeText(txt)
		var g string
		if isTruthy(c["met"]) {
			g = done.Render("✓")
		} else {
			g = ready.Render("○")
		}
		out = append(out, wrapLines(g+" "+ctx.Theme.Body.Render(txt), cw)...)
		if ev := sanitizeText(strings.TrimSpace(attrStr(c, "evidence"))); ev != "" {
			out = append(out, wrapLines(ctx.Theme.Dim.Render("↳ "+ev), cw)...)
		}
	}
	return out
}

func detailDeps(t map[string]any, ctx RenderCtx, cw int) []string {
	blocks := attrInt(t, "blocks", 0)
	blocked := attrInt(t, "blocked_by", 0)
	var words []string
	if blocks > 0 {
		unit := "tasks"
		if blocks == 1 {
			unit = "task"
		}
		words = append(words, fmt.Sprintf("blocks %d %s", blocks, unit))
	}
	if blocked > 0 {
		words = append(words, fmt.Sprintf("blocked by %d", blocked))
	}
	if len(words) == 0 {
		return nil
	}
	return append(
		[]string{ctx.Theme.FieldLabel.Render("Dependencies")},
		wrapLines(ctx.Theme.Body.Render(strings.Join(words, " · ")), cw)...,
	)
}

// detailChildren is the children rail: `Children · d/n done` then up to 20 rows
// of `glyph title` (dim), with an overflow tail.
func detailChildren(t map[string]any, ctx RenderCtx, cw int) []string {
	kids := itemMaps(t, "children")
	if len(kids) == 0 {
		return nil
	}
	done := countRole(kids, "done")
	out := []string{ctx.Theme.FieldLabel.Render(fmt.Sprintf("Children · %d/%d done", done, len(kids)))}
	shown := kids
	if len(shown) > 20 {
		shown = shown[:20]
	}
	for _, k := range shown {
		role := roleForStatus(attrStr(k, "status"))
		g := statusGlyphStyle(ctx.Theme, role).Render(glyphForRole(role))
		kt := sanitizeText(strings.TrimSpace(attrStr(k, "title")))
		out = append(out, wrapLines(g+" "+ctx.Theme.Dim.Render(kt), cw)...)
	}
	if len(kids) > 20 {
		out = append(out, ctx.Theme.Dim.Render(fmt.Sprintf("… and %d more", len(kids)-20)))
	}
	return out
}

// detailPapers is the papers rail: up to 10 `▸ title` dim lines with overflow.
func detailPapers(t map[string]any, ctx RenderCtx, cw int) []string {
	var titles []string
	for _, p := range attrSlice(t, "papers") {
		if s := sanitizeText(strings.TrimSpace(toStr(p))); s != "" {
			titles = append(titles, s)
		}
	}
	if len(titles) == 0 {
		return nil
	}
	out := []string{ctx.Theme.FieldLabel.Render("Papers")}
	shown := titles
	if len(shown) > 10 {
		shown = shown[:10]
	}
	for _, p := range shown {
		out = append(out, wrapLines(ctx.Theme.Dim.Render("▸ "+p), cw)...)
	}
	if len(titles) > 10 {
		out = append(out, ctx.Theme.Dim.Render(fmt.Sprintf("… and %d more", len(titles)-10)))
	}
	return out
}

// detailLabels is the labels rail: the non-empty labels joined by " · " in Dim.
func detailLabels(t map[string]any, ctx RenderCtx, cw int) []string {
	var labels []string
	for _, l := range attrSlice(t, "labels") {
		if s := sanitizeText(strings.TrimSpace(toStr(l))); s != "" {
			labels = append(labels, s)
		}
	}
	if len(labels) == 0 {
		return nil
	}
	return wrapLines(ctx.Theme.Dim.Render(strings.Join(labels, " · ")), cw)
}

// ── task-board ───────────────────────────────────────────────────────────────
// {snapshot: [row]}. Group rows by roleForStatus(status) into the FIXED column
// order open · ready · progress · blocked · done · considering · researching
// (empty columns omitted). The `open` lane mirrors the web reader's white-ladder
// column set so a populated `open` bucket is never silently dropped
// (bug-taskboard-drops-open-tasks). Where every
// lane clears MinWidth the lanes draw SIDE-BY-SIDE as bordered columns (the P9
// standard — the internal/taskboard lane look, ported into pdrender's
// import-disciplined world via joinColumns): a role-tinted rounded box per lane
// with a `glyph Label  count` header and its cards beneath. Below the per-cell
// floor the lanes STACK vertically (the verbatim fallback): each lane a
// `Label  count` header then its cards as glyph+title+meta rows. Absent snapshot
// → placeholder; empty → "No tasks yet."
type taskBoardRenderer struct{}

// boardColumns is the board's column ROLES in white-ladder order: the manifest
// ladder (statusLadder) MINUS `cancel`, which is not a lane — the same seven
// roles, in the same order, that react's BOARD_ROLES (js/packages/react/src/
// blocks/taskboard.ts) and Elixir's board_roles/0 (portable_doc/render/
// components.ex) carry. The header label is DERIVED (the canonical roleLabel,
// sentence-cased via boardLabel) — NOT a second hardcoded copy (the fold —
// shares gridblocks.go's roleLabel).
//
// The two thought states are load-bearing, not decoration: roleForStatus
// resolves `considering`/`researching` to roles of their own, and Render
// collects lanes by iterating boardColumns ALONE, so a role missing here means
// its rows are silently DROPPED from the board (the row-loss bug tlv-s3 left
// behind when its file list omitted this file).
var boardColumns = []string{"open", "ready", "progress", "blocked", "done", "considering", "researching"}

// boardLabel is a lane's sentence-cased column header, folded from the ONE
// canonical lowercase label: "in progress" → "In progress".
func boardLabel(role string) string {
	return capitalizeFirst(labelForRole(role))
}

func (taskBoardRenderer) Render(b Block, ctx RenderCtx) []string {
	if !resolvedKeyPresent(b, "snapshot") {
		return []string{unresolvedPlaceholder(ctx, "task-board")}
	}
	rows := itemMaps(b.Attrs, "snapshot")
	if len(rows) == 0 {
		return []string{ctx.Theme.Dim.Render("No tasks yet.")}
	}

	byRole := make(map[string][]map[string]any)
	for _, r := range rows {
		role := roleForStatus(attrStr(r, "status"))
		byRole[role] = append(byRole[role], r)
	}

	// Collect non-empty lanes in the fixed column order.
	type lane struct {
		role, label string
		rows        []map[string]any
	}
	var lanes []lane
	for _, role := range boardColumns {
		if rs := byRole[role]; len(rs) > 0 {
			lanes = append(lanes, lane{role, boardLabel(role), rs})
		}
	}
	if len(lanes) == 0 {
		return []string{ctx.Theme.Dim.Render("No tasks yet.")}
	}

	w := clampWidth(ctx.Width)
	n := len(lanes)
	const chrome = 4 // rounded border (2) + padding (2)
	// The shared Flex solver resolves per-lane width + the degrade verdict
	// (Measure owns the (W-(N-1)*gutter)/N divide; side-by-side when >1 lane clears MinWidth).
	cellW, sideBySide := DefaultFlex.Measure(w, n)
	if sideBySide {
		// Side-by-side bordered lanes.
		nodes := make([]Node, n)
		for i, ln := range lanes {
			innerW := clampWidth(cellW - chrome)
			body := laneBody(ln.role, ln.label, ln.rows, ctx, innerW)
			box := lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).
				BorderForeground(laneBorderColor(ctx.Theme, ln.role)).
				Padding(0, 1).
				Width(innerW).
				Render(lipgloss.JoinVertical(lipgloss.Left, body...))
			nodes[i] = Node{Lines: strings.Split(box, "\n"), Width: cellW, Span: 1}
		}
		// Measure-into-arrange: only lay lanes side-by-side if every bordered box's
		// realized min-content fits its cell. A card with a wide unbreakable token
		// (nodeWidth > cellW) would overflow, so fall through to the stacked lanes.
		if DefaultFlex.Fits(nodes) {
			return DefaultFlex.Arrange(nodes)
		}
	}

	// Fallback (verbatim): stacked lanes — taken when a lane falls below MinWidth
	// OR a lane's content min-width overflows its cell.
	var out []string
	for _, ln := range lanes {
		if len(out) > 0 {
			out = append(out, "") // rhythm between lanes
		}
		out = append(out, ctx.Theme.FieldLabel.Render(ln.label)+"  "+ctx.Theme.Dim.Render(strconv.Itoa(len(ln.rows))))
		for _, r := range ln.rows {
			out = append(out, boardCardLines(r, ln.role, ctx, w)...)
		}
	}
	if len(out) == 0 {
		return []string{ctx.Theme.Dim.Render("No tasks yet.")}
	}
	return out
}

// laneBody builds a bordered lane's inner lines: a `glyph Label  count` header
// (the role glyph via the shared statusGlyphStyle/glyphForRole seam, the label in
// FieldLabel, the count dim) then each card via boardCardLines at innerW.
func laneBody(role, label string, rows []map[string]any, ctx RenderCtx, innerW int) []string {
	glyph := statusGlyphStyle(ctx.Theme, role).Render(glyphForRole(role))
	header := glyph + " " + ctx.Theme.FieldLabel.Render(label) + "  " + ctx.Theme.Dim.Render(strconv.Itoa(len(rows)))
	out := wrapLines(header, innerW)
	for _, r := range rows {
		out = append(out, boardCardLines(r, role, ctx, innerW)...)
	}
	return out
}

// laneBorderColor tints a lane's rounded border by its role, reusing the shared
// statusGlyphStyle foreground (progress→info, done→success, blocked→warning,
// ready→body, open/cancel→dim). Falls back to the rule color when the style
// carries no foreground.
func laneBorderColor(t Theme, role string) lipgloss.TerminalColor {
	if c := statusGlyphStyle(t, role).GetForeground(); c != nil {
		return c
	}
	return ruleColor(t)
}

// boardCardLines renders one board card as an indented `glyph title  meta` row
// (P<n> · m/n meta), colored by the lane's role.
func boardCardLines(r map[string]any, role string, ctx RenderCtx, w int) []string {
	glyph := statusGlyphStyle(ctx.Theme, role).Render(glyphForRole(role))
	title := sanitizeText(strings.TrimSpace(attrStr(r, "title")))
	line := "  " + glyph + " " + ctx.Theme.Body.Render(title)
	var meta []string
	if p := priorityLabel(attrStr(r, "priority")); p != "" {
		meta = append(meta, p)
	}
	if c := criteriaLabel(r["criteria"]); c != "" {
		meta = append(meta, c)
	}
	if len(meta) > 0 {
		line += "  " + ctx.Theme.Dim.Render(strings.Join(meta, " · "))
	}
	return wrapLines(line, w)
}

// ── roadmap (v2 — date rails, month scale, milestone glyph layer) ─────────────
// {snapshot: [row], today?: 0-100|ISO, scale?: [str], start?: ISO, end?: ISO,
// months?: int}. row: {status, title, phase_row, left: 0-100, width: 0-100,
// start?: ISO, end?: ISO, milestone?: bool, note?: bool}. Author-positioned
// bars: each row is `label │····▓▓▓▓····│` — a fixed-width track, filled for the
// row's [left, left+width) run, · elsewhere.
//
// GLYPH LAYER (v2). Each track cell resolves to exactly one glyph by precedence
// ┃ > ◆ > ◇ > ▓/░ > ┊ > · (highest wins where markers coincide):
//
//	┃ today   — block `today` (numeric pct OR an ISO date within [start,end]).
//	◆ milestone — a row with `milestone:true`, at the bar's end cell.
//	◇ note      — a row with `note:true`, at the bar's start cell.
//	▓ / ░ fill  — ▓ for a done-role row, ░ (planned) otherwise; colored by role.
//	┊ month tick — interior month boundaries, placed by distributeSegments so
//	               the ticks never drift (they sum to EXACTLY the track).
//	· empty.
//
// DATE RAILS: when the block carries `start`+`end` ISO dates, a row's own
// `start`/`end` derive its left/width off that span; a row WITHOUT dates falls
// back to its literal pct left/width — byte-identical to the pre-v2 path (the
// pct math is untouched). Month ticks derive from `months` (explicit) else the
// month count of the span. This is the one bespoke renderer — every index is
// clamped, so it never panics.
type roadmapRenderer struct{}

func (roadmapRenderer) Render(b Block, ctx RenderCtx) []string {
	if !resolvedKeyPresent(b, "snapshot") {
		return []string{unresolvedPlaceholder(ctx, "roadmap")}
	}
	rows := itemMaps(b.Attrs, "snapshot")
	if len(rows) == 0 {
		return []string{ctx.Theme.Dim.Render("No roadmap items.")}
	}

	w := clampWidth(ctx.Width)
	var out []string

	// Optional scale axis header.
	if scale := attrSlice(b.Attrs, "scale"); len(scale) > 0 {
		var cells []string
		for _, c := range scale {
			if s := sanitizeText(strings.TrimSpace(toStr(c))); s != "" {
				cells = append(cells, s)
			}
		}
		if len(cells) > 0 {
			out = append(out, firstLine(wrapLines(ctx.Theme.Dim.Render(strings.Join(cells, "  ")), w)))
		}
	}

	// Label column width: widest title, capped to a third of the surface.
	labelW := 0
	for _, r := range rows {
		if n := runeWidth(sanitizeText(strings.TrimSpace(attrStr(r, "title")))); n > labelW {
			labelW = n
		}
	}
	cap := w / 3
	if cap < 6 {
		cap = 6
	}
	if cap > 24 {
		cap = 24
	}
	if labelW > cap {
		labelW = cap
	}
	if labelW < 1 {
		labelW = 1
	}
	// Track = surface − label − " " − the two │ rails.
	track := clampWidth(w - labelW - 3)

	// Optional block-level ISO date span → date-derived lanes + month ticks.
	blockStart, blockEnd, haveSpan := roadmapSpan(b.Attrs)

	// Month ┊ ticks: explicit `months` wins, else derive from the span.
	months := attrInt(b.Attrs, "months", 0)
	if months <= 0 && haveSpan {
		months = monthsBetween(blockStart, blockEnd)
	}
	ticks := monthTickCells(track, months)

	// Optional today now-marker cell (numeric pct OR an ISO date in the span).
	todayCell := roadmapTodayCell(b.Attrs, blockStart, blockEnd, haveSpan, track)

	for _, r := range rows {
		out = append(out, roadmapLane(r, ctx, labelW, track, todayCell, ticks, blockStart, blockEnd, haveSpan))
	}
	return out
}

// laneMarks carries the per-row glyph-layer inputs renderTrack resolves by
// precedence. milestone/note are cell indices, or -1 when absent.
type laneMarks struct {
	fillGlyph       string
	fillStyle       lipgloss.Style
	start, fill     int
	milestone, note int
}

// roadmapLane draws one row: a padded (phase→bold) label, then the bordered
// track holding the fill run and the optional milestone/note/today markers.
func roadmapLane(r map[string]any, ctx RenderCtx, labelW, track, todayCell int, ticks map[int]bool, blockStart, blockEnd time.Time, haveSpan bool) string {
	role := roleForStatus(attrStr(r, "status"))
	title := sanitizeText(strings.TrimSpace(attrStr(r, "title")))
	label := padOrTruncate(title, labelW)
	labelStyle := ctx.Theme.Body
	if attrBool(r, "phase_row") {
		labelStyle = ctx.Theme.Body.Bold(true)
	}

	left, width := roadmapLeftWidth(r, blockStart, blockEnd, haveSpan)
	start := pctToCell(left, track)
	fill := pctToCell(width, track)
	if start > track {
		start = track
	}
	if start+fill > track {
		fill = track - start
	}
	if fill < 0 {
		fill = 0
	}

	// Fill glyph: ▓ for a done row, ░ (planned) otherwise — dual-encoded so the
	// done/planned distinction survives an ANSI strip (color is reinforcement).
	fillGlyph := "░"
	if role == "done" {
		fillGlyph = "▓"
	}

	// Optional per-row point markers, resolved by precedence inside renderTrack.
	milestone := -1
	if attrBool(r, "milestone") {
		milestone = start
		if fill > 0 {
			milestone = start + fill - 1 // the bar's end cell
		}
		milestone = clampCell(milestone, track)
	}
	note := -1
	if attrBool(r, "note") {
		note = clampCell(start, track)
	}

	marks := laneMarks{
		fillGlyph: fillGlyph,
		fillStyle: statusGlyphStyle(ctx.Theme, role),
		start:     start,
		fill:      fill,
		milestone: milestone,
		note:      note,
	}
	bar := renderTrack(ctx, marks, track, todayCell, ticks)
	rail := ctx.Theme.Dim.Render("│")
	// Two UNEQUAL-width cells joined by joinColumns (the shared side-by-side body):
	// the label cell (labelW) and the bordered track cell (│bar│, track+2 rails), the
	// lane's single-space separator supplied as the gutter. Reuses the Node/join
	// primitive — no bespoke width math — and is byte-identical to the old
	// `label + " " + │bar│` concat (each cell is already exactly its width, so
	// joinColumns' pad is a no-op and the gutter is the one separating space).
	joined := joinColumns([][]string{{labelStyle.Render(label)}, {rail + bar + rail}}, []int{labelW, track + 2}, 1)
	return firstLine(joined)
}

// track-cell glyph classes, ordered LOW→HIGH so a numerically greater class wins
// where markers coincide: · < ┊ < ▓/░ < ◇ < ◆ < ┃ (the v2 precedence chain).
const (
	clsEmpty = iota
	clsTick
	clsFill
	clsNote
	clsMilestone
	clsToday
)

// renderTrack composes the track cells, run-grouping consecutive same-class
// cells so the styled string stays compact. Each cell's class is the HIGHEST
// marker present at that index (the precedence ┃ > ◆ > ◇ > ▓/░ > ┊ > ·).
func renderTrack(ctx RenderCtx, m laneMarks, track, todayCell int, ticks map[int]bool) string {
	accent := lipgloss.NewStyle().Foreground(ctx.Theme.Accent).Bold(true)

	classify := func(i int) int {
		switch {
		case i == todayCell:
			return clsToday
		case i == m.milestone:
			return clsMilestone
		case i == m.note:
			return clsNote
		case i >= m.start && i < m.start+m.fill:
			return clsFill
		case ticks[i]:
			return clsTick
		default:
			return clsEmpty
		}
	}
	glyphOf := func(class int) string {
		switch class {
		case clsToday:
			return "┃"
		case clsMilestone:
			return "◆"
		case clsNote:
			return "◇"
		case clsFill:
			return m.fillGlyph
		case clsTick:
			return "┊"
		default:
			return "·"
		}
	}
	styleOf := func(class int) lipgloss.Style {
		switch class {
		case clsToday:
			return accent
		case clsMilestone:
			return m.fillStyle.Bold(true)
		case clsFill:
			return m.fillStyle
		default: // note, tick, empty all render in Dim
			return ctx.Theme.Dim
		}
	}

	var b strings.Builder
	i := 0
	for i < track {
		cls := classify(i)
		j := i
		var run strings.Builder
		for j < track && classify(j) == cls {
			run.WriteString(glyphOf(cls))
			j++
		}
		b.WriteString(styleOf(cls).Render(run.String()))
		i = j
	}
	return b.String()
}

// ── roadmap v2 helpers: date rails + distributed-rounding month ticks ─────────

// roadmapSpan reads the block-level `start`+`end` ISO dates that anchor
// date-derived lanes. Both must parse and end must be after start; otherwise the
// block has no span and every lane uses its literal pct left/width.
func roadmapSpan(attrs map[string]any) (time.Time, time.Time, bool) {
	s, ok1 := parseISODate(attrStr(attrs, "start"))
	e, ok2 := parseISODate(attrStr(attrs, "end"))
	if ok1 && ok2 && e.After(s) {
		return s, e, true
	}
	return time.Time{}, time.Time{}, false
}

// roadmapLeftWidth resolves a lane's [left, width] percentages. With a block
// span AND parseable row `start`/`end`, they derive off the span; otherwise the
// literal `left`/`width` pct path (byte-identical to pre-v2). Both paths funnel
// through the SAME clampPct/clampBarWidth so date- and pct-positioned lanes land
// on identical cell math.
func roadmapLeftWidth(r map[string]any, start, end time.Time, haveSpan bool) (left, width float64) {
	if haveSpan {
		rs, ok1 := parseISODate(attrStr(r, "start"))
		re, ok2 := parseISODate(attrStr(r, "end"))
		if ok1 && ok2 {
			// Subtract the CLAMPED left, not the raw pct: a row whose start
			// predates the block span clamps to the track's left edge, and its
			// bar must still END at the row-end's true position — subtracting
			// the raw (negative) left would inflate the width past that end.
			left = clampPct(dateToPct(rs, start, end))
			width = clampBarWidth(dateToPct(re, start, end)-left, left)
			return left, width
		}
	}
	left = clampPct(attrFloat(r, "left"))
	width = clampBarWidth(attrFloat(r, "width"), left)
	return left, width
}

// roadmapTodayCell maps the block `today` marker onto a track cell. A numeric
// value is a 0-100 pct (the pre-v2 path, kept byte-identical); an ISO date
// derives its pct off the span. Absent/uncoercible → -1 (no marker).
func roadmapTodayCell(attrs map[string]any, start, end time.Time, haveSpan bool, track int) int {
	v, ok := attrs["today"]
	if !ok {
		return -1
	}
	clampToTrack := func(cell int) int {
		if cell >= track {
			return track - 1
		}
		return cell
	}
	if f, ok := toFloat(v); ok {
		return clampToTrack(pctToCell(clampPct(f), track))
	}
	if haveSpan {
		if d, ok := parseISODate(toStr(v)); ok {
			return clampToTrack(pctToCell(clampPct(dateToPct(d, start, end)), track))
		}
	}
	return -1
}

// parseISODate parses a YYYY-MM-DD author-literal date; blank/malformed → !ok.
func parseISODate(s string) (time.Time, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// dateToPct maps a date onto a 0-100 position within [start, end]. A degenerate
// span (end ≤ start) collapses to 0. Uses hours so day fractions never round-trip
// through an integer day count.
func dateToPct(d, start, end time.Time) float64 {
	span := end.Sub(start).Hours()
	if span <= 0 {
		return 0
	}
	return d.Sub(start).Hours() / span * 100
}

// monthsBetween counts the calendar months the [a, b] span touches, inclusive
// (Jan→Mar = 3). Drives the month-tick count when the block gives no explicit
// `months`.
func monthsBetween(a, b time.Time) int {
	m := (b.Year()*12 + int(b.Month())) - (a.Year()*12 + int(a.Month())) + 1
	if m < 1 {
		return 1
	}
	return m
}

// clampCell clamps a marker cell index into the drawable track [0, track-1].
func clampCell(i, track int) int {
	if track <= 0 {
		return -1
	}
	if i < 0 {
		return 0
	}
	if i >= track {
		return track - 1
	}
	return i
}

// monthTickCells returns the interior month-boundary cells for `months` months
// across `track` cells. The boundaries come from distributeSegments so the ticks
// sum to EXACTLY the track (no independent-rounding drift); the final boundary
// (== track, the right rail) is not a tick.
func monthTickCells(track, months int) map[int]bool {
	ticks := map[int]bool{}
	if months <= 1 || track <= 0 {
		return ticks
	}
	pos := 0
	sizes := distributeSegments(track, months)
	for k := 0; k < len(sizes)-1; k++ {
		pos += sizes[k]
		if pos > 0 && pos < track {
			ticks[pos] = true
		}
	}
	return ticks
}

// distributeSegments splits `total` cells into `n` contiguous segments whose
// sizes sum to EXACTLY total and differ by at most one cell. It walks ONE
// running boundary — boundary k lands at round(k·total/n) — so the k==n boundary
// IS total by construction and the rounding error can never accumulate. This is
// the drift-free replacement for calling pctToCell per tick, where each boundary
// rounds in isolation and the last tick can miss the end or two ticks can collide.
func distributeSegments(total, n int) []int {
	if n <= 0 || total <= 0 {
		return nil
	}
	sizes := make([]int, n)
	prev := 0
	for k := 1; k <= n; k++ {
		cur := int(math.Round(float64(k) * float64(total) / float64(n)))
		sizes[k-1] = cur - prev
		prev = cur
	}
	return sizes
}

// ── shared small helpers ─────────────────────────────────────────────────────

// unresolvedPlaceholder is the honest degrade line for a task block whose
// resolver key is absent (only a `query` reached the renderer, or the block is
// empty): a dim `[<label> — unresolved]`.
func unresolvedPlaceholder(ctx RenderCtx, label string) string {
	return ctx.Theme.Dim.Render("[" + label + " — unresolved]")
}

// priorityLabel renders a priority scalar as `P<n>`: strips non-digits, ""→drop,
// non-empty-but-no-digit→"P?" (mirrors the reader's priority_html). Priority 0
// is VALID (the highest) so "0" → "P0".
func priorityLabel(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	digits := onlyDigits(s)
	if digits == "" {
		return "P?"
	}
	return "P" + digits
}

// criteriaLabel renders the AGGREGATED criteria shape {met,total} as `m/t`, only
// when total > 0 (never "0/0"). Anything else → "".
func criteriaLabel(v any) string {
	c, ok := v.(map[string]any)
	if !ok {
		return ""
	}
	total := attrInt(c, "total", 0)
	if total <= 0 {
		return ""
	}
	return fmt.Sprintf("%d/%d", attrInt(c, "met", 0), total)
}

// onlyDigits keeps just the 0-9 runes of s.
func onlyDigits(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, s)
}

// groupRowsByPhase groups rows by their `phase` label, preserving first-seen
// order; an empty phase groups under the "" key (rendered header-less).
func groupRowsByPhase(rows []map[string]any) (order []string, byPhase map[string][]map[string]any) {
	byPhase = make(map[string][]map[string]any)
	for _, r := range rows {
		key := strings.TrimSpace(attrStr(r, "phase"))
		if _, seen := byPhase[key]; !seen {
			order = append(order, key)
		}
		byPhase[key] = append(byPhase[key], r)
	}
	return order, byPhase
}

// countRole counts rows whose status maps to the given ladder role.
func countRole(rows []map[string]any, role string) int {
	n := 0
	for _, r := range rows {
		if roleForStatus(attrStr(r, "status")) == role {
			n++
		}
	}
	return n
}

// isTruthy mirrors the reader's criterion `met` truthiness: bool true, "true",
// or a numeric 1.
func isTruthy(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case string:
		return x == "true"
	case int:
		return x == 1
	case int64:
		return x == 1
	case float64:
		return x == 1
	}
	return false
}

// clampPct clamps a 0-100 percentage.
func clampPct(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

// clampBarWidth mirrors the reader's clampf_width: at least 1, at most the room
// left of `left` (100-left) — so a bar never runs past the track's end.
func clampBarWidth(v, left float64) float64 {
	if v < 1 {
		v = 1
	}
	if room := 100 - left; v > room {
		v = room
	}
	if v < 0 {
		v = 0
	}
	return v
}

// pctToCell maps a 0-100 percentage onto a cell index within a track of `track`
// cells, clamped to [0, track].
func pctToCell(pct float64, track int) int {
	cell := int(math.Round(pct / 100 * float64(track)))
	if cell < 0 {
		return 0
	}
	if cell > track {
		return track
	}
	return cell
}

// firstLine returns the first element of a wrapped-line slice (never panics on
// an empty slice).
func firstLine(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return lines[0]
}

// runeWidth is the display width of a plain (unstyled) string.
func runeWidth(s string) int { return lipgloss.Width(s) }

// toFloat coerces a decoded JSON scalar to float64 (JSON numbers arrive as
// float64; strings / Stringer are parsed). Reports ok=false when uncoercible.
func toFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case float32:
		return float64(x), true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case string:
		if f, err := strconv.ParseFloat(strings.TrimSpace(x), 64); err == nil {
			return f, true
		}
	case fmt.Stringer:
		if f, err := strconv.ParseFloat(x.String(), 64); err == nil {
			return f, true
		}
	}
	return 0, false
}

// attrFloat reads a numeric-ish field as float64 (missing/uncoercible → 0).
func attrFloat(m map[string]any, key string) float64 {
	if m == nil {
		return 0
	}
	f, _ := toFloat(m[key])
	return f
}
