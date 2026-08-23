package taskboard

import "time"

// hitmap.go — the mouse soul's coordinate substrate (charter wave-16, D89–D93).
// A hit map is a []LineTarget PARALLEL to the painted frame lines: entry i tells
// the mouse reducer what painted line i IS, so a click at row Y resolves to a
// cursor stop, a scroll affordance, or nothing — with NO coordinate arithmetic
// scattered through Update. It is the SECOND consumer of the ONE spine producer
// (spineRows via flattenSpine, charter D42): the painter emits lines, the hit map
// emits a target per emitted line from the SAME closures, so the two can never
// drift (the rejected bubblezone marker-injection would have been a rival
// producer — see the task brief). Everything here is pure (data → targets), so
// the parity tripwire (len(hitmap) == painted lines; spine-row targets == the
// U+258E-marked lines) golden-tests deterministically.

// LineKind classifies one painted frame line for mouse hit-testing.
type LineKind int

const (
	// LineNone is a line the mouse ignores: a blank separator, a phase band, a
	// dead-epic tombstone, a prose line inside a reading frame, or padding.
	LineNone LineKind = iota
	// LineSpineRow is a selectable cursor stop — a board row (epic/cluster/orphan
	// header, task, or "+N more" fold) or a reading-frame rail stop. CursorIndex
	// carries which stop, so a click sets the cursor to exactly that row.
	LineSpineRow
	// LineScrollUp is the "↑ N more above" affordance overwriting a scrolled
	// window's first line. A click on it scrolls up one step — never a cursor stop.
	LineScrollUp
	// LineScrollDown is the "↓ N more below" affordance overwriting a scrolled
	// window's last line. A click on it scrolls down one step — never a cursor stop.
	LineScrollDown
	// LineChrome is fixed identity/status chrome — the header strip, momentum +
	// progress, the ticker, the action strip, the footer, a reading breadcrumb.
	// The mouse never acts on it (this slice); it exists so the hit map stays a
	// 1:1 mirror of the painted frame.
	LineChrome
)

// LineTarget is the hit-map entry for ONE painted frame line. CursorIndex is the
// selectable-row index for LineSpineRow, and -1 for every other kind.
type LineTarget struct {
	Kind        LineKind
	CursorIndex int
}

// noneTarget / chromeTarget / scrollUpTarget / scrollDownTarget are the
// non-selectable singletons — a LineTarget carries no per-line payload beyond its
// kind + (-1) index, so they need not be reconstructed.
var (
	noneTarget       = LineTarget{Kind: LineNone, CursorIndex: -1}
	chromeTarget     = LineTarget{Kind: LineChrome, CursorIndex: -1}
	scrollUpTarget   = LineTarget{Kind: LineScrollUp, CursorIndex: -1}
	scrollDownTarget = LineTarget{Kind: LineScrollDown, CursorIndex: -1}
)

// HitMapFor is the board frame's hit map — the pure sibling of SpineTopFor
// (render.go), mirroring Render's layout line-for-line: the pinned identity strip
// (chrome), then the slideTop/windowSpine-clipped spine (spine rows + the ↑/↓
// scroll affordances + padding), then the fixed bottom chrome. len(HitMapFor) ==
// the number of lines Render paints at the same geometry, BY CONSTRUCTION (both
// derive avail identically), so a click Y indexes straight into it.
func HitMapFor(b Board, st UIState, width, height int, now time.Time) []LineTarget {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	identityTop := renderIdentityTop(st, width, now)
	bottom := bottomChrome(b, st, width, now)
	_, spineTargets, cursorLine := flattenSpine(b, st, width, now)

	avail := height - len(identityTop) - len(bottom)
	if avail < 1 {
		avail = 1
	}
	top := slideTop(st.SpineScroll, cursorLine, avail, len(spineTargets))
	win := windowTargets(spineTargets, top, avail)

	out := make([]LineTarget, 0, len(identityTop)+len(win)+len(bottom))
	for range identityTop {
		out = append(out, chromeTarget)
	}
	out = append(out, win...)
	for range bottom {
		out = append(out, chromeTarget)
	}
	return out
}

// windowTargets is the hit-map twin of windowSpine (render.go): it clips the
// per-line spine targets to `avail` lines from the slideTop-chosen top, stamps
// the overflow affordances (a scrolled window's first line becomes LineScrollUp,
// its last LineScrollDown — the SAME rows windowSpine overwrites with "↑/↓ N
// more"), and pads short spines with LineNone (Render pads the painted spine the
// same way). Keep the clip/pad math byte-equal to windowSpine + Render so the two
// stay a 1:1 mirror.
func windowTargets(targets []LineTarget, top, avail int) []LineTarget {
	if avail <= 0 {
		return nil
	}
	var win []LineTarget
	if len(targets) <= avail {
		win = append(win, targets...)
	} else {
		start := top
		if start < 0 {
			start = 0
		}
		if start+avail > len(targets) {
			start = len(targets) - avail
		}
		win = make([]LineTarget, avail)
		copy(win, targets[start:start+avail])
		if start > 0 {
			win[0] = scrollUpTarget
		}
		if below := len(targets) - (start + avail); below > 0 {
			win[avail-1] = scrollDownTarget
		}
	}
	for len(win) < avail {
		win = append(win, noneTarget)
	}
	return win
}

// frameHitTargets is the reading-frame hit map (FrameTask / FramePaper): the
// twin of windowFrame (compose.go). It maps each VISIBLE body line to a target —
// a rail stop's line (Stop.Line) becomes LineSpineRow carrying that stop's index,
// prose becomes LineNone — and stamps the ↑/↓ affordances on the same first/last
// rows windowFrame overwrites. It shares windowFrame's window-top producer
// (readingWindowTop, charter D42/D105) — one function, not a re-inlined copy — so
// the hit map and the paint can never drift about which body line a screen row
// shows. `avail` is the reading viewport height Compose reserves.
func frameHitTargets(body []string, stops []Stop, cursor, scroll, avail int) []LineTarget {
	if avail <= 0 {
		return nil
	}
	stopAt := make(map[int]int, len(stops))
	for i, s := range stops {
		stopAt[s.Line] = i
	}
	mk := func(bodyLine int) LineTarget {
		if idx, ok := stopAt[bodyLine]; ok {
			return LineTarget{Kind: LineSpineRow, CursorIndex: idx}
		}
		return noneTarget
	}
	if len(body) <= avail {
		out := make([]LineTarget, 0, avail)
		for bi := range body {
			out = append(out, mk(bi))
		}
		for len(out) < avail {
			out = append(out, noneTarget)
		}
		return out
	}
	top := readingWindowTop(len(body), stops, cursor, scroll, avail)
	out := make([]LineTarget, avail)
	for i := 0; i < avail; i++ {
		out[i] = mk(top + i)
	}
	if top > 0 {
		out[0] = scrollUpTarget
	}
	if below := len(body) - (top + avail); below > 0 {
		out[avail-1] = scrollDownTarget
	}
	return out
}

// composeInner is the (width, height) Compose hands composeAt — the SAME
// gutter/clamp math the shell already re-derives in boardGeometry, so the hit
// map is built against the inner surface the frame is painted on without a
// third copy of that math. It is narrow-mode only: boardGeometry's wide branch
// is guarded by m.wide, and ComposeHitMap returns nil before calling this in
// wide mode (the two-pane mouse map is ttm-s5).
func (m Model) composeInner() (int, int) {
	return m.boardGeometry()
}

// ComposeHitMap is the compose-level hit map: the ONE seam that applies ALL
// origin offsets exactly once (charter D89) so the mouse reducer does zero
// coordinate math. It mirrors Compose/composeAt: the leading blank row (LineNone,
// compose.go), then the board frame's HitMapFor OR a pushed reading frame's
// windowed body + footer (chrome; the breadcrumb row was retired). The left gutter is a
// pure X shift that never changes a row's identity — a board row's click target
// is the FULL row width — so only the Y axis is mapped here. len(ComposeHitMap)
// == len(strings.Split(m.View(), "\n")) by construction. Wide mode returns nil:
// the two-pane mouse map is ttm-s5, and the reducer no-ops on a nil map.
func (m Model) ComposeHitMap() []LineTarget {
	if m.wide {
		return nil
	}
	now := m.now()
	top := m.topFrame()

	var body []LineTarget
	if top.Kind == FrameBoard {
		bw, bh := m.composeInner()
		body = HitMapFor(m.board, m.ui, bw, bh, now)
	} else {
		width, height := m.composeInner()
		avail := height - 1 // reading footer, exactly as composeAt reserves
		if avail < 1 {
			avail = 1
		}
		docW, _ := docLayout(width)
		content, stops := m.frameContent(top, docW, now)
		body = make([]LineTarget, 0, avail+1)
		body = append(body, frameHitTargets(content, stops, top.Cursor, top.Scroll, avail)...)
		body = append(body, chromeTarget) // reading footer
	}

	out := make([]LineTarget, 0, len(body)+1)
	out = append(out, noneTarget) // the leading blank row (compose.go)
	out = append(out, body...)
	return out
}
