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

	// Budget the pinned NOW band so a swarm of concurrent claims can never push
	// the spine/ticker/footer off the pane: header + 2 blanks + bottom are
	// fixed, and the spine keeps at least minSpine lines.
	const minSpine = 4
	nowBudget := height - len(top) - 2 - len(bottom) - minSpine
	if nowBudget < 2 {
		nowBudget = 2 // "NOW" + one honest line, whatever the pane size
	}

	top = append(top, "")
	top = append(top, renderNowBand(b, st, width, nowBudget, now)...)
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

// renderNowBand renders the pinned claim band within maxLines, degrading
// honestly instead of overflowing: full two-line cards with breathing room →
// cards without separators → as many cards as fit plus a dim "+N more claimed"
// fold. The band never lies about how much is in flight. NOW cards are the
// FIRST cursor rows (indexes [0, len(b.Now)) — the shell's visibleRows order),
// so the card at st.Cursor wears the selection marker; a selection folded into
// the "+N more" line marks that line instead, never vanishing silently.
func renderNowBand(b Board, st UIState, width, maxLines int, now time.Time) []string {
	// Claim-forward (wave-7 D35): when nothing is claimed but ready work exists,
	// the band is NOT a dead "nothing claimed" line — it becomes the READY TO
	// CLAIM head so there is always an obvious next task to move into NOW.
	if showReadyHead(b) {
		return renderReadyHead(b, st, width, maxLines, now)
	}
	lines := []string{boldStyle.Render("NOW")}
	if len(b.Now) == 0 {
		// Both empty: no claims AND nothing ready. An honest all-clear, not a dead
		// end — there is genuinely nothing to claim. The separator is the board's
		// calm "·" (the em dash is a reading-frame glyph, not a board one).
		lines = append(lines, dimStyle.Render("   nothing ready · all clear"))
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
		// flashTitle lights line-1's title if this claim just changed; NowCard's
		// existing ansi-aware truncation carries the emphasis through width-safely.
		card := NowCard(flashTitle(t, st, now), bc[t.DocID], st.Cursor == i, width, st.Frame, now)
		// The NOW band is the ONE place real work runs, so its claim age ticks in
		// SECONDS (decision 19). NowCard builds line-1 (glyph, twin, title); render
		// rebuilds line-2 so its age reads LiveElapsed instead of the coarse
		// AgeBadge, with the lease tint (claimRole) unchanged.
		if len(card) == 2 {
			card[1] = nowCardMeta(t, bc[t.DocID], width, now)
		}
		lines = append(lines, card...)
	}
	if folded := n - shown; folded > 0 {
		sel := st.Cursor >= shown && st.Cursor < n
		lines = append(lines, dimStyle.Render(truncate(
			SelectionMarker(sel)+fmt.Sprintf("  +%d more claimed", folded), width)))
	}
	return lines
}

// renderReadyHead paints the claim-forward READY TO CLAIM band (wave-7 D35): a
// label mirroring "NOW", then the top ready tasks as single calm TaskRows (○
// ready glyph + priority meta — NO new vocabulary), then a dim, display-only
// "+K more ready" tail naming the depth behind the head. The head rows are the
// FIRST cursor stops (indexes [0, len(ReadyHead)) — the shell's visibleRows), so
// the row at st.Cursor wears the ▎ marker; c claims it and enter opens its
// detail. Over budget it shows as many rows as fit and folds the rest into the
// tail, marking the tail selected when the cursor is on a folded row (never a
// silently vanishing selection — the same honesty the NOW fold uses).
func renderReadyHead(b Board, st UIState, width, maxLines int, now time.Time) []string {
	lines := []string{boldStyle.Render("READY TO CLAIM")}
	n := len(b.ReadyHead)

	// Each ready row is one line; reserve the label + the tail line under budget.
	shown := n
	if 1+n > maxLines {
		shown = maxLines - 2 // label + fold/tail line
		if shown < 0 {
			shown = 0
		}
	}

	for i, t := range b.ReadyHead[:shown] {
		selected := st.Cursor == i
		for _, ln := range TaskRow(flashTitle(t, st, now), selected, 0, false, width, st.Frame, now) {
			lines = append(lines, ln)
		}
	}

	// The tail counts every ready task NOT shown — both the budget-folded head
	// rows and the corpus queue beyond the head — so it is honest about the depth.
	if more := b.ReadyTotal - shown; more > 0 {
		sel := st.Cursor >= shown && st.Cursor < n
		lines = append(lines, dimStyle.Render(truncate(
			SelectionMarker(sel)+fmt.Sprintf("  +%d more ready", more), width)))
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

// nowCardMeta rebuilds a NOW card's second line (worker · elapsed · criteria ·
// breadcrumb) so the claim age reads LiveElapsed's ticking seconds instead of
// NowCard's coarse AgeBadge (decision 19). It mirrors NowCard's line-2 structure
// exactly — same order, same " · " join, same width clamp, same claimRole lease
// tint, same calm criteria digits — differing ONLY in the age token.
func nowCardMeta(t Task, breadcrumb string, width int, now time.Time) string {
	var sparts []string
	add := func(p, s string) {
		if p == "" {
			return
		}
		sparts = append(sparts, s)
	}
	if t.Claim != nil {
		add(t.Claim.Worker, dimStyle.Render(t.Claim.Worker))
		if el := LiveElapsed(t.Claim.ClaimedAt, now); el != "" {
			st := roleStyle(claimRole(t.Claim.ClaimedAt, now))
			add(el, st.Render(el))
		}
	}
	if f := criteriaFraction(t.Criteria); f != "" {
		add(f, dimStyle.Render(f))
	}
	if breadcrumb != "" {
		add(breadcrumb, dimStyle.Render(breadcrumb))
	}
	styled := strings.Join(sparts, " · ")
	if disp(styled) > width-3 {
		styled = truncate(styled, width-3)
	}
	return "   " + styled
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
	// The pinned band owns the first indexes (renderNowBand marks them): the READY
	// TO CLAIM head when nothing is claimed, else the NOW cards. showReadyHead
	// gates the band identically, so this offset always matches what was painted.
	selIdx := len(b.Now)
	if showReadyHead(b) {
		selIdx = len(b.ReadyHead)
	}
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
			emit(moreLine(sr.more, sr.Depth, width))
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
// (charter D42 + wave-10 W10-B): "+K more" names the hidden remainder (head cap +
// the 24h done fold) when head-capped, else "+N done" is the terminal tally; a
// non-zero cancelled fold always trails as "· M cancelled" (never expandable —
// abandoned work never renders as a row). Depth indents the line to sit under a
// phase band's children.
func moreLine(m spineMoreInfo, depth, width int) string {
	indent := strings.Repeat(" ", childIndent+depth*2)
	var parts []string
	switch {
	case m.hidden > 0:
		parts = append(parts, fmt.Sprintf("+%d more", m.hidden+m.done))
	case m.done > 0:
		parts = append(parts, fmt.Sprintf("+%d done", m.done))
	}
	if m.cancelled > 0 {
		if len(parts) == 0 {
			parts = append(parts, fmt.Sprintf("+%d cancelled", m.cancelled))
		} else {
			parts = append(parts, fmt.Sprintf("%d cancelled", m.cancelled))
		}
	}
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
