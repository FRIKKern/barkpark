package pdrender

import (
	"fmt"
	"math"
	"strconv"
	"strings"

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
		Width(clampWidth(inner)).
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
// order ready · progress · blocked · done (empty columns omitted). Where every
// lane clears MinWidth the lanes draw SIDE-BY-SIDE as bordered columns (the P9
// standard — the internal/taskboard lane look, ported into pdrender's
// import-disciplined world via joinColumns): a role-tinted rounded box per lane
// with a `glyph Label  count` header and its cards beneath. Below the per-cell
// floor the lanes STACK vertically (the verbatim fallback): each lane a
// `Label  count` header then its cards as glyph+title+meta rows. Absent snapshot
// → placeholder; empty → "No tasks yet."
type taskBoardRenderer struct{}

var boardColumns = []struct{ role, label string }{
	{"ready", "Ready"},
	{"progress", "In progress"},
	{"blocked", "Blocked"},
	{"done", "Done"},
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
	for _, col := range boardColumns {
		if rs := byRole[col.role]; len(rs) > 0 {
			lanes = append(lanes, lane{col.role, col.label, rs})
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

// ── roadmap ──────────────────────────────────────────────────────────────────
// {snapshot: [row], today?: 0-100, scale?: [str]}. row: {status, title,
// phase_row, left: 0-100, width: 0-100}. Author-positioned bars: each row is
// `label │····▓▓▓▓····│` — a fixed-width ASCII track, ▓ filled for the row's
// [left, left+width) run (colored by role via statusGlyphStyle), · elsewhere.
// Phase rows carry a bold label; an optional `scale` axis prints above; an
// optional `today` marker (┃) is overlaid in the track. This is the one bespoke
// renderer — bar math is simple and every index is clamped, so it never panics.
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

	// Optional today now-marker cell.
	todayCell := -1
	if v, ok := b.Attrs["today"]; ok {
		if f, ok := toFloat(v); ok {
			todayCell = pctToCell(clampPct(f), track)
			if todayCell >= track {
				todayCell = track - 1
			}
		}
	}

	for _, r := range rows {
		out = append(out, roadmapLane(r, ctx, labelW, track, todayCell))
	}
	return out
}

// roadmapLane draws one row: a padded (phase→bold) label, then the bordered
// track holding the author-positioned fill run and an optional today marker.
func roadmapLane(r map[string]any, ctx RenderCtx, labelW, track, todayCell int) string {
	role := roleForStatus(attrStr(r, "status"))
	title := sanitizeText(strings.TrimSpace(attrStr(r, "title")))
	label := padOrTruncate(title, labelW)
	labelStyle := ctx.Theme.Body
	if attrBool(r, "phase_row") {
		labelStyle = ctx.Theme.Body.Bold(true)
	}

	left := clampPct(attrFloat(r, "left"))
	width := clampBarWidth(attrFloat(r, "width"), left)
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

	bar := renderTrack(ctx, role, track, start, fill, todayCell)
	rail := ctx.Theme.Dim.Render("│")
	return labelStyle.Render(label) + " " + rail + bar + rail
}

// renderTrack composes the track cells, run-grouping consecutive same-class
// cells so the styled string stays compact. class: fill (role color), today
// (accent ┃), or empty (dim ·).
func renderTrack(ctx RenderCtx, role string, track, start, fill, todayCell int) string {
	roleStyle := statusGlyphStyle(ctx.Theme, role)
	todayStyle := lipgloss.NewStyle().Foreground(ctx.Theme.Accent).Bold(true)

	// classify(i): 0 empty, 1 fill, 2 today. today overlays whatever is beneath.
	classify := func(i int) int {
		if i == todayCell {
			return 2
		}
		if i >= start && i < start+fill {
			return 1
		}
		return 0
	}
	glyphOf := func(class int) string {
		switch class {
		case 1:
			return "▓"
		case 2:
			return "┃"
		default:
			return "·"
		}
	}
	styleOf := func(class int) lipgloss.Style {
		switch class {
		case 1:
			return roleStyle
		case 2:
			return todayStyle
		default:
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
