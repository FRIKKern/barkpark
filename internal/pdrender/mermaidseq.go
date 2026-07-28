package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── sequenceDiagram → responsive lifeline ladder ─────────────────────────────
//
// The brief's poster child for the shared Flex solver: participants are COLUMNS,
// time flows DOWN, and every row is just the lifelines (│ at each column centre)
// with a message shaft stamped across it. Because each row is assembled in a
// fixed-width single-cell-rune buffer and padded to ctx.Width, rectangularity is
// free for admitted text. Column positions come from the same Measure/Arrange
// divide-formula the columns/grid/board surfaces use (seqFlex). A narrow terminal,
// oversized label, or wide/zero-width glyph declines the native ladder and falls
// back to the honest complete-source box (renderSequence returns nil).

// seqFlex is the shared solver tuned for lifeline columns: a modest gutter and a
// MinWidth floor below which the boxes would collide and we degrade to folded
// source.
var seqFlex = Flex{Gutter: 2, MinWidth: 8}

// seqFlexTight is the compaction fallback (scenario heuristics): when the roomy
// solve doesn't fit — many participants, narrow terminal — the ladder shrinks
// its gutter and lets boxes go narrower before giving up to the folded-source
// box. It never clips names: complete source beats a misleading partial ladder.
var seqFlexTight = Flex{Gutter: 1, MinWidth: 6}

// renderSequence lays a parsed sequence into a participant header band + a
// message ladder. Returns nil when it can't fit cleanly at ctx.Width (caller
// keeps the folded-source box). Every returned line is exactly ctx.Width wide.
func renderSequence(s *mmSequence, ctx RenderCtx) []string {
	if s == nil || len(s.actors) < 2 {
		return nil // one lifeline isn't a diagram; degrade honestly
	}
	W := clampWidth(ctx.Width)
	n := len(s.actors)

	// Roomy solve first; compact solve before folding (the sequence ladder's rung
	// of the box-art → compact → folded-source degradation ladder).
	flex := seqFlex
	cellW, sideBySide := flex.Measure(W, n)
	if !sideBySide {
		flex = seqFlexTight
		cellW, sideBySide = flex.Measure(W, n)
	}
	if !sideBySide {
		return nil // columns would collide even compacted — folded source
	}

	// Column geometry: slot i spans [i*(cellW+gutter), +cellW); the lifeline sits
	// at the slot centre. The whole band is centered in W.
	gutter := flex.Gutter
	total := n*cellW + (n-1)*gutter
	leftPad := 0
	if total < W {
		leftPad = (W - total) / 2
	}
	xOf := make([]int, n) // absolute lifeline column per actor index
	idx := map[string]int{}
	for i, a := range s.actors {
		xOf[i] = leftPad + i*(cellW+gutter) + cellW/2
		idx[a] = i
	}

	// A native ladder is only truthful when every actor and message fits its
	// geometric slot. The ladder buffer indexes one terminal cell per rune, so
	// any wide or zero-width rune declines native placement rather than mixing
	// incompatible coordinate systems. Otherwise the caller renders the complete
	// folded source.
	actorInner := cellW - 2
	for _, actor := range s.actors {
		label := s.label[actor]
		if label == "" {
			label = actor
		}
		if s.isActor[actor] {
			label = "○ " + label
		}
		label = sanitizeText(label)
		if !singleCellRunes(label) || lipgloss.Width(label) > actorInner {
			return nil
		}
	}
	for _, message := range s.messages {
		fi, okf := idx[message.from]
		ti, okt := idx[message.to]
		if !okf || !okt || message.text == "" {
			continue
		}
		available := 0
		if fi == ti {
			available = W - xOf[fi] - 1
		} else {
			available = xOf[fi] - xOf[ti]
			if available < 0 {
				available = -available
			}
			available--
		}
		text := sanitizeText(message.text)
		if fi == ti {
			text = "↺ " + text
		}
		if !singleCellRunes(text) || available < 1 || lipgloss.Width(text) > available {
			return nil
		}
	}

	var out []string
	out = append(out, renderActorHeads(s, cellW, gutter, leftPad, W, ctx)...)
	// A breathing lifeline row under the heads.
	out = append(out, lifelineRow(xOf, W, ctx, nil))

	for _, m := range s.messages {
		fi, okf := idx[m.from]
		ti, okt := idx[m.to]
		if !okf || !okt {
			continue
		}
		out = append(out, renderMessage(m, fi, ti, xOf, cellW, W, ctx)...)
	}
	// A foot lifeline row.
	out = append(out, lifelineRow(xOf, W, ctx, nil))

	for i := range out {
		out[i] = padRight(out[i], W)
	}
	return out
}

// singleCellRunes reports whether the native sequence buffer's one-rune ==
// one-terminal-cell coordinate model is valid for s. Wide CJK/emoji and
// zero-width combining/joiner runes return false and trigger complete source.
func singleCellRunes(s string) bool {
	for _, r := range s {
		if lipgloss.Width(string(r)) != 1 {
			return false
		}
	}
	return true
}

// renderActorHeads draws each participant as a boxed column header with a ┬ tick
// where its lifeline attaches, joined side by side and centered.
func renderActorHeads(s *mmSequence, cellW, gutter, leftPad, W int, ctx RenderCtx) []string {
	n := len(s.actors)
	boxes := make([][]string, n)
	widths := make([]int, n)
	for i, a := range s.actors {
		label := s.label[a]
		if label == "" {
			label = a
		}
		boxes[i] = actorBox(sanitizeText(label), cellW, s.isActor[a], ctx)
		widths[i] = cellW
	}
	joined := joinColumns(boxes, widths, gutter)
	pad := strings.Repeat(" ", leftPad)
	for i := range joined {
		joined[i] = pad + joined[i]
	}
	return joined
}

// actorBox is one participant header: a centered, bordered box exactly cellW wide
// whose bottom border carries a ┬ at the centre column (the lifeline root). An
// `actor` (vs `participant`) is marked with a small ○ before its name.
func actorBox(label string, cellW int, isActor bool, ctx RenderCtx) []string {
	inner := cellW - 2 // border columns
	if isActor {
		label = "○ " + label
	}
	label = padOrTruncate(centerText(label, inner), inner)

	top := "┌" + strings.Repeat("─", inner) + "┐"
	// Bottom border with the lifeline tick at the centre.
	c := inner / 2
	bottomRunes := []rune("└" + strings.Repeat("─", inner) + "┘")
	bottomRunes[1+c] = '┬'
	dim := ctx.Theme.Dim
	return []string{
		dim.Render(top),
		dim.Render("│") + ctx.Theme.Body.Render(label) + dim.Render("│"),
		dim.Render(string(bottomRunes)),
	}
}

// lifelineRow is a single row showing every lifeline (│) at its column, with an
// optional overlay already stamped by the caller (nil = plain lifelines).
func lifelineRow(xOf []int, W int, ctx RenderCtx, overlay []rune) string {
	runes := overlay
	if runes == nil {
		runes = blankRow(W)
		for _, x := range xOf {
			if x >= 0 && x < W {
				runes[x] = '│'
			}
		}
	}
	return ctx.Theme.Dim.Render(strings.TrimRight(string(runes), " "))
}

// renderMessage draws one message as a label row (text over the shaft) + an arrow
// row (the shaft with an arrowhead). Self-messages collapse to a single compact
// loop row. Lifelines are stamped on every row so the ladder stays continuous.
func renderMessage(m mmMessage, fi, ti int, xOf []int, cellW, W int, ctx RenderCtx) []string {
	xf, xt := xOf[fi], xOf[ti]

	// Self-message: a compact "↺ label" hanging off the one lifeline.
	if fi == ti {
		row := blankRow(W)
		stampLifelines(row, xOf)
		txt := []rune("↺ " + sanitizeText(m.text))
		start := xf + 1
		writeRunes(row, start, txt, W)
		return []string{ctx.Theme.Dim.Render(strings.TrimRight(string(row), " "))}
	}

	rightward := xt > xf
	lo, hi := xf, xt
	if lo > hi {
		lo, hi = hi, lo
	}

	// Label row: lifelines + the message text centered over the shaft span.
	labelRow := blankRow(W)
	stampLifelines(labelRow, xOf)
	if m.text != "" {
		txt := []rune(sanitizeText(m.text))
		center := (lo + hi) / 2
		start := center - len(txt)/2
		if start <= lo {
			start = lo + 1
		}
		writeRunes(labelRow, start, txt, W)
	}

	// Arrow row: the shaft (solid ─ / dashed ╌) across the gap, crossing any
	// intermediate lifelines with ┼, an arrowhead at the target end.
	arrowRow := blankRow(W)
	stampLifelines(arrowRow, xOf)
	shaft := '─'
	if m.style == msgDashed {
		shaft = '╌'
	}
	for c := lo + 1; c < hi; c++ {
		if arrowRow[c] == '│' {
			arrowRow[c] = '┼'
		} else {
			arrowRow[c] = shaft
		}
	}
	// Origin tick: the shaft leaves the source lifeline.
	if rightward {
		arrowRow[xf] = '├'
	} else {
		arrowRow[xf] = '┤'
	}
	// Arrowhead at the target.
	head := '▶'
	if !rightward {
		head = '◀'
	}
	if m.style == msgCross {
		head = '✗'
	}
	arrowRow[xt] = head

	return []string{
		ctx.Theme.Dim.Render(strings.TrimRight(string(labelRow), " ")),
		ctx.Theme.Dim.Render(strings.TrimRight(string(arrowRow), " ")),
	}
}

// ── small buffer helpers ─────────────────────────────────────────────────────

// blankRow returns a W-wide space-filled rune buffer.
func blankRow(W int) []rune {
	r := make([]rune, W)
	for i := range r {
		r[i] = ' '
	}
	return r
}

// stampLifelines writes a │ at every lifeline column that is currently blank.
func stampLifelines(row []rune, xOf []int) {
	for _, x := range xOf {
		if x >= 0 && x < len(row) && row[x] == ' ' {
			row[x] = '│'
		}
	}
}

// writeRunes copies txt into row at start, clipped to [0,W).
func writeRunes(row []rune, start int, txt []rune, W int) {
	for i, r := range txt {
		c := start + i
		if c < 0 || c >= W {
			continue
		}
		row[c] = r
	}
}

// centerText pads s with leading spaces so it sits centered within width w (used
// before the box border is added). A too-wide s is returned unchanged (the caller
// truncates).
func centerText(s string, w int) string {
	d := lipgloss.Width(s)
	if d >= w {
		return s
	}
	left := (w - d) / 2
	return strings.Repeat(" ", left) + s
}

// truncateToWidth clips s (plain text) to at most w display columns, adding a …
// when it had to cut. w<=0 → "".
func truncateToWidth(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	return truncateANSI(s, w-1) + "…"
}
