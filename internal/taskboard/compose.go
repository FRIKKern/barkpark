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
// terminal body padding). Below 56 cols the side gutter narrows to 1 to keep
// portrait real estate.
func Compose(m Model) string {
	width, height := m.width, m.height
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	g := 2
	if width < 56 {
		g = 1
	}
	body := composeAt(m, width-2*g, height-1)
	lines := strings.Split(body, "\n")
	pad := strings.Repeat(" ", g)
	var sb strings.Builder
	sb.Grow(len(body) + len(lines)*(g+1) + 1)
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

func composeAt(m Model, width, height int) string {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	now := m.now()
	top := m.topFrame()

	if !m.wide {
		// NARROW — full-frame push. The board at depth 0 is oriented by its own
		// header, so it renders whole (no redundant "tasks" breadcrumb); a pushed
		// reading frame gets the breadcrumb as its top line + a per-kind footer.
		if top.Kind == FrameBoard {
			return Render(m.board, m.ui, width, height, now)
		}
		crumb := Breadcrumb(m.stack, width)
		footer := readingFooter(width)
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
	leftLines := strings.Split(Render(m.board, m.ui, boardPaneWidth, inner, now), "\n")

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
// ascend, free-scroll prose.
func readingFooter(width int) string {
	hint := "jk move · enter open · esc back · space scroll"
	if disp(hint) > width {
		hint = "jk · enter open · esc back · space scroll"
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
	var top int
	if scroll >= 0 {
		top = scroll
	} else {
		top = followTop(len(body), stops, cursor, avail)
	}
	if top < 0 {
		top = 0
	}
	if top > len(body)-avail {
		top = len(body) - avail
	}
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
