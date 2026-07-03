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

	top := renderHeader(b, st, width, now)
	top = append(top, "")
	top = append(top, renderNowBand(b, width, now)...)
	top = append(top, "")

	bottom := renderTicker(b.Events, width, now)
	bottom = append(bottom, renderFooter(width))

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
	line2 := dimStyle.Render(truncate(countsStrip(b.Counts), width))
	return []string{line1, line2}
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

func countsStrip(counts map[string]int) string {
	get := func(k string) int { return counts[k] }
	parts := []string{
		fmt.Sprintf("%d active", get("in_progress")),
		fmt.Sprintf("%d ready", get("ready")),
		fmt.Sprintf("%d blocked", get("blocked")),
		fmt.Sprintf("%d done", get("done")),
	}
	return strings.Join(parts, " · ")
}

// ── NOW band (pinned) ────────────────────────────────────────────────────────

func renderNowBand(b Board, width int, now time.Time) []string {
	lines := []string{boldStyle.Render("NOW")}
	if len(b.Now) == 0 {
		lines = append(lines, dimStyle.Render("   nothing claimed right now"))
		return lines
	}
	bc := epicTitleByChild(b)
	for i, t := range b.Now {
		if i > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, NowCard(t, bc[t.DocID], width, now)...)
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
	// A NOW task may not be listed among a shown epic's children (e.g. folded);
	// fall back to resolving its ParentID against the epic roots.
	for _, e := range b.Epics {
		for _, c := range e.Children {
			if _, ok := out[c.DocID]; !ok {
				out[c.DocID] = byParent[c.ParentID]
			}
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

	if len(b.Orphans) > 0 {
		if len(lines) > 0 {
			emit("")
		}
		emit(EpicHeader(Epic{Root: Task{Title: "(no epic)"}}, width))
		for _, o := range b.Orphans {
			emitTask(o)
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
