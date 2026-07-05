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
	// The action strip sits directly above the footer, and only when there is
	// something to say — an empty strip costs no line, so an idle board is byte
	// -identical to before this slice (the goldens stay green).
	if strip := renderActionStrip(st.Strip, width); strip != "" {
		bottom = append(bottom, strip)
	}
	bottom = append(bottom, renderFooter(width))

	// The header is 2 lines, plus an optional third when the list was truncated,
	// so measure it before budgeting rather than assuming a fixed height.
	top := renderHeader(b, st, width, now)

	// The pinned band (WHO = NOW claims + INTENT = NEXT strip) sits between the
	// header and the spine (charter wave-12 D58/D63). Budget it so a swarm of
	// concurrent claims can never push the spine/ticker/footer off the pane: header
	// + 2 blanks + bottom are fixed, and the spine keeps at least minSpine lines.
	// NOW reserves its lines FIRST; NEXT gets the remainder and folds before the
	// spine starves (NOW is last to shed). An empty NOW+NEXT collapses the band to
	// NOTHING — no labels, no blank spacers (the all-clear lives in the momentum
	// header's "0 in flight").
	const minSpine = 4
	if len(b.Now) > 0 || len(b.Next) > 0 {
		bandBudget := height - len(top) - 2 - len(bottom) - minSpine
		if bandBudget < 2 {
			bandBudget = 2 // one honest row, whatever the pane size
		}
		// Reserve NEXT its single collapse line BEFORE NOW spends the budget, so a
		// greedy NOW can never orphan a NEXT cursor stop (charter D63: NEXT folds to
		// "+N intent", it never silently vanishes while it owns rows). Under the very
		// tightest budget both bands collapse to one catch line apiece (1 NOW + 1
		// NEXT == the clamped floor), so every pinned cursor row stays markable. NOW
		// keeps the full budget whenever NEXT is empty (unchanged path).
		nowBudget := bandBudget
		if len(b.Next) > 0 {
			nowBudget = bandBudget - 1
			if nowBudget < 1 {
				nowBudget = 1
			}
		}
		nowLines := renderNowBand(b, st, width, nowBudget, now)
		nextBudget := bandBudget - len(nowLines)
		if nextBudget < 0 {
			nextBudget = 0
		}
		nextLines := renderNextBand(b, st, width, nextBudget, now)

		top = append(top, "")
		top = append(top, nowLines...)
		top = append(top, nextLines...)
		top = append(top, "")
	}

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
	line1 := headerLine1(st, width, now)

	// Line 2: the MOMENTUM header (spec §0, charter D40) — the always-on progress
	// read: the in_progress spinner + in-flight/ready/done counts (icons + color,
	// done teal), a warn "N stale" instrument, and a right-aligned overall %. Line
	// 3 is the proportional progress BAR beneath it.
	lines := []string{line1, momentumLine(b, st, width), progressBar(b, width)}

	// Line 4 (only when the 1000-row list clamp truncated the corpus): an honest
	// "showing N of M" note, so a partial board never masquerades as the whole.
	if note := truncationNote(b); note != "" {
		lines = append(lines, dimStyle.Render(truncate(note, width)))
	}
	return lines
}

// headerLine1 is the identity strip (wish Amendment 3): `barkpark · tasks` on the
// left, the connection chip `⇄ <server> ● live · 2m` on the right. Two width
// rules (charter D-A, the live-corpus fix):
//
//  1. The server is reduced to its FIRST DNS LABEL at render time —
//     "https://guerrilla.barkpark.cloud" → "guerrilla" — so the chip is short and
//     honest regardless of how the shell resolved Chrome.Server (a full URL,
//     FQDN, or host:port). Done here, not in the shell, so it is robust.
//  2. The primary label "tasks" is SACRED — it is NEVER truncated. When the strip
//     is tight the droppable brand ("barkpark · ") is shed first; only if the
//     chip still cannot coexist with the whole label does the CHIP clip (never
//     "tasks"). The old code fed left+right to leftRight, which truncates the
//     LEFT, so a long FQDN chewed "tasks" down to "tas…".
func headerLine1(st UIState, width int, now time.Time) string {
	glyph, word := connGlyphWord(st.Conn)
	if isSyncing(st) {
		// Before the very first snapshot lands we are not "polling" (which implies
		// we already hold data and are re-checking) — we are doing the first fetch.
		// Say so honestly, distinct from offline.
		word = "syncing…"
	}
	cs := roleStyle(connRole(st.Conn))
	right := dimStyle.Render("⇄ "+firstDNSLabel(Chrome.Server)) + "  " + cs.Render(glyph) + " " + dimStyle.Render(word)
	if age := AgeBadge(st.LastSync, now); age != "" {
		right += dimStyle.Render(" · " + age)
	}

	label := boldStyle.Render("tasks")
	brand := dimStyle.Render("barkpark") + dimStyle.Render(" · ")
	// Prefer brand + label + the full chip.
	if disp(brand)+disp(label)+disp(right)+1 <= width {
		return leftRight(brand+label, right, width)
	}
	// Shed the brand; keep the sacred label + the full chip.
	if disp(label)+disp(right)+1 <= width {
		return leftRight(label, right, width)
	}
	// The chip will not coexist with the whole label: clip the chip, never "tasks".
	rMax := width - disp(label) - 1
	if rMax < 1 {
		return truncate(label, width) // absurdly narrow — the final safety net
	}
	return leftRight(label, truncate(right, rMax), width)
}

// firstDNSLabel reduces a server identity to its first DNS label for the header
// chip: "https://guerrilla.barkpark.cloud" → "guerrilla", "host:4010" → "host".
// It strips any scheme, path and port, then takes the leftmost label. An IPv4
// literal (all-numeric labels) is returned WHOLE — a bare "157" first octet would
// misidentify the host — as is a single-label host (localhost) and the honest
// "—" placeholder.
func firstDNSLabel(server string) string {
	h := strings.TrimSpace(server)
	if h == "" {
		return h
	}
	if i := strings.Index(h, "://"); i >= 0 {
		h = h[i+3:]
	}
	if i := strings.IndexAny(h, "/?#"); i >= 0 {
		h = h[:i]
	}
	// An IPv6 literal wears colons of its own ([::1]:4000) — leave it whole rather
	// than butcher it on a port split; only strip a port from a bracket-free host.
	if !strings.HasPrefix(h, "[") {
		if i := strings.LastIndex(h, ":"); i >= 0 {
			h = h[:i]
		}
	}
	if h == "" {
		return strings.TrimSpace(server)
	}
	parts := strings.Split(h, ".")
	if len(parts) < 2 {
		return h // single label (localhost) or already bare
	}
	allNumeric := true
	for _, p := range parts {
		if p == "" || strings.IndexFunc(p, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
			allNumeric = false
			break
		}
	}
	if allNumeric {
		return h // IPv4 literal — the first octet alone is not the host
	}
	return parts[0]
}

// momentumLine is the spec §0 aggregate: `⟨spinner⟩ N in flight · ○ N ready ·
// ✓ N done[ · N stale]   NN%`. The spinner rides the same heartbeat frame as the
// board (D38), done is teal, the stale count (when > 0) is the warn instrument,
// and the % is right-aligned. Icons carry state; the counts stay dim.
func momentumLine(b Board, st UIState, width int) string {
	spin := infoStyle.Render(spinnerGlyph(st.Frame))
	segs := []string{
		spin + " " + dimStyle.Render(fmt.Sprintf("%d in flight", b.Counts["in_progress"])),
		readyStyle.Render("○") + " " + dimStyle.Render(fmt.Sprintf("%s ready", readyCountLabel(b))),
		doneStyle.Render("✓") + " " + dimStyle.Render(fmt.Sprintf("%d done", b.Counts["done"])),
	}
	leftPart := strings.Join(segs, dimStyle.Render(" · "))
	if b.Stale > 0 {
		leftPart += dimStyle.Render(" · ") + warnStyle.Render(fmt.Sprintf("%d stale", b.Stale))
	}
	right := boldStyle.Render(fmt.Sprintf("%d%%", progressPct(b)))
	return leftRight(leftPart, right, width)
}

// progressPct is the overall completion percentage — done / (every counted task
// EXCEPT cancelled), rounded. Cancelled work is abandoned, so it leaves both the
// numerator and the denominator (charter W10-B: the momentum header excludes
// cancelled). 0 when the corpus is empty (never a divide-by-zero).
func progressPct(b Board) int {
	total := 0
	for k, v := range b.Counts {
		if k == lifeCancelled {
			continue
		}
		total += v
	}
	if total <= 0 {
		return 0
	}
	pct := int(float64(b.Counts["done"])/float64(total)*100 + 0.5)
	if pct > 100 {
		pct = 100
	}
	return pct
}

// progressBar is the spec §0 proportional bar (charter D40): a full-width track
// filled to progressPct — teal fill (completion), dim track. "Things grow, not
// jump": the fill widens as done climbs. ANSI-stripped it reads █████░░░░░, an
// honest at-a-glance needle.
func progressBar(b Board, width int) string {
	if width < 1 {
		return ""
	}
	filled := progressPct(b) * width / 100
	if filled > width {
		filled = width
	}
	if filled < 0 {
		filled = 0
	}
	return doneStyle.Render(strings.Repeat("█", filled)) + dimStyle.Render(strings.Repeat("░", width-filled))
}

// readyCountLabel counts every ready task the board holds — epic roots, epic
// children, derived-cluster members and orphans; a ready task is never in NOW,
// which is in_progress only. Like the neighbouring active/blocked/done numbers this is a corpus
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
	for _, c := range b.Clusters {
		for _, m := range c.Tasks {
			if m.Lifecycle == lifeReady {
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

// renderNowBand renders the WHO half of the pinned band (charter wave-12 D59):
// one agent-first line per live claim, within maxLines. An empty NOW returns nil
// — NO "NOW" label, NO "nothing claimed" line: the empty band collapses and the
// all-clear lives in the momentum header's "0 in flight". NOW cards are the FIRST
// cursor rows (indexes [0, len(b.Now)) — the shell's visibleRows order), so the
// row at st.Cursor wears the selection marker; when more claims exist than fit,
// the rest fold into a dim "+N more claimed" line that CATCHES a folded-row
// selection, never vanishing silently.
func renderNowBand(b Board, st UIState, width, maxLines int, now time.Time) []string {
	if len(b.Now) == 0 {
		return nil
	}
	n := len(b.Now)
	// Fully collapsed: only one line fits (the tightest supported panes, where NEXT
	// has reserved the band's other line). Drop the "NOW" label and fold EVERY claim
	// into one dim "+N claimed" catch line that still marks a folded NOW-row cursor,
	// so no claim cursor stop is ever left unmarked (the parity floor).
	if maxLines < 2 {
		sel := st.Cursor < n
		return []string{dimStyle.Render(truncate(
			SelectionMarker(sel)+fmt.Sprintf("  +%d claimed", n), width))}
	}
	lines := []string{boldStyle.Render("NOW")}
	shown := n
	if 1+n > maxLines {
		shown = maxLines - 2 // reserve the header + fold line
		if shown < 0 {
			shown = 0
		}
	}
	for i, t := range b.Now[:shown] {
		// flashTitle lights the title if this claim just changed; NowCard's ansi-
		// aware truncation carries the emphasis through width-safely.
		lines = append(lines, NowCard(flashTitle(t, st, now), st.Cursor == i, width, st.Frame, now)...)
	}
	if folded := n - shown; folded > 0 {
		sel := st.Cursor >= shown && st.Cursor < n
		lines = append(lines, dimStyle.Render(truncate(
			SelectionMarker(sel)+fmt.Sprintf("  +%d more claimed", folded), width)))
	}
	return lines
}

// renderNextBand renders the INTENT half of the pinned band (charter wave-12
// D60): a tiny NEXT strip directly under NOW showing what the system is ABOUT to
// work on — resumables first, then the priority head of the ready queue. The
// "NEXT" label is DIM (intent is subordinate to active work; NOW's label is bold,
// so the weight difference encodes active > intent). Each row is a real cursor
// stop at indexes [len(b.Now), len(b.Now)+len(b.Next)). When the rows don't fit
// maxLines they fold to a dim "+N intent" catch line (the visual collapse of the
// folded cursor rows, NOT a separate stop). A display-only "+N ready" tail points
// at the spine below and sheds FIRST under height pressure. Empty NEXT => nil.
func renderNextBand(b Board, st UIState, width, maxLines int, now time.Time) []string {
	if len(b.Next) == 0 || maxLines < 1 {
		return nil
	}
	base := len(b.Now)
	n := len(b.Next)
	// Fully collapsed: only one line fits (the tightest supported panes). Drop the
	// "NEXT" label and fold EVERY intent row into one dim "+N intent" catch line that
	// still marks a folded NEXT-row cursor — the charter D63 guarantee that NEXT
	// sheds to "+N intent" rather than vanishing while it owns cursor stops.
	if maxLines < 2 {
		sel := st.Cursor >= base && st.Cursor < base+n
		return []string{dimStyle.Render(truncate(
			SelectionMarker(sel)+fmt.Sprintf("  +%d intent", n), width))}
	}
	lines := []string{dimStyle.Render("NEXT")}

	// Rows take priority over the display-only "+N ready" tail. Show as many rows
	// as fit under maxLines (reserving the label); fold the remainder to "+N intent".
	shown := n
	if 1+n > maxLines {
		shown = maxLines - 2 // label + fold line
		if shown < 0 {
			shown = 0
		}
	}
	for i := 0; i < shown; i++ {
		lines = append(lines, renderNextRow(b.Next[i], st.Cursor == base+i, width, now))
	}
	if folded := n - shown; folded > 0 {
		sel := st.Cursor >= base+shown && st.Cursor < base+n
		lines = append(lines, dimStyle.Render(truncate(
			SelectionMarker(sel)+fmt.Sprintf("  +%d intent", folded), width)))
	}
	// The "+N ready" tail is a display-only pointer to the ready rows in the spine
	// below (never a cursor stop, never counted in len(b.Next)). It sheds FIRST
	// under height pressure, so append it only when a spare line remains.
	if b.NextReadyMore > 0 && len(lines) < maxLines {
		lines = append(lines, dimStyle.Render(truncate(
			fmt.Sprintf("   +%d ready", b.NextReadyMore), width)))
	}
	return lines
}

// ── Motion paint (flash + live elapsed) ──────────────────────────────────────

// flashTitle lights a row's title with the one-shot flash emphasis when the
// task's last observed change is still decaying (decision 17), returning a COPY
// with a pre-styled Title (the loop value is already a copy, so the board is
// untouched). It works through the frozen TaskRow/NowCard unchanged: those
// measure the title with the ansi-aware disp/truncate (the wave-1
// styled-truncation paths), so a pre-styled title clips on its VISIBLE width and
// the chip/meta budgets stay correct. At FlashLevel 0 — a settled row, or the
// nil Flashes map of a still board — the task is returned verbatim, so an at-rest
// render is byte-identical (the aliveness budget). The one-shot is guaranteed by
// construction: the heartbeat prunes an expired entry, so a flash never persists.
func flashTitle(t Task, st UIState, now time.Time) Task {
	if lvl := FlashLevel(st.Flashes[t.DocID], now); lvl > 0 {
		t.Title = flashStyle(lvl).Render(t.Title)
	}
	return t
}

// ── Epic spine (scrolls) ─────────────────────────────────────────────────────

// flattenSpine renders every spine display line and reports the line index of
// the cursor-selected row when it lives in the spine (-1 when the cursor is on
// a pinned NOW card, which the spine window never needs to chase).
//
// It consumes the ONE ordered spine producer (spineRows, charter D42): the shell
// and the renderer read the SAME list, so the selection index space is
// structural — NOW cards occupy [0, pinned), then each spineRow that is
// Selectable consumes the next index in emission order (headers, then their
// nested children, then clusters, then orphans). Separators, "+K more" folds and
// phase sub-bands are Selectable:false and never touch the cursor. Any divergence
// is now impossible: visibleRows filters the SAME producer to its Selectable set.
func flattenSpine(b Board, st UIState, width int, now time.Time) (lines []string, cursorLine int) {
	cursorLine = -1
	// The pinned band owns the first indexes: the NOW cards (renderNowBand marks
	// them), then the NEXT intent rows (renderNextBand marks them — charter wave-12
	// D63). So the spine's first selectable row follows NOW + NEXT.
	selIdx := len(b.Now) + len(b.Next)
	emit := func(s string) { lines = append(lines, s) }
	markSel := func() bool {
		selected := selIdx == st.Cursor
		if selected {
			cursorLine = len(lines)
		}
		selIdx++
		return selected
	}
	for _, sr := range spineRows(b, st) {
		switch sr.Kind {
		case spineSep:
			emit("")
		case spineEpicHeader, spineClusterHeader, spineOrphanHeader:
			selected := markSel()
			emit(renderSectionHeader(sr.hdr.title, sr.hdr.code, sr.hdr.derived, selected, sr.hdr.counts, width))
		case spinePhaseBand:
			// A named phase band (W10-A): the SAME dotted-leader grammar as a
			// section header, indented one level under its epic, display-only (no
			// selection marker — the cursor never lands on a band).
			emit(renderSectionHeaderIndent(sr.hdr.title, sr.hdr.code, false, false, childIndent, sr.hdr.counts, width))
		case spineTask:
			selected := markSel()
			for _, ln := range TaskRow(flashTitle(sr.task, st, now), selected, sr.Depth, sr.Guide, width, st.Frame, now) {
				emit(ln)
			}
		case spineMore:
			emit(moreLine(sr.more, sr.Depth, width, markSel()))
		case spineDeadEpic:
			emit(deadEpicLine(sr.hdr.title, width))
		case spineEmpty:
			emit(dimStyle.Render(truncate(sr.text, width)))
		}
	}
	return lines, cursorLine
}

// deadEpicLine is a cancelled-root epic's tombstone (charter W10-B): one dim
// header-only line at the bottom of the board, so an abandoned initiative stops
// occupying prime space. Display-only — never a cursor stop.
func deadEpicLine(title string, width int) string {
	if strings.TrimSpace(title) == "" {
		title = "(untitled)"
	}
	return dimStyle.Render(truncate("  "+title+" · cancelled", width))
}

// moreLine folds the tail of a section behind one dim, depth-aligned line
// (charter D42 + wave-11 D50/D51): "+N more" names the focus-window remainder
// (non-done kept rows the neighborhood did not pick), "+M done" is the completion
// tally (folded regardless of age — done never floods), and a non-zero cancelled
// fold always trails as "· K cancelled" (never expandable — abandoned work never
// renders as a row). The three are DISTINCT segments, so a focus window over a
// mass-closed epic reads honestly as e.g. "+6 more · 23 done". Depth indents the
// line to sit under a phase band's children.
func moreLine(m spineMoreInfo, depth, width int, selected bool) string {
	indent := strings.Repeat(" ", childIndent+depth*2)
	if selected && len(indent) > 0 {
		indent = indent[:len(indent)-1] + SelectionMarker(true)
	}
	var parts []string
	add := func(lead string, n int, unit string) {
		if n <= 0 {
			return
		}
		if len(parts) == 0 {
			parts = append(parts, fmt.Sprintf("%s%d %s", lead, n, unit))
		} else {
			parts = append(parts, fmt.Sprintf("%d %s", n, unit))
		}
	}
	add("+", m.hidden, "more")
	add("+", m.done, "done")
	add("+", m.cancelled, "cancelled")
	if len(parts) == 0 {
		return ""
	}
	return dimStyle.Render(truncate(indent+strings.Join(parts, " · "), width))
}

// clusterDisplayName is a cluster key's display form: one proj:/area: taxonomy
// prefix stripped ("proj:sheets-parity" → "sheets-parity"); a plain-label key is
// shown verbatim. It replaces chips.go's chipText now that the hash-to-hue chip
// engine is retired.
func clusterDisplayName(key string) string {
	for _, p := range []string{labelProjPrefix, labelAreaPrefix} {
		if strings.HasPrefix(key, p) && len(key) > len(p) {
			return key[len(p):]
		}
	}
	return key
}

// isSyncing is the honest first-paint state: we are polling for the very first
// snapshot (Conn is ConnPolling, the newModel default) and none has landed yet
// (LastSync is still zero). It is DISTINCT from offline (a failed fetch) and
// from steady polling (a live board leaning on the backstop after a sync).
func isSyncing(st UIState) bool {
	return st.Conn == ConnPolling && st.LastSync.IsZero()
}

// renderActionStrip draws the one-line act-verb status directly above the
// footer, role-colored (green ok / amber warn / red danger). An empty message
// renders nothing at all — the strip only exists when it has something honest
// to report.
func renderActionStrip(s ActionStrip, width int) string {
	if s.Message == "" {
		return ""
	}
	// A message carrying a deep link ("opening https://…/task/<doc-id>") keeps
	// its load-bearing doc-id tail via a middle-out clip; every other message
	// (verb + reason) reads head-first, so it clips normally. Below ~85 cols the
	// old tail-first clip ate the doc id — the one thing an SSH user needs to
	// paste — so the link was worse than useless. The asked-for tail is the
	// final path segment ("/<doc-id>") measured, not guessed: real doc ids are
	// 36-col UUIDs, so a blind 50/50 split on a 60–70-col pane would clip the
	// id's leading chars and hand the user a lookalike that resolves to nothing.
	msg := s.Message
	if strings.Contains(msg, "://") {
		wantTail := 0
		if i := strings.LastIndex(msg, "/"); i >= 0 {
			wantTail = disp(msg[i:])
		}
		msg = truncateMiddle(msg, width, wantTail)
	} else {
		msg = truncate(msg, width)
	}
	return stripStyle(s.Role).Render(msg)
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

// renderTicker draws the fixed event tail: a rule, then ONE dim last-event line
// (the calm-board subtraction, charter D14 — the three-line ticker and its
// verb-cycling working line are retired; the queue breathes through the NOW
// band's ticking claims and flash-on-change, not a personality line). At rest
// with no events it reads the honest quiet "no recent activity"; otherwise it
// shows the single freshest event. Always exactly two lines tall.
func renderTicker(events []Event, width int, now time.Time) []string {
	lines := []string{dimStyle.Render(strings.Repeat("─", width))}
	if len(events) == 0 {
		return append(lines, dimStyle.Render("no recent activity"))
	}
	return append(lines, dimStyle.Render(truncate(eventSentence(events[0], now), width)))
}

func eventSentence(e Event, now time.Time) string {
	verb := strings.TrimPrefix(e.Mutation, "task.")
	// The ticker glyph borrows the RESULTING lifecycle's StatusGlyph, so the tail
	// reads in the same board-wide status grammar as the spine: closed→done ✓,
	// created→open ○, blocked→◐, claimed→in_progress ●.
	glyph := StatusGlyph(eventLifecycle(verb))
	s := fmt.Sprintf("%s %s '%s'", glyph, verb, e.DocID)
	if age := AgeBadge(e.At, now); age != "" {
		s += " · " + age
	}
	return s
}

// eventLifecycle maps a task.% mutation verb to the lifecycle whose StatusGlyph
// the ticker borrows. An unknown verb maps to "" → the neutral "·" glyph.
func eventLifecycle(verb string) string {
	switch verb {
	case "closed":
		return "closed"
	case "claimed":
		return "in_progress"
	case "created":
		return "open"
	case "blocked":
		return "blocked"
	default:
		return ""
	}
}

// renderFooter is the BOARD frame's one hint line (charter D18: one line per
// frame kind — the reading frames get their own hint from the compositor). `esc
// back` teaches the navigation-shell ascend now that enter descends into a
// detail frame (charter D11). A tight pane drops the word "move" (jk next to the
// other single-key verbs still reads as motion) rather than blind-truncating the
// LAST verb off the end; the trailing truncate stays as the sub-60 safety net.
func renderFooter(width int) string {
	hint := "jk move · enter open · esc back · c claim · x close · o studio"
	if disp(hint) > width {
		hint = "jk · enter open · esc back · c claim · x close · o studio"
	}
	return dimStyle.Render(truncate(hint, width))
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
