package taskboard

// compose.go — the adaptive compositor (charter D12/D26). View() picks the mode
// from Model.wide (hysteresis is Model state, D27) and composites the
// navigation stack from the SAME pure frame renderers — a wide two-pane (board
// pinned left + stack-top right) or a narrow full-frame push. Render STAYS the
// board-frame painter (D26): in wide mode it is called at the left-pane width,
// in narrow mode at full width when the board is the stack top. This file adds
// the only new top-level seams: Compose, docLayout, and the reading-frame
// windowing. The breadcrumb row was retired (2026-08-12): the document's own
// title orients the reader, and the row returned to the panes; the Breadcrumb
// builder itself was removed (2026-08-17, D127) once no frame drew a trail.

import (
	"math"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

const (
	// boardPaneWidth keeps the original fixed-width test fixture available for
	// focused compositor tests. Real sessions use defaultDetailsPaneRatio.
	boardPaneWidth = 46
	// A fresh wide task board gives the detail pane one third of the terminal.
	defaultDetailsPaneRatio = 1.0 / 3.0
	// paneGutter2 is the breathing gap between the two wide panes.
	paneGutter2 = 2
	// wideEnter/wideExit are the ±4 hysteresis boundaries (charter D12/D27):
	// become two-pane at >=110, revert to push below 106; [106,110) holds.
	wideEnter = 110
	wideExit  = 106
	// minReadingWidth is the pathological floor for the wide right pane.
	minReadingWidth = 24
	minBoardWidth   = 24
	// maxDocWidth caps the borderless reading/preview document column. A wider
	// pane centers the capped column and the surplus becomes symmetric margin;
	// 80 columns gives task detail a little more room without turning prose into
	// an ultrawide scan.
	maxDocWidth = 80
	// scrollFollow is the Frame.Scroll sentinel for "follow the cursor stop"
	// (charter D18). A frame's zero-value Scroll is 0 — a real absolute offset
	// (the top of the frame), so a freshly opened frame shows its title, never a
	// mid-body jump onto stop 0; j/k switch the frame INTO follow mode (-1), and
	// free-scrolling all the way to the top settles on 0 instead of snapping back.
	scrollFollow = -1
)

type widePaneFocus uint8

const (
	wideFocusBoard widePaneFocus = iota
	wideFocusReader
)

// boardPaneCols returns the active split, clamped so both panes remain useful
// after any terminal resize. A fresh session gives the details pane one third
// of the full inner width; a persisted ratio replaces that default.
func (m Model) boardPaneCols(innerW int) int {
	w := m.wideBoardCols
	if w == 0 {
		ratio := m.wideDetailsRatio
		if ratio <= 0 || ratio >= 1 {
			ratio = defaultDetailsPaneRatio
		}
		detailsW := int(math.Round(float64(innerW) * ratio))
		w = innerW - paneGutter2 - detailsW
	}
	max := innerW - paneGutter2 - minReadingWidth
	if max < minBoardWidth {
		max = minBoardWidth
	}
	if w < minBoardWidth {
		w = minBoardWidth
	}
	if w > max {
		w = max
	}
	return w
}

func (m *Model) resizeWidePanes(x, innerW int) {
	if x < minBoardWidth {
		x = minBoardWidth
	}
	max := innerW - paneGutter2 - minReadingWidth
	if x > max {
		x = max
	}
	m.wideBoardCols = x
	m.wideDetailsRatio = float64(innerW-paneGutter2-x) / float64(innerW)
}

func (m Model) wideInnerWidth() int {
	_, w, _ := m.wideGeom()
	return w
}

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
		return m.boardPaneCols(width), height // left pane, full height (crumb retired)
	}
	return width, height
}

// docLayout is the ONE reading-column seam: given a pane width it returns the
// text measure the document renders at (capped at maxDocWidth) and its centered
// left margin. Paint (composeAt, previewLines), the scroll clamp (scrollPreview),
// and the mouse stop resolvers (rightPaneStopAt, ComposeHitMap) all derive the
// pair here, so line wrapping and the click hit-map can never disagree about
// where a body line falls.
func docLayout(paneW int) (contentW, leftPad int) {
	contentW = paneW
	if contentW > maxDocWidth {
		contentW = maxDocWidth
	}
	if contentW < 1 {
		contentW = 1
	}
	return contentW, (paneW - contentW) / 2
}

// renderDocPane windows a document body into a borderless, centered reading
// column. body must be rendered at docLayout's contentW.
func renderDocPane(body []string, stops []Stop, cursor, scroll, hoverStop, paneW, paneH int) []string {
	docW, pad := docLayout(paneW)
	avail := paneH
	if avail < 1 {
		avail = 1
	}
	win := windowFrame(body, stops, cursor, scroll, hoverStop, avail, docW)
	for len(win) < avail {
		win = append(win, "")
	}
	margin := strings.Repeat(" ", pad)
	out := make([]string, 0, avail)
	for _, l := range win {
		plain := strings.TrimRight(ansi.Strip(l), " ")
		if plain == "" {
			out = append(out, "")
			continue
		}
		out = append(out, margin+ansi.Truncate(l, ansi.StringWidth(plain), ""))
	}
	return out
}

// docBodyRow maps a pane row to its borderless document body-window row.
func docBodyRow(pl int) int { return pl }

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
	// derived from the stack HERE, at paint time (never stored), so the ◆ marker on
	// an entered task can never desync from the frames actually open.
	ui := m.ui
	ui.OpenTasks = openTaskRefs(m.stack)

	if !m.wide {
		// NARROW — full-frame push. The board at depth 0 is oriented by its own
		// header, so it renders whole; a pushed reading frame gets the windowed
		// document + a per-kind footer (no breadcrumb row — the document's own
		// title is the orientation).
		if top.Kind == FrameBoard {
			return Render(m.board, ui, width, height, now)
		}
		footer := readingFooter(m.ui, width)
		paneH := height - 1 // reading footer
		if paneH < 2 {
			paneH = 2
		}
		docW, _ := docLayout(width)
		body, stops := m.frameContent(top, docW, now)
		// The narrow reading frame paints the hovered rail stop (charter D99 /
		// D105, the wide right pane's twin below): mouseMotion resolves the
		// pointer through ComposeHitMap into m.ui.HoverStop, and windowFrame tints
		// that stop's body line in the accent foreground. HoverStop defaults to -1
		// (newModel; keyboard input clears it), so a pointer-free frame paints
		// nothing and the goldens stay byte-frozen.
		win := renderDocPane(body, stops, top.Cursor, top.Scroll, m.ui.HoverStop, width, paneH)
		out := make([]string, 0, paneH+1)
		out = append(out, win...)
		out = append(out, footer)
		return strings.Join(out, "\n")
	}

	// WIDE — two-pane: board pinned left, the stack-top frame right, panes at
	// full height (the breadcrumb row was retired). At depth 0 the right pane
	// PREVIEWS the board cursor-target's detail from the in-hand index (zero
	// fetch, D12).
	inner := height
	if inner < 1 {
		inner = 1
	}
	boardW := m.boardPaneCols(width)
	leftLines := strings.Split(Render(m.board, ui, boardW, inner, now), "\n")

	rightW := width - boardW - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	var rightLines []string
	if t, ok := m.hoverPreviewTask(); ok {
		// A live board-row hover PREVIEWS that task in the right pane, exactly as
		// entering it would render it — at any depth. Transient by construction:
		// the pointer leaving the board pane clears the hover (wideMouseMotion),
		// and the pane reverts to the frame/cursor content below.
		rightLines = m.previewLines(t, rightW, inner, now)
	} else if top.Kind == FrameBoard {
		if t, ok := m.taskUnderCursor(); ok {
			rightLines = m.previewLines(t, rightW, inner, now)
		} else {
			rightLines = []string{dimStyle.Render(truncate("no task selected", rightW))}
		}
	} else {
		docW, _ := docLayout(rightW)
		body, stops := m.frameContent(top, docW, now)
		// The wide reading pane paints the hovered rail stop (charter D99): a
		// board-row hover would have taken the preview branch above and cleared
		// HoverStop, so a non-negative HoverStop here always belongs to THIS frame.
		rightLines = renderDocPane(body, stops, top.Cursor, top.Scroll, m.ui.HoverStop, rightW, inner)
	}

	rows := make([]string, 0, inner)
	for i := 0; i < inner; i++ {
		var l, r string
		if i < len(leftLines) {
			l = leftLines[i]
		}
		if i < len(rightLines) {
			r = rightLines[i]
		}
		divider := "│ "
		if m.wideFocus == wideFocusReader {
			divider = " │"
		}
		if i == 0 {
			divider = "↔ "
			if m.wideFocus == wideFocusReader {
				divider = " ↔"
			}
			if m.wideDragging {
				divider = "↔↔"
			}
		}
		if r == "" {
			divider = strings.TrimRight(divider, " ")
		}
		dividerStyle := dividerRestStyle
		if m.wideDividerHover {
			dividerStyle = dividerHoverStyle
		}
		if m.wideDragging {
			dividerStyle = dividerGrabbedStyle
		}
		rows = append(rows, padTo(l, boardW)+dividerStyle.Render(divider)+r)
	}
	return strings.Join(rows, "\n")
}

// previewLines renders the wide right-pane PREVIEW of one task's detail (the
// depth-0 cursor target, or a live board-row hover at any depth), from the
// in-hand DetailIndex — NEVER a fetch, and never a paper (charter D12).
// cursor -1 means no active stop (this is a preview, not the focused frame).
// The viewport windows at the wheel-driven previewScroll while the preview
// still shows previewRef (rightPaneMouse owns the offset); any other target
// renders from the top.
func (m Model) previewLines(t Task, width, avail int, now time.Time) []string {
	scroll := 0
	if m.previewRef == t.DocID {
		scroll = m.previewScroll
	}
	docW, _ := docLayout(width)
	body, _ := RenderTaskDetail(m.previewDetail(t), ChildrenOf(m.tasks, t.DocID), -1, docW, now)
	// The depth-0 preview has NO stops (stops=nil, cursor=-1) — nothing to select,
	// nothing to hover-paint (hoverStop=-1); #4240 owns depth-0 hover.
	return renderDocPane(body, nil, -1, scroll, -1, width, avail)
}

// previewDetail is a task's preview-pane detail: the reading index's entry, or
// a thin best-effort wrap of the board row when the index has none.
func (m Model) previewDetail(t Task) TaskDetail {
	if d, has := m.details[t.DocID]; has {
		return d
	}
	return TaskDetail{Task: t}
}

// hoverPreviewTask resolves a live pointer hover on a board spine row to the
// task the wide right pane should preview — hovering a row shows it exactly as
// entering it would. A hover target that is not a task (a cluster fold key, a
// "+N more" line) previews nothing.
func (m Model) hoverPreviewTask() (Task, bool) {
	if !m.wide || m.ui.HoverTarget == "" {
		return Task{}, false
	}
	return m.taskByID(m.ui.HoverTarget)
}

// openTaskRefs marks the ONE task the user is currently inside: the DEEPEST
// FrameTask on the navigation stack. The board wears the ◆ reader-open marker on
// exactly this row (UIState.OpenTasks) — never more than one at a time, even on
// a deep trail (task → paper → child task marks only the child; the breadcrumb
// still shows the full trail). Returns nil when no task is open, so the zero
// state stays byte-identical.
func openTaskRefs(stack []Frame) map[string]bool {
	for i := len(stack) - 1; i >= 0; i-- {
		if stack[i].Kind == FrameTask && stack[i].Ref != "" {
			return map[string]bool{stack[i].Ref: true}
		}
	}
	return nil
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
// board spine uses. hoverStop is the rail stop under the mouse pointer (-1 for
// none, charter D99): its body line repaints in the accent FOREGROUND
// (hoverPaint/hoverStyle — the board's hover grammar), distinct from the cursor
// stop's ▎ bar the body already carries. hoverStop<0 paints nothing, so a
// pointer-free frame (goldens, the keyboard flow, the stop-less depth-0 preview)
// is byte-identical.
func windowFrame(body []string, stops []Stop, cursor, scroll, hoverStop, avail, width int) []string {
	if avail <= 0 {
		return nil
	}
	windowed := len(body) > avail
	var win []string
	top := 0
	if !windowed {
		win = body
	} else {
		top = readingWindowTop(len(body), stops, cursor, scroll, avail)
		win = make([]string, avail)
		copy(win, body[top:top+avail])
		if top > 0 {
			win[0] = dimStyle.Render(truncate(strings.Repeat(" ", 2)+"↑ more above", width))
		}
		if below := len(body) - (top + avail); below > 0 {
			win[avail-1] = dimStyle.Render(truncate(strings.Repeat(" ", 2)+"↓ more below", width))
		}
	}
	// Hover tint (charter D99): the stop under the pointer repaints in the accent
	// foreground — but only when its body line is inside the window and is NOT the
	// row an ↑/↓ overflow marker took (the marker owns that row).
	if hoverStop >= 0 && hoverStop < len(stops) {
		if row := stops[hoverStop].Line - top; row >= 0 && row < len(win) {
			markerTop := windowed && top > 0 && row == 0
			markerBot := windowed && len(body)-(top+avail) > 0 && row == avail-1
			if !markerTop && !markerBot {
				if !windowed {
					// win aliases the caller's body slice — copy before mutating one line.
					win = append([]string(nil), body...)
				}
				win[row] = hoverPaint(win[row])
			}
		}
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
//   - every remaining composeAt row is a pane row (the breadcrumb row was
//     retired — no dead chrome row, no Y offset), then
//   - X thresholds the pane: x<46 board, 46≤x<48 the dead gutter, x≥48 right
//     (shifted by 48). The board pane's semantics are identical to narrow — a
//     click SELECTS the row (same effect as arrowing to it), wheel steps the
//     cursor (#1878: one line, never a recenter jump).
//   - Depth 0, the right pane is the cursor task's PREVIEW: wheel scrolls
//     inside it (scrollPreview, clamped) and a click enters the previewed task
//     (enterTask — the single-open descent). Depth>0 it is the stack-top
//     reading frame: clicks resolve to a rail stop via Stop.Line + the painted
//     window offset (overflow markers skipped), wheel free-scrolls ±1 exactly
//     like space/u/d.
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
	boardW := m.boardPaneCols(innerW)

	// Screen (X,Y) → composeAt (x,y): strip the leading blank row and the gl pad.
	cx, cy := ev.X-gl, ev.Y-1
	// Motion = HOVER (ttm-s3), resolved BEFORE the pane-row early-outs so a
	// pointer leaving the panes (chrome, crumb, gutter) clears the tint instead
	// of leaving it stale.
	if ev.Action == tea.MouseActionMotion && m.wideDragging {
		m.wideDividerHover = true
		m.resizeWidePanes(cx, innerW)
		return m, nil
	}
	if ev.Action == tea.MouseActionMotion {
		return m.wideMouseMotion(cx, cy, innerW, inner, now)
	}
	if ev.Action == tea.MouseActionRelease {
		wasDragging := m.wideDragging
		m.wideDragging = false
		m.wideDividerHover = cx >= boardW && cx < boardW+paneGutter2 && cy >= 0 && cy < inner
		if wasDragging && m.wideDetailsRatio > 0 {
			saveTaskboardPreferences(m.cacheDir, taskboardPreferences{
				DetailsPaneRatio: m.wideDetailsRatio,
			})
		}
		return m, nil // the press acted; the release is not an input of its own
	}
	// Footer-verb clicks are hit-tested FIRST — the ONE wide press that must
	// survive the pendingClose clear below (mirror narrow program.go's verb-first
	// early-out): a two-step x arm/fire lives in that guard, so a verb click routes
	// through clickFooterVerb (which owns the x-exception) before anything disarms
	// it (charter D111). Genuine chrome/pane clicks miss every span, fall through,
	// and keep the documented clear.
	if ev.Button == tea.MouseButtonLeft && ev.Action == tea.MouseActionPress {
		if verb, ok := m.footerVerbAt(ev.X, ev.Y); ok {
			nm, cmd := m.clickFooterVerb(verb)
			return nm.(Model), cmd
		}
	}
	if cx < 0 || cy < 0 {
		return m, nil
	}
	// Y: every composeAt row is a pane row (crumb retired); bound-check only.
	rowmap := m.wideRowMap()
	if cy >= len(rowmap) || rowmap[cy] != rowPanes {
		return m, nil
	}
	pl := cy
	if pl >= inner {
		return m, nil
	}
	// Every press/wheel that reaches HERE is non-verb input — footer-verb clicks
	// (the sole x-exception) were already routed above — so exactly like the narrow
	// reducer it clears the transient strip and disarms the close guard.
	m.pendingClose = ""
	m.ui.Strip = ActionStrip{}
	// X: pure threshold over the assembled row.
	switch {
	case cx < boardW:
		m.wideFocus = wideFocusBoard
		return m.boardPaneMouse(ev, pl, inner, now)
	case cx < boardW+paneGutter2:
		if ev.Button == tea.MouseButtonLeft && ev.Action == tea.MouseActionPress {
			m.wideDragging = true
			m.wideDividerHover = true
		}
		return m, nil
	default:
		m.wideFocus = wideFocusReader
		return m.rightPaneMouse(ev, pl, innerW, inner, now)
	}
}

// wideMouseMotion is wide-mode hover (ttm-s3 fused into ttm-s5's router). Two
// mutually-exclusive tints, one per pane, keyed on the X threshold against the
// user-resizable divider (boardPaneCols):
//
//   - the LEFT board pane's spine rows tint through HoverTarget — the wide pane
//     shares flattenSpine's hover paint with the narrow board, so resolving the
//     row Ref is all it takes; and
//   - the RIGHT reading pane's rail stops tint through HoverStop (charter D99),
//     resolved via rightPaneStopAt — the SAME stop producer the click router
//     reads, so hover and click can never disagree. The depth-0 preview has no
//     stops, so it resolves to -1 (#4240).
//
// The target rides queueHover's settle timer (the expensive wide preview never
// renders intermediate rows); the stop tint commits change-only through
// setHoverStop (charter D95 — a cheap rail repaint needs no timer). The divider
// tracks hover directly so the ↔ affordance lights the moment the pointer
// reaches the gutter.
func (m Model) wideMouseMotion(cx, cy, innerW, inner int, now time.Time) (Model, tea.Cmd) {
	target := ""
	stop := -1
	boardW := m.boardPaneCols(innerW)
	m.wideDividerHover = cx >= boardW && cx < boardW+paneGutter2 && cy >= 0 && cy < inner
	switch {
	case cx >= 0 && cx < boardW && cy >= 0 && cy < inner:
		idTop, avail := m.wideBoardPaneAvail(inner, now)
		if idx := m.wideBoardRowIndex(cy, idTop, avail, now); idx >= 0 {
			if rows := m.visibleRows(); idx < len(rows) {
				target = rows[idx].docID
			}
		}
	case cx >= boardW+paneGutter2 && cy >= 0 && cy < inner:
		stop = m.rightPaneStopAt(cy, innerW, inner, now)
	}
	// The board footer's verbs tint on hover exactly as narrow does (charter D111 /
	// D96): footerVerbAt resolves the same span geometry the click router uses, and
	// the verb rides queueHover into HoverFooterVerb, which renderFooterSegs paints
	// with the D96 background tint (verbHoverStyle) — never an accent foreground.
	gl, _, _ := m.wideGeom()
	verb := rune(0)
	if v, ok := m.footerVerbAt(cx+gl, cy+1); ok {
		verb = v
	}
	m.ui, _ = setHoverStop(m.ui, stop)
	return m.queueHover(target, verb)
}

// paneRow is a composeAt row's vertical class in wide mode, keyed on Y alone (the
// X threshold picks the pane within a rowPanes row). wideRowMap materializes one
// entry per composeAt line so a click router addresses exactly the painted rows —
// `inner` pane rows since the breadcrumb row was retired — no more, no fewer.
type paneRow int

const (
	rowPanes paneRow = iota // a two-pane content row (board | gutter | right by X)
)

// wideRowMap is the Y hit-map: `inner` rowPanes. Its length equals composeAt's
// wide line count, the hit-map length parity the router keeps.
func (m Model) wideRowMap() []paneRow {
	_, _, inner := m.wideGeom()
	return make([]paneRow, inner) // zero value IS rowPanes
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
	inner = height // panes span the full inner height (crumb retired)
	if inner < 1 {
		inner = 1
	}
	return gl, innerW, inner
}

// boardPaneMouse routes a click/wheel that landed in the wide left board pane —
// identical semantics to the narrow board. Wheel steps the cursor one row; a
// left click targets the FULL row under it (any X in the pane), moves the cursor
// there, and activates it through the same reducer as Enter. The identity strip,
// bottom status chrome, and ↑/↓ overflow markers are not rows and no-op honestly.
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
		// A press on an ↑/↓ overflow marker steps the cursor one row toward the
		// hidden spine (moveCursor ∓1) — the SAME gesture the wheel and the narrow
		// board's LineScrollUp/Down affordances reach (program.go mouseLeftPress),
		// so the wide board's markers stop being click-dead (D119). Genuine chrome
		// and display-only lines still no-op.
		if d := m.wideBoardMarkerAt(pl, idTop, avail, now); d != 0 {
			(&m).moveCursor(d)
		}
		return m, nil // chrome, a stepped overflow marker, or a display-only line
	}
	nm, cmd := m.boardClickActivate(idx)
	return nm.(Model), cmd
}

// wideBoardMarkerAt reports whether wide left-pane row `pl` is an ↑/↓ overflow
// marker, returning the cursor delta a click on it should apply: -1 for the ↑
// more-above marker, +1 for the ↓ more-below marker, and 0 for a spine row,
// chrome, or a display-only line. It re-derives the SAME window offset
// wideBoardRowIndex resolves the row index through (flattenSpine + slideTop), so
// a marker click and the resolver's -1 marker contract can never disagree about
// which two rows are markers. These are the COUNTED board markers (a spine of N
// rows windowed to `avail`); the countless reading/preview markers live in
// rightPaneMarkerAt.
func (m Model) wideBoardMarkerAt(pl, idTop, avail int, now time.Time) int {
	if pl < idTop || pl >= idTop+avail {
		return 0 // identity / status chrome, not a spine row
	}
	winIdx := pl - idTop
	boardW := m.boardPaneCols(m.wideInnerWidth())
	spineLines, _, cursorLine := flattenSpine(m.board, m.ui, boardW, now)
	top := slideTop(m.ui.SpineScroll, cursorLine, avail, len(spineLines))
	if top > 0 && winIdx == 0 {
		return -1 // ↑ more-above marker
	}
	if len(spineLines)-(top+avail) > 0 && winIdx == avail-1 {
		return 1 // ↓ more-below marker
	}
	return 0
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
	boardW := m.boardPaneCols(m.wideInnerWidth())
	spineLines, targets, cursorLine := flattenSpine(m.board, m.ui, boardW, now)
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
	boardW := m.boardPaneCols(m.wideInnerWidth())
	idTop = len(renderIdentityTop(m.ui, boardW, now))
	bottom := len(bottomChrome(m.board, m.ui, boardW, now))
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
// depth 0 the pane is the detail PREVIEW of the cursor task: wheel scrolls
// INSIDE the preview (previewScroll, clamped to its body), and a click ENTERS
// the previewed task — the same single-open descent as activating its board
// row. At depth>0 it is the stack-top reading frame: wheel free-scrolls ±1
// (reusing freeScroll so mouse == keyboard), a click resolves to the rail stop
// on the clicked body line (overflow markers skipped), moves the cursor there,
// and descends through the same reducer as Enter.
func (m Model) rightPaneMouse(ev tea.MouseMsg, pl, innerW, inner int, now time.Time) (Model, tea.Cmd) {
	top := m.topFrame()
	if top.Kind == FrameBoard {
		t, ok := m.taskUnderCursor()
		if !ok {
			return m, nil // empty board — nothing previewed, nothing to drive
		}
		switch ev.Button {
		case tea.MouseButtonWheelUp:
			(&m).scrollPreview(t, -1, innerW, inner, now)
			return m, nil
		case tea.MouseButtonWheelDown:
			(&m).scrollPreview(t, 1, innerW, inner, now)
			return m, nil
		}
		if ev.Button == tea.MouseButtonLeft && ev.Action == tea.MouseActionPress {
			// Defuse the depth-0 booby-trap: a press on the preview's ↑/↓ overflow
			// marker scrolls the preview one notch (scrollPreview, mouse == wheel)
			// instead of ENTERING the previewed task (D121) — clicking the affordance
			// that means "there is more" must reveal the more, never descend.
			if d := m.rightPaneMarkerAt(pl, innerW, inner, now); d != 0 {
				(&m).scrollPreview(t, d, innerW, inner, now)
				return m, nil
			}
			return m.enterTask(t.DocID), nil
		}
		return m, nil
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
	if idx := m.rightPaneStopAt(pl, innerW, inner, now); idx >= 0 {
		nm, cmd := m.readingClickActivate(idx)
		return nm.(Model), cmd
	}
	// A press on the reading frame's ↑/↓ overflow marker free-scrolls ±1 (mouse ==
	// space/u/d) — the last mouse asymmetry with the narrow board, now closed
	// (D119). Prose and empty lines below still no-op.
	if d := m.rightPaneMarkerAt(pl, innerW, inner, now); d != 0 {
		(&m).freeScroll(d)
		return m, nil
	}
	return m, nil // prose / empty line — nothing to select
}

// rightPaneMarkerAt reports whether wide right-pane row `pl` is an ↑/↓ overflow
// marker, returning the scroll delta a click on it applies: -1 for ↑ more-above,
// +1 for ↓ more-below, and 0 for a body/chrome/empty line. It re-derives the SAME
// window offset the paint uses at BOTH depths — the depth-0 preview (previewLines,
// windowed at previewScroll with no stops) and the depth>0 reading frame
// (renderDocPane over frameContent) — so a marker click can never disagree with
// the painted affordance. It is the countless-marker twin of the counted
// wideBoardMarkerAt, and the deliberate complement of rightPaneStopAt: a stop row
// under the window edge is HIDDEN beneath the marker glyph, so the click router
// asks rightPaneStopAt first (a real stop wins) and only then this helper.
func (m Model) rightPaneMarkerAt(pl, innerW, inner int, now time.Time) int {
	row := docBodyRow(pl)
	if row < 0 {
		return 0
	}
	avail := inner
	if avail < 1 {
		avail = 1
	}
	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	docW, _ := docLayout(rightW)
	top := m.topFrame()
	var body []string
	var stops []Stop
	cursor, scroll := -1, 0
	if top.Kind == FrameBoard {
		t, ok := m.taskUnderCursor()
		if !ok {
			return 0 // empty board — the preview is a single dim line, no markers
		}
		// Mirror previewLines: cursor -1, and previewScroll only when the offset
		// still belongs to THIS previewed task (else the window is at the top).
		body, _ = RenderTaskDetail(m.previewDetail(t), ChildrenOf(m.tasks, t.DocID), -1, docW, now)
		if m.previewRef == t.DocID {
			scroll = m.previewScroll
		}
	} else {
		body, stops = m.frameContent(top, docW, now)
		cursor, scroll = top.Cursor, top.Scroll
	}
	if len(body) <= avail {
		return 0 // fits the window — no overflow, no markers
	}
	wtop := readingWindowTop(len(body), stops, cursor, scroll, avail)
	if wtop > 0 && row == 0 {
		return -1 // ↑ more-above marker
	}
	if len(body)-(wtop+avail) > 0 && row == avail-1 {
		return 1 // ↓ more-below marker
	}
	return 0
}

// rightPaneStopAt is the ONE reading-frame stop resolver both the click router
// (rightPaneMouse) and the hover painter (wideMouseMotion) read, so a click and a
// hover on the same wide right-pane row can never disagree about which rail stop —
// if any — sits under the pointer (charter D99). Given a pane row `pl` it returns
// the stop index on that body line, or -1 when there is nothing to select: the
// stop-less depth-0 preview (#4240), an ↑/↓ overflow-marker row, or a
// prose/gutter/empty line. It re-derives the paint's window offset
// (readingWindowTop) from the SAME geometry composeAt paints — including the
// user-resizable divider position (boardPaneCols) — so resolution and paint stay
// pixel-locked.
func (m Model) rightPaneStopAt(pl, innerW, inner int, now time.Time) int {
	top := m.topFrame()
	if top.Kind == FrameBoard {
		return -1 // depth-0 preview has no stops (previewLines passes stops=nil)
	}
	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	docW, _ := docLayout(rightW)
	body, stops := m.frameContent(top, docW, now)
	row := docBodyRow(pl)
	if row < 0 {
		return -1
	}
	avail := inner
	if avail < 1 {
		avail = 1
	}
	wtop := readingWindowTop(len(body), stops, top.Cursor, top.Scroll, avail)
	if wtop > 0 && row == 0 {
		return -1 // ↑ more-above marker
	}
	if len(body)-(wtop+avail) > 0 && row == avail-1 {
		return -1 // ↓ more-below marker
	}
	bodyLine := wtop + row
	for i, s := range stops {
		if s.Line == bodyLine {
			return i
		}
	}
	return -1 // prose / empty line — nothing to select
}

// scrollPreview moves the wide depth-0 preview viewport one wheel notch,
// clamped to the previewed task's rendered body at the SAME width/height the
// paint uses (previewLines) — the offset can never point past the detail. A
// wheel on a task other than previewRef re-seeds the offset from the top first,
// so a preview that just moved (cursor step, hover) starts at 0, not at a stale
// offset from the last task.
func (m *Model) scrollPreview(t Task, delta, innerW, inner int, now time.Time) {
	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	docW, _ := docLayout(rightW)
	body, _ := RenderTaskDetail(m.previewDetail(t), ChildrenOf(m.tasks, t.DocID), -1, docW, now)
	maxTop := len(body) - inner
	if maxTop < 0 {
		maxTop = 0
	}
	if m.previewRef != t.DocID {
		m.previewRef, m.previewScroll = t.DocID, 0
	}
	s := m.previewScroll + delta
	if s < 0 {
		s = 0
	}
	if s > maxTop {
		s = maxTop
	}
	m.previewScroll = s
}
