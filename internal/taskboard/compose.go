package taskboard

// compose.go — the adaptive compositor (charter D12/D26). View() calls Compose;
// Compose builds the breadcrumb, picks the mode from Model.wide (hysteresis is
// Model state, D27), and composites the navigation stack from the SAME pure
// frame renderers — a wide two-pane (board pinned left + stack-top right) or a
// narrow full-frame push. Render STAYS the board-frame painter (D26): in wide
// mode it is called at the 46-col left-pane width, in narrow mode at full width
// when the board is the stack top. This file adds the only new top-level seams:
// Compose, Breadcrumb, and the reading-frame windowing.

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	// boardPaneWidth is the wide-mode left board pane (charter D12).
	boardPaneWidth = 46
	// paneGutter2 is the breathing gap between the two wide panes.
	paneGutter2 = 2
	// wideEnter/wideExit are the ±4 hysteresis boundaries (charter D12/D27):
	// become two-pane at >=110, revert to push below 106; [106,110) holds.
	wideEnter = 110
	wideExit  = 106
	// minReadingWidth is the pathological floor for the wide right pane.
	minReadingWidth = 24
	// scrollFollow is the Frame.Scroll sentinel for "follow the cursor stop"
	// (charter D18). A frame's zero-value Scroll is 0 — a real absolute offset
	// (the top of the frame), so a freshly opened frame shows its title, never a
	// mid-body jump onto stop 0; j/k switch the frame INTO follow mode (-1), and
	// free-scrolling all the way to the top settles on 0 instead of snapping back.
	scrollFollow = -1
	// crumbSep is the breadcrumb separator (a chevron — the reading vocabulary,
	// allowlisted in glyph_budget_test.go's reading set).
	crumbSep = " › "
)

// Compose paints the whole frame. It is the one impure-ish shell seam (it reads
// Model), but it delegates every pixel to pure renderers, so it holds no layout
// state of its own beyond reading m.wide.
//
// The pane gets a breathing gutter here — the ONE assembly seam — so every mode
// (board, pushed reading frame, two-pane) is inset identically and the pure
// renderers stay gutter-blind: content renders at the inner width, then each
// line is shifted right and one blank row tops the frame (the design artifact's
// terminal body padding). The gutter is ASYMMETRIC on purpose: rows carry their
// own left indent (section lead + glyph column), so a symmetric inset reads
// left-heavy — the eye sees indent+gutter on the left but only the gutter to
// the right of the right-aligned meta. One structural column left, three right
// balances the perceived whitespace. Below 56 cols both shrink to keep
// portrait real estate.
func Compose(m Model) string {
	width, height := m.width, m.height
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	gl, gr := 1, 3
	if width < 56 {
		gl, gr = 1, 2
	}
	body := composeAt(m, width-gl-gr, height-1)
	lines := strings.Split(body, "\n")
	pad := strings.Repeat(" ", gl)
	var sb strings.Builder
	sb.Grow(len(body) + len(lines)*(gl+1) + 1)
	sb.WriteByte('\n')
	for i, l := range lines {
		if i > 0 {
			sb.WriteByte('\n')
		}
		if l != "" {
			sb.WriteString(pad)
			sb.WriteString(l)
		}
	}
	return sb.String()
}

// boardGeometry is the width/height composeAt hands Render for the board
// frame — Compose's gutter/clamp math re-derived in one place so Update's
// spine-scroll sync (SpineTopFor) is computed against the same surface the
// next View paints. A drift here is self-healing (Render clamps the cursor
// into view at paint time), but keep it byte-equal to Compose/composeAt.
func (m Model) boardGeometry() (int, int) {
	width, height := m.width, m.height
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	gl, gr := 1, 3
	if width < 56 {
		gl, gr = 1, 2
	}
	width, height = width-gl-gr, height-1
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	if m.wide {
		return boardPaneWidth, height - 1 // left pane, under the breadcrumb
	}
	return width, height
}

func composeAt(m Model, width, height int) string {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	now := m.now()
	top := m.topFrame()
	// The board pane reads the breadcrumb trail as render state: OpenTasks is
	// derived from the stack HERE, at paint time (never stored), so the checked
	// radio on an entered task can never desync from the frames actually open.
	ui := m.ui
	ui.OpenTasks = openTaskRefs(m.stack)

	if !m.wide {
		// NARROW — full-frame push. The board at depth 0 is oriented by its own
		// header, so it renders whole (no redundant "tasks" breadcrumb); a pushed
		// reading frame gets the breadcrumb as its top line + a per-kind footer.
		if top.Kind == FrameBoard {
			return Render(m.board, ui, width, height, now)
		}
		crumb := Breadcrumb(m.stack, width)
		footer := readingFooter(m.ui, width)
		avail := height - 2 // breadcrumb + footer
		if avail < 1 {
			avail = 1
		}
		body, stops := m.frameContent(top, width, now)
		win := windowFrame(body, stops, top.Cursor, top.Scroll, avail, width)
		for len(win) < avail {
			win = append(win, "")
		}
		out := make([]string, 0, avail+2)
		out = append(out, crumb)
		out = append(out, win...)
		out = append(out, footer)
		return strings.Join(out, "\n")
	}

	// WIDE — two-pane: board pinned left (46 cols), the stack-top frame right,
	// the breadcrumb spanning the top. At depth 0 the right pane PREVIEWS the
	// board cursor-target's detail from the in-hand index (zero fetch, D12).
	crumb := Breadcrumb(m.stack, width)
	inner := height - 1
	if inner < 1 {
		inner = 1
	}
	leftLines := strings.Split(Render(m.board, ui, boardPaneWidth, inner, now), "\n")

	rightW := width - boardPaneWidth - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	var rightLines []string
	if top.Kind == FrameBoard {
		rightLines = m.previewLines(rightW, inner, now)
	} else {
		body, stops := m.frameContent(top, rightW, now)
		rightLines = windowFrame(body, stops, top.Cursor, top.Scroll, inner, rightW)
	}

	rows := make([]string, 0, inner+1)
	rows = append(rows, crumb)
	for i := 0; i < inner; i++ {
		var l, r string
		if i < len(leftLines) {
			l = leftLines[i]
		}
		if i < len(rightLines) {
			r = rightLines[i]
		}
		rows = append(rows, padTo(l, boardPaneWidth)+strings.Repeat(" ", paneGutter2)+r)
	}
	return strings.Join(rows, "\n")
}

// previewLines renders the wide depth-0 right pane: the board cursor-target
// task's detail, from the in-hand DetailIndex — NEVER a fetch, and never a paper
// (charter D12). cursor -1 means no active stop (this is a preview, not the
// focused frame); the viewport shows the top of the detail.
func (m Model) previewLines(width, avail int, now time.Time) []string {
	t, ok := m.taskUnderCursor()
	if !ok {
		return []string{dimStyle.Render(truncate("no task selected", width))}
	}
	d, has := m.details[t.DocID]
	if !has {
		d = TaskDetail{Task: t} // thin best-effort from the board row
	}
	body, _ := RenderTaskDetail(d, ChildrenOf(m.tasks, t.DocID), -1, width, now)
	return windowFrame(body, nil, -1, 0, avail, width)
}

// Breadcrumb renders the navigation trail (charter D11/D18: always shows where
// you are), middle-truncating so the FIRST and LAST segments always survive —
// the root ("tasks") and the frame you are IN are the two you must never lose.
func Breadcrumb(stack []Frame, width int) string {
	if width < 1 {
		width = 1
	}
	segs := make([]string, 0, len(stack))
	for _, f := range stack {
		segs = append(segs, crumbSeg(f))
	}
	if len(segs) == 0 {
		return ""
	}
	full := strings.Join(segs, crumbSep)
	if disp(full) <= width {
		return dimStyle.Render(full)
	}
	// Collapse the middle to a single ellipsis, keeping first + last.
	if len(segs) > 2 {
		collapsed := []string{segs[0], "…", segs[len(segs)-1]}
		if c := strings.Join(collapsed, crumbSep); disp(c) <= width {
			return dimStyle.Render(c)
		}
		segs = collapsed
		full = strings.Join(segs, crumbSep)
	}
	// Still too wide: middle-clip, honoring the last segment (where you ARE).
	tail := disp(segs[len(segs)-1]) + disp(crumbSep)
	return dimStyle.Render(truncateMiddle(full, width, tail))
}

// openTaskRefs collects the doc_ids of every FrameTask on the navigation stack
// — the tasks the user has ENTERED and not yet escaped out of. The board wears
// the checked radio on exactly these rows (UIState.OpenTasks). Returns nil when
// none are open, so the zero state stays byte-identical. Usually one ref; a
// deeper trail (task → paper → task) checks every task on it, mirroring the
// breadcrumb.
func openTaskRefs(stack []Frame) map[string]bool {
	var refs map[string]bool
	for _, f := range stack {
		if f.Kind == FrameTask && f.Ref != "" {
			if refs == nil {
				refs = make(map[string]bool, 1)
			}
			refs[f.Ref] = true
		}
	}
	return refs
}

// crumbSeg is a frame's breadcrumb label: its Title, else "tasks" for the board,
// else its Ref, else a placeholder — never blank.
func crumbSeg(f Frame) string {
	if f.Title != "" {
		return f.Title
	}
	if f.Kind == FrameBoard {
		return "tasks"
	}
	if f.Ref != "" {
		return f.Ref
	}
	return "?"
}

// readingFooter is the pushed frames' one hint line (charter D18: one line per
// frame kind). It teaches the reading grammar: move between stops, descend,
// ascend, free-scroll prose. It OMITS the c/x/o act verbs (they follow the reader
// as keys, not clickable footer targets — charter D96); it only gains the
// mouse-mode etiquette footnote, and only when the width allows. Like the
// board footer, the footnote yields first: it compresses to the short M-toggle
// form, then sheds entirely; the nav word "move" drops before either form, and
// a footnote is appended only when the whole line still fits.
func readingFooter(st UIState, width int) string {
	hint := "jk move · enter open · esc back · space scroll"
	if disp(hint) > width {
		hint = "jk · enter open · esc back · space scroll"
	}
	for _, tail := range []string{footerEtiquette(st.MouseReleased), footerEtiquetteShort(st.MouseReleased)} {
		if disp(hint)+disp(footerSep)+disp(tail) <= width {
			hint += footerSep + tail
			break
		}
	}
	return dimStyle.Render(truncate(hint, width))
}

// windowFrame clips a reading frame's body to `avail` lines. Scroll==scrollFollow
// (-1) makes the viewport FOLLOW the cursor's stop (charter D18); Scroll>=0 is an
// absolute free-scroll offset (space/u/d, and the zero-value top-of-frame a fresh
// push opens on). Hidden overflow is marked with the same dim ↑/↓ affordances the
// board spine uses.
func windowFrame(body []string, stops []Stop, cursor, scroll, avail, width int) []string {
	if avail <= 0 {
		return nil
	}
	if len(body) <= avail {
		return body
	}
	top := readingWindowTop(len(body), stops, cursor, scroll, avail)
	win := make([]string, avail)
	copy(win, body[top:top+avail])
	if top > 0 {
		win[0] = dimStyle.Render(truncate(strings.Repeat(" ", 2)+"↑ more above", width))
	}
	if below := len(body) - (top + avail); below > 0 {
		win[avail-1] = dimStyle.Render(truncate(strings.Repeat(" ", 2)+"↓ more below", width))
	}
	return win
}

// followTop is the viewport top when following the cursor's stop line: centered
// on the stop, clamped to the body. It is the SHARED helper freeScroll seeds
// from, so cursor-follow and free-scroll never disagree about the top.
func followTop(n int, stops []Stop, cursor, avail int) int {
	if n <= avail || avail <= 0 {
		return 0
	}
	focus := 0
	if cursor >= 0 && cursor < len(stops) {
		focus = stops[cursor].Line
	}
	top := focus - avail/2
	if top < 0 {
		top = 0
	}
	if top > n-avail {
		top = n - avail
	}
	return top
}

// readingWindowTop is the viewport top windowFrame paints for a reading frame at
// (cursor, scroll) — Scroll>=0 is an absolute free-scroll offset, Scroll<0 (the
// follow sentinel) tracks the cursor stop. Extracted from windowFrame so the
// mouse router (handleWideMouse) resolves a right-pane click against the EXACT
// same offset the paint used — the two can never drift about which body line a
// screen row shows. A body that fits (bodyLen<=avail) never windows: top 0.
func readingWindowTop(bodyLen int, stops []Stop, cursor, scroll, avail int) int {
	if avail <= 0 || bodyLen <= avail {
		return 0
	}
	top := scroll
	if scroll < 0 {
		top = followTop(bodyLen, stops, cursor, avail)
	}
	if top < 0 {
		top = 0
	}
	if top > bodyLen-avail {
		top = bodyLen - avail
	}
	return top
}

// padTo pads a (possibly styled) string to exactly n display columns with
// trailing spaces, truncating on its VISIBLE width when longer — the left board
// pane must be a fixed-width column so the wide gutter + right pane align.
func padTo(s string, n int) string {
	w := disp(s)
	if w > n {
		return truncate(s, n)
	}
	if w < n {
		return s + strings.Repeat(" ", n-w)
	}
	return s
}

// ── Wide two-pane mouse routing (charter D12) ─────────────────────────────────
//
// The wide compositor assembles each row as padTo(board,46) + a 2-col gutter +
// the right pane (composeAt above), with NO pane provenance baked into the
// bytes. handleWideMouse recovers it by pure X/Y arithmetic — the SAME geometry
// Compose/composeAt paint — so a click resolves against exactly what the eye
// sees, and mouse mode never desyncs from the frame:
//
//   - the Compose gutter is stripped first (one blank top row, gl left pad), then
//   - the breadcrumb spans the top composeAt row (a dead target — the +1 crumb
//     Y offset lives here, once), then
//   - X thresholds the pane: x<46 board, 46≤x<48 the dead gutter, x≥48 right
//     (shifted by 48). The board pane's semantics are identical to narrow — a
//     click SELECTS the row (same effect as arrowing to it), wheel steps the
//     cursor (#1878: one line, never a recenter jump).
//   - Depth 0, the right pane is a non-interactive preview (cursor -1, no stops):
//     clicks AND wheel no-op honestly. Depth>0 it is the stack-top reading frame:
//     clicks resolve to a rail stop via Stop.Line + the painted window offset
//     (overflow markers skipped), wheel free-scrolls ±1 exactly like space/u/d.
//
// It touches no paint (routing only), degrades honestly (a click on chrome, the
// gutter, or empty prose is a no-op, never a crash), and leaves the keyboard flow
// untouched. Narrow-mode mouse is a separate path; this router owns wide only.
func (m Model) handleWideMouse(ev tea.MouseMsg) (Model, tea.Cmd) {
	if !m.wide {
		return m, nil
	}
	now := m.now()
	gl, innerW, inner := m.wideGeom()

	// Screen (X,Y) → composeAt (x,y): strip the leading blank row and the gl pad.
	cx, cy := ev.X-gl, ev.Y-1
	// Motion = HOVER (ttm-s3), resolved BEFORE the pane-row early-outs so a
	// pointer leaving the panes (chrome, crumb, gutter) clears the tint instead
	// of leaving it stale.
	if ev.Action == tea.MouseActionMotion {
		return m.wideMouseMotion(cx, cy, inner, now)
	}
	if ev.Action == tea.MouseActionRelease {
		return m, nil // the press acted; the release is not an input of its own
	}
	if cx < 0 || cy < 0 {
		return m, nil
	}
	// Y: the breadcrumb is composeAt row 0 (rowCrumb); pane rows start one below.
	rowmap := m.wideRowMap()
	if cy >= len(rowmap) || rowmap[cy] != rowPanes {
		return m, nil
	}
	pl := cy - 1
	if pl < 0 || pl >= inner {
		return m, nil
	}
	// Every press/wheel that reaches a pane is non-x input — exactly like the
	// narrow reducer, it clears the transient strip and disarms the close guard
	// (wide exposes no footer-verb click targets, so there is no x-exception).
	m.pendingClose = ""
	m.ui.Strip = ActionStrip{}
	// X: pure threshold over the assembled row.
	switch {
	case cx < boardPaneWidth:
		return m.boardPaneMouse(ev, pl, inner, now)
	case cx < boardPaneWidth+paneGutter2:
		return m, nil // the dead inter-pane gutter — an honest no-op
	default:
		return m.rightPaneMouse(ev, pl, innerW, inner, now)
	}
}

// wideMouseMotion is wide-mode hover (ttm-s3 fused into ttm-s5's router): only
// the left board pane's spine rows tint — the wide pane shares flattenSpine's
// hover paint with the narrow board, so resolving the row Ref is all it takes.
// The right pane's rail stops and the depth-0 preview have no hover tint (the
// same honest gap as the narrow reading frames). Change-only mutation through
// setHoverTarget stays the debounce (charter D95); anything off the board
// pane's spine rows resolves to "" and clears the tint.
func (m Model) wideMouseMotion(cx, cy, inner int, now time.Time) (Model, tea.Cmd) {
	target := ""
	if cx >= 0 && cx < boardPaneWidth && cy >= 1 && cy-1 < inner {
		idTop, avail := m.wideBoardPaneAvail(inner, now)
		if idx := m.wideBoardRowIndex(cy-1, idTop, avail, now); idx >= 0 {
			if rows := m.visibleRows(); idx < len(rows) {
				target = rows[idx].docID
			}
		}
	}
	ui, changed := setHoverTarget(m.ui, target)
	if !changed {
		return m, nil
	}
	m.ui = ui
	return m, nil
}

// paneRow is a composeAt row's vertical class in wide mode, keyed on Y alone (the
// X threshold picks the pane within a rowPanes row). wideRowMap materializes one
// entry per composeAt line so a click router addresses exactly the painted rows —
// the crumb plus `inner` pane rows — no more, no fewer.
type paneRow int

const (
	rowCrumb paneRow = iota // the breadcrumb (composeAt row 0) — never a click target
	rowPanes                // a two-pane content row (board | gutter | right by X)
)

// wideRowMap is the Y hit-map: rowCrumb at 0, then `inner` rowPanes. Its length
// equals composeAt's wide line count, the hit-map length parity the router keeps.
func (m Model) wideRowMap() []paneRow {
	_, _, inner := m.wideGeom()
	rows := make([]paneRow, 1+inner)
	for i := 1; i < len(rows); i++ {
		rows[i] = rowPanes
	}
	return rows
}

// wideGeom re-derives composeAt's wide geometry (the left gl gutter, the inner
// content width, and the pane height under the breadcrumb) so the mouse router
// and the paint agree pixel-for-pixel. Kept byte-equal to Compose/composeAt,
// INCLUDING the height chain: Compose floors at 8, spends one line on the
// leading blank row, and composeAt re-floors the remainder at 8 before
// reserving the breadcrumb — skipping that re-floor would under-count the pane
// by one row on a pathologically short (<=8-row) wide terminal.
func (m Model) wideGeom() (gl, innerW, inner int) {
	width, height := m.width, m.height
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	gl = 1
	gr := 3
	if width < 56 {
		gr = 2
	}
	innerW = width - gl - gr
	height-- // Compose's leading blank row
	if height < 8 {
		height = 8 // composeAt re-floors
	}
	inner = height - 1 // the breadcrumb row
	if inner < 1 {
		inner = 1
	}
	return gl, innerW, inner
}

// boardPaneMouse routes a click/wheel that landed in the wide left board pane —
// identical semantics to the narrow board. Wheel steps the cursor one row; a
// left click selects the FULL row under it (any X in the pane), exactly as
// arrowing to it would, and a click on the ALREADY-selected row activates it
// (activateBoard: descend a task, fold/unfold a section) — so a double-click
// opens, exactly like the narrow board. The identity strip, the bottom status
// chrome and the ↑/↓ overflow markers are not rows and no-op honestly.
func (m Model) boardPaneMouse(ev tea.MouseMsg, pl, inner int, now time.Time) (Model, tea.Cmd) {
	switch ev.Button {
	case tea.MouseButtonWheelUp:
		(&m).moveCursor(-1)
		return m, nil
	case tea.MouseButtonWheelDown:
		(&m).moveCursor(1)
		return m, nil
	}
	if ev.Button != tea.MouseButtonLeft || ev.Action != tea.MouseActionPress {
		return m, nil
	}
	// Render floors its height at 8 internally, so the painted layout is computed
	// at max(8, inner) even when a pathologically short pane clips the frame —
	// wideBoardPaneAvail mirrors that floor or the chrome/spine row boundaries
	// would drift by one there.
	idTop, avail := m.wideBoardPaneAvail(inner, now)
	idx := m.wideBoardRowIndex(pl, idTop, avail, now)
	if idx < 0 {
		return m, nil // chrome, an overflow marker, or a display-only line
	}
	if m.ui.Cursor == idx {
		return m.activateBoard(), nil
	}
	m.ui.Cursor = idx
	return m, nil
}

// wideBoardRowIndex resolves a wide left-pane row (pl, in pane coordinates, with
// the pane's identity-top height and spine window height already derived) to the
// selectable-row (cursor) index painted there, or -1 for chrome, an ↑/↓ overflow
// marker, or a display-only line. It reads flattenSpine's per-emit LineTarget
// slice — the SAME hit-map producer the narrow board resolves through (ttm-s1),
// multi-line-safe by construction — windowed by the SAME slideTop offset the
// paint used, so click, hover and keyboard cursors can never desync.
func (m Model) wideBoardRowIndex(pl, idTop, avail int, now time.Time) int {
	if pl < idTop || pl >= idTop+avail {
		return -1 // identity / status chrome, not a spine row
	}
	winIdx := pl - idTop
	spineLines, targets, cursorLine := flattenSpine(m.board, m.ui, boardPaneWidth, now)
	top := slideTop(m.ui.SpineScroll, cursorLine, avail, len(spineLines))
	if top > 0 && winIdx == 0 {
		return -1 // ↑ more-above marker
	}
	if len(spineLines)-(top+avail) > 0 && winIdx == avail-1 {
		return -1 // ↓ more-below marker
	}
	line := top + winIdx
	if line < 0 || line >= len(targets) || targets[line].Kind != LineSpineRow {
		return -1 // a separator / phase band / dead-epic line — display only
	}
	return targets[line].CursorIndex
}

// wideBoardPaneAvail derives the wide left pane's identity-top height and spine
// window height — the SAME chrome math Render uses at boardPaneWidth, including
// Render's internal 8-row floor — shared by the press and hover resolvers.
func (m Model) wideBoardPaneAvail(inner int, now time.Time) (idTop, avail int) {
	idTop = len(renderIdentityTop(m.ui, boardPaneWidth, now))
	bottom := len(bottomChrome(m.board, m.ui, boardPaneWidth, now))
	effH := inner
	if effH < 8 {
		effH = 8
	}
	avail = effH - idTop - bottom
	if avail < 1 {
		avail = 1
	}
	return idTop, avail
}

// rightPaneMouse routes a click/wheel that landed in the wide right pane. At
// depth 0 the pane is the inert detail PREVIEW (cursor -1, no stops) — clicks AND
// wheel no-op honestly. At depth>0 it is the stack-top reading frame: wheel
// free-scrolls ±1 (reusing freeScroll so mouse == keyboard), a click resolves to
// the rail stop on the clicked body line (overflow markers skipped) and selects
// it exactly as g/G/j would (viewport follows); a click on the ALREADY-selected
// stop descends onto it, exactly like enter — the narrow reading semantics.
func (m Model) rightPaneMouse(ev tea.MouseMsg, pl, innerW, inner int, now time.Time) (Model, tea.Cmd) {
	top := m.topFrame()
	if top.Kind == FrameBoard {
		return m, nil // depth-0 preview: not a frame you drive
	}
	switch ev.Button {
	case tea.MouseButtonWheelUp:
		(&m).freeScroll(-1)
		return m, nil
	case tea.MouseButtonWheelDown:
		(&m).freeScroll(1)
		return m, nil
	}
	if ev.Button != tea.MouseButtonLeft || ev.Action != tea.MouseActionPress {
		return m, nil
	}
	rightW := innerW - boardPaneWidth - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	body, stops := m.frameContent(top, rightW, now)
	wtop := readingWindowTop(len(body), stops, top.Cursor, top.Scroll, inner)
	if wtop > 0 && pl == 0 {
		return m, nil // ↑ more-above marker
	}
	if len(body)-(wtop+inner) > 0 && pl == inner-1 {
		return m, nil // ↓ more-below marker
	}
	bodyLine := wtop + pl
	for i, s := range stops {
		if s.Line == bodyLine {
			if top.Cursor == i {
				nm, cmd := m.descend()
				return nm.(Model), cmd
			}
			(&m).setTopCursor(i)
			return m, nil
		}
	}
	return m, nil // prose / empty line — nothing to select
}
