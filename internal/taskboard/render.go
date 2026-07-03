package taskboard

import (
	"fmt"
	"strings"
	"time"
)

// ChromeInfo carries the header's repo⇄server identity. Render's signature is
// frozen by the epic charter (it takes only Board/UIState/size/clock), so this
// package-level seam is where the Bubble Tea shell injects the resolved repo,
// branch and server once at startup. Defaults are honest placeholders — the
// pane never claims to know a repo it hasn't been told about.
type ChromeInfo struct {
	RepoName string
	Branch   string
	Server   string
}

// Chrome is read by the header strip. The shell slice sets it; tests pin it.
var Chrome = ChromeInfo{RepoName: "—", Branch: "—", Server: "—"}

// childIndent is the 2-space indent under an epic header — hierarchy is glyph
// gutter + indent + weight, never a border.
const childIndent = 2

// @canonical capability:taskboard-render aka:portrait,tui,task board,glance pane doc:docs/cards/tui.md
// Render draws the whole portrait frame for a 60–100col × 100+row pane: a
// two-line header strip, the pinned NOW band, the scrolling epic spine
// (a window around st.Cursor), then a fixed event ticker + footer hint pinned
// to the bottom. It is pure — no I/O, no tea, no network — so goldens are the
// primary gate. Below 60 cols rows shed their right-meta and keep glyph+title.
func Render(b Board, st UIState, width, height int, now time.Time) string {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}

	bottom := renderTicker(b.Events, width, now)
	bottom = append(bottom, renderFooter(width))

	// The header is 2 lines, plus an optional third when the list was truncated,
	// so measure it before budgeting rather than assuming a fixed height.
	top := renderHeader(b, st, width, now)

	// Budget the pinned NOW band so a swarm of concurrent claims can never push
	// the spine/ticker/footer off the pane: header + 2 blanks + bottom are
	// fixed, and the spine keeps at least minSpine lines.
	const minSpine = 4
	nowBudget := height - len(top) - 2 - len(bottom) - minSpine
	if nowBudget < 2 {
		nowBudget = 2 // "NOW" + one honest line, whatever the pane size
	}

	top = append(top, "")
	top = append(top, renderNowBand(b, width, nowBudget, now)...)
	top = append(top, "")

	spineLines, cursorLine := flattenSpine(b, st, width, now)

	avail := height - len(top) - len(bottom)
	if avail < 1 {
		avail = 1
	}
	spine := windowSpine(spineLines, cursorLine, avail, width)
	for len(spine) < avail {
		spine = append(spine, "")
	}

	all := make([]string, 0, len(top)+len(spine)+len(bottom))
	all = append(all, top...)
	all = append(all, spine...)
	all = append(all, bottom...)
	return strings.Join(all, "\n")
}

// ── Header ───────────────────────────────────────────────────────────────────

func renderHeader(b Board, st UIState, width int, now time.Time) []string {
	// Line 1: repo (⎇ branch) ⇄ server            ● live · 2m
	left := Chrome.RepoName
	if Chrome.Branch != "" {
		left += "  ⎇ " + Chrome.Branch
	}
	left += "  ⇄ " + Chrome.Server

	glyph, word := connGlyphWord(st.Conn)
	cs := roleStyle(connRole(st.Conn))
	conn := cs.Render(glyph) + " " + dimStyle.Render(word)
	if age := AgeBadge(st.LastSync, now); age != "" {
		conn += dimStyle.Render(" · " + age)
	}
	line1 := leftRight(dimStyle.Render(left), conn, width)

	// Line 2: counts strip.
	line2 := dimStyle.Render(truncate(countsStrip(b), width))
	lines := []string{line1, line2}

	// Line 3 (only when the 1000-row list clamp truncated the corpus): an honest
	// "showing N of M" note, so a partial board never masquerades as the whole.
	if note := truncationNote(b); note != "" {
		lines = append(lines, dimStyle.Render(truncate(note, width)))
	}
	return lines
}

// countsStrip is the header's one-line queue summary. active/blocked/done come
// straight from prime's stored lifecycle counts; the READY count is computed
// from the overlaid tasks because storage never holds a "ready" count key
// (readiness is derived), and wears a "+" when the ready head was clamped.
func countsStrip(b Board) string {
	parts := []string{
		fmt.Sprintf("%d active", b.Counts["in_progress"]),
		fmt.Sprintf("%s ready", readyCountLabel(b)),
		fmt.Sprintf("%d blocked", b.Counts["blocked"]),
		fmt.Sprintf("%d done", b.Counts["done"]),
	}
	return strings.Join(parts, " · ")
}

// readyCountLabel counts every ready task the board holds — epic roots, epic
// children and orphans; a ready task is never in NOW, which is in_progress
// only. Like the neighbouring active/blocked/done numbers this is a corpus
// summary, not a visible-row count: a dormant epic's hidden children and a
// ready ROOT (a claimable parent task, shown only as a section header) still
// count, so the number agrees with what `bp task next` can actually claim. The
// prime overlay is what marks a stored open/blocked row ready, so this is the
// only honest ready number the board has. A "+" means the ready head hit the
// server clamp, so the true count is at least this many.
func readyCountLabel(b Board) string {
	n := 0
	for _, e := range b.Epics {
		if e.Root.Lifecycle == lifeReady {
			n++
		}
		for _, c := range e.Children {
			if c.Lifecycle == lifeReady {
				n++
			}
		}
	}
	for _, o := range b.Orphans {
		if o.Lifecycle == lifeReady {
			n++
		}
	}
	s := fmt.Sprintf("%d", n)
	if b.ReadyHeadClamped {
		s += "+"
	}
	return s
}

// truncationNote reports "showing N of M" when the list fetch returned fewer
// task envelopes (TaskCount) than the summed lifecycle counts say exist — i.e.
// the 1000-row clamp dropped rows. Empty when the board is whole (or has no
// counts to compare against), so it never fires on a small fixture.
func truncationNote(b Board) string {
	total := 0
	for _, v := range b.Counts {
		total += v
	}
	if b.TaskCount > 0 && total > b.TaskCount {
		return fmt.Sprintf("showing %d of %d tasks", b.TaskCount, total)
	}
	return ""
}

func connGlyphWord(c ConnState) (string, string) {
	switch c {
	case ConnLive:
		return "●", "live"
	case ConnPolling:
		return "◐", "polling"
	default:
		return "✗", "offline"
	}
}

// ── NOW band (pinned) ────────────────────────────────────────────────────────

// renderNowBand renders the pinned claim band within maxLines, degrading
// honestly instead of overflowing: full two-line cards with breathing room →
// cards without separators → as many cards as fit plus a dim "+N more claimed"
// fold. The band never lies about how much is in flight.
func renderNowBand(b Board, width, maxLines int, now time.Time) []string {
	lines := []string{boldStyle.Render("NOW")}
	if len(b.Now) == 0 {
		lines = append(lines, dimStyle.Render("   nothing claimed right now"))
		return lines
	}
	bc := epicTitleByChild(b)
	n := len(b.Now)

	// Preferred: cards separated by blank lines (1 + 3n - 1 lines).
	spaced := 3*n <= maxLines
	// Compact: cards back to back (1 + 2n lines). Over budget, show as many
	// full cards as fit and fold the rest into one honest count line.
	shown := n
	if 1+2*n > maxLines {
		shown = (maxLines - 2) / 2 // reserve the header + fold line
		if shown < 0 {
			shown = 0
		}
	}

	for i, t := range b.Now[:shown] {
		if spaced && i > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, NowCard(t, bc[t.DocID], width, now)...)
	}
	if folded := n - shown; folded > 0 {
		lines = append(lines, dimStyle.Render(truncate(
			fmt.Sprintf("   +%d more claimed", folded), width)))
	}
	return lines
}

// epicTitleByChild maps a child doc_id -> its epic's title, for NOW-card
// breadcrumbs (Task carries only ParentID, not the parent's title).
func epicTitleByChild(b Board) map[string]string {
	byParent := map[string]string{}
	for _, e := range b.Epics {
		byParent[e.Root.DocID] = e.Root.Title
	}
	out := map[string]string{}
	for _, e := range b.Epics {
		for _, c := range e.Children {
			out[c.DocID] = e.Root.Title
		}
	}
	// A NOW task may not be listed among a shown epic's children (dormant epic,
	// folded child); resolve its ParentID against the epic roots directly.
	for _, t := range b.Now {
		if _, ok := out[t.DocID]; !ok && t.ParentID != "" {
			out[t.DocID] = byParent[t.ParentID]
		}
	}
	return out
}

// ── Epic spine (scrolls) ─────────────────────────────────────────────────────

// flattenSpine renders every spine display line and reports the line index of
// the cursor-selected selectable row (task/orphan rows are selectable; epic
// headers, folded-done lines and blanks are not).
func flattenSpine(b Board, st UIState, width int, now time.Time) (lines []string, cursorLine int) {
	cursorLine = -1
	selIdx := 0
	emit := func(s string) { lines = append(lines, s) }
	emitTask := func(t Task) {
		selected := selIdx == st.Cursor
		if selected {
			cursorLine = len(lines)
		}
		expanded := st.Expanded[t.DocID]
		for _, ln := range TaskRow(t, selected, expanded, childIndent, width, now) {
			emit(ln)
		}
		selIdx++
	}

	for ei, e := range b.Epics {
		if ei > 0 {
			emit("")
		}
		emit(EpicHeader(e, width))
		collapsed := st.CollapsedEpics[e.Root.DocID]
		if e.Dormant || collapsed {
			continue
		}
		for _, c := range e.Children {
			emitTask(c)
		}
		if e.DoneFolded > 0 {
			emit(dimStyle.Render(fmt.Sprintf("  +%d done", e.DoneFolded)))
		}
	}

	if len(b.Orphans) > 0 || b.OrphansFolded > 0 {
		if len(lines) > 0 {
			emit("")
		}
		// With zero epics the whole board IS the loose queue, so "(no epic)" is
		// noise — the section reads as a plain queue title. Otherwise it names
		// the bucket the loose tasks fall into.
		title := "(no epic)"
		if len(b.Epics) == 0 {
			title = "tasks"
		}
		emit(EpicHeader(Epic{Root: Task{Title: title}}, width))
		for _, o := range b.Orphans {
			emitTask(o)
		}
		if b.OrphansFolded > 0 {
			emit(dimStyle.Render(fmt.Sprintf("  +%d done", b.OrphansFolded)))
		}
	}

	if len(lines) == 0 {
		emit(dimStyle.Render("All clear — no open tasks."))
	}
	return lines, cursorLine
}

// windowSpine clips the spine to `avail` lines, keeping the cursor line in
// view, and marks any hidden overflow with dim ↑/↓ "N more" affordances.
func windowSpine(lines []string, cursorLine, avail, width int) []string {
	if avail <= 0 {
		return nil
	}
	if len(lines) <= avail {
		return lines
	}
	start := 0
	if cursorLine >= 0 {
		start = cursorLine - avail/2
	}
	if start < 0 {
		start = 0
	}
	if start+avail > len(lines) {
		start = len(lines) - avail
	}
	win := make([]string, avail)
	copy(win, lines[start:start+avail])
	if start > 0 {
		win[0] = dimStyle.Render(truncate(fmt.Sprintf("  ↑ %d more above", start), width))
	}
	if below := len(lines) - (start + avail); below > 0 {
		win[avail-1] = dimStyle.Render(truncate(fmt.Sprintf("  ↓ %d more below", below), width))
	}
	return win
}

// ── Ticker + footer (pinned bottom) ──────────────────────────────────────────

func renderTicker(events []Event, width int, now time.Time) []string {
	lines := []string{dimStyle.Render(strings.Repeat("─", width))}
	if len(events) == 0 {
		return append(lines, dimStyle.Render("no recent activity"))
	}
	n := len(events)
	if n > 3 {
		n = 3
	}
	for _, e := range events[:n] {
		lines = append(lines, dimStyle.Render(truncate(eventSentence(e, now), width)))
	}
	return lines
}

func eventSentence(e Event, now time.Time) string {
	verb := strings.TrimPrefix(e.Mutation, "task.")
	glyph := "·"
	switch verb {
	case "closed":
		glyph = "✓"
	case "claimed":
		glyph = "▶"
	case "created":
		glyph = "○"
	case "blocked":
		glyph = "◐"
	}
	s := fmt.Sprintf("%s %s '%s'", glyph, verb, e.DocID)
	if age := AgeBadge(e.At, now); age != "" {
		s += " · " + age
	}
	return s
}

func renderFooter(width int) string {
	return dimStyle.Render(truncate("jk move · enter expand · c claim · x close · o studio", width))
}

// ── small shared helpers ─────────────────────────────────────────────────────

// leftRight right-aligns `right` against `left` within width, degrading to a
// width-safe truncation when the two cannot both fit.
func leftRight(left, right string, width int) string {
	lw, rw := disp(left), disp(right)
	if rw >= width {
		return truncate(right, width)
	}
	if lw+rw+1 > width {
		left = truncate(left, width-rw-1)
		lw = disp(left)
	}
	gap := width - lw - rw
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}
