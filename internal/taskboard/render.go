package taskboard

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/x/ansi"
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

// Render draws the whole portrait frame for a 60–100col × 100+row pane
// (charter Amendment 6 / D83): a one-line identity strip pinned at the very top,
// then the scrolling epic spine (a window around st.Cursor) filling the top
// region, then the slim progress bar + momentum line + keyboard footer as fixed
// bottom status chrome. The spine IS the whole cursor space (Amendment 7: the
// pinned NEXT/NOW band is retired — claims already render in place as spinner
// rows per D56, and intent is the ready rows themselves, so the band only
// duplicated the list while eating its window). It is pure — no I/O, no tea, no
// network — so goldens are the primary gate. Below 60 cols rows shed their
// right-meta and keep glyph+title.
//
// @canonical capability:taskboard-render aka:portrait,tui,task board,glance pane doc:docs/cards/tui.md
func Render(b Board, st UIState, width, height int, now time.Time) string {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}

	// FIXED TOP: the identity/title strip only (charter D85). Momentum + progress
	// descend to the bottom status chrome (D83). It is one line, always.
	identityTop := renderIdentityTop(st, width, now)

	bottom := bottomChrome(b, st, width, now)

	spineLines, _, cursorLine := flattenSpine(b, st, width, now)

	avail := height - len(identityTop) - len(bottom)
	if avail < 1 {
		avail = 1
	}
	top := slideTop(st.SpineScroll, cursorLine, avail, len(spineLines))
	spine := windowSpine(spineLines, top, avail, width)
	for len(spine) < avail {
		spine = append(spine, "")
	}

	all := make([]string, 0, len(identityTop)+len(spine)+len(bottom))
	all = append(all, identityTop...)
	all = append(all, spine...)
	all = append(all, bottom...)
	return strings.Join(all, "\n")
}

// bottomChrome is deliberately only THREE lines: one slim progress bar, the
// status totals the operator values most, then keyboard help. A transient action message
// replaces (rather than expands) the keyboard line, so feedback never steals
// another row from the task list. Shared by Render and SpineTopFor so scrolling
// and paint use identical geometry.
func bottomChrome(b Board, st UIState, width int, _ time.Time) []string {
	chrome := renderStatusFooter(b, st, width)
	if strip := renderActionStrip(st.Strip, width); strip != "" {
		return append(chrome, strip)
	}
	return append(chrome, renderFooter(st, width))
}

// SpineTopFor reports the spine viewport top Render will paint for this state
// at this geometry: the minimal slide from st.SpineScroll that keeps the
// cursor line in view. The shell persists the result back into
// UIState.SpineScroll after every update (Amendment 8 — scroll 1:1, never a
// re-centering jump), and Render recomputes the same value at paint time, so
// the two agree and Render stays pure.
func SpineTopFor(b Board, st UIState, width, height int, now time.Time) int {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	lines, _, cursorLine := flattenSpine(b, st, width, now)
	avail := height - len(renderIdentityTop(st, width, now)) - len(bottomChrome(b, st, width, now))
	if avail < 1 {
		avail = 1
	}
	return slideTop(st.SpineScroll, cursorLine, avail, len(lines))
}

// slideTop slides a remembered viewport top the MINIMUM needed to keep the
// cursor line visible (Amendment 8): while the cursor walks inside the window
// the top does not move at all — the list holds still — and at an edge it
// follows 1:1 with the cursor's line movement. A one-line margin keeps the
// cursor clear of the ↑/↓ "more" affordances that overwrite a scrolled
// window's first/last line (collapsed in pathologically short viewports). A
// cursorLine of -1 (no cursor in this body) just clamps the remembered top.
func slideTop(prev, cursorLine, avail, n int) int {
	if avail <= 0 || n <= avail {
		return 0
	}
	maxTop := n - avail
	top := prev
	if top < 0 {
		top = 0
	}
	if top > maxTop {
		top = maxTop
	}
	if cursorLine < 0 {
		return top
	}
	margin := 1
	if avail < 4 {
		margin = 0
	}
	lo := top
	if top > 0 {
		lo = top + margin
	}
	hi := top + avail - 1
	if top < maxTop {
		hi = top + avail - 1 - margin
	}
	switch {
	case cursorLine < lo:
		top = cursorLine - margin
		if top < 0 {
			top = 0
		}
	case cursorLine > hi:
		top = cursorLine + margin - (avail - 1)
		if top > maxTop {
			top = maxTop
		}
	}
	return top
}

// ── Header (split: identity pinned top, momentum+progress relocated bottom) ───

// renderIdentityTop is the pinned title strip (charter D85): the identity line
// ONLY — "barkpark · tasks · ⇄ host · ● live · 2m". It answers "what am I looking
// at / is it live", is ORIENTATION not activity, so it stays pinned at the very
// top and never scrolls. The momentum line, the progress bar and the truncation
// note (all live status/activity readouts) descend to the bottom status chrome
// (charter D83). Always exactly one line.
func renderIdentityTop(st UIState, width int, now time.Time) []string {
	return []string{headerLine1(st, width, now)}
}

// renderStatusFooter is the relocated header block (charter D83): the
// proportional one-line progress BAR followed by the MOMENTUM line (spec §0,
// D40 — spinner + in-flight/ready/done counts + right-aligned %). Corpus truncation and
// activity prose are intentionally omitted here: the status totals already use
// authoritative counts, and the task list benefits more from those recovered
// rows. Never sheddable (D87).
func renderStatusFooter(b Board, st UIState, width int) []string {
	return []string{progressBar(b, width), momentumLine(b, st, width)}
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
	if st.ConnProblem != "" {
		word = st.ConnProblem
	}
	if isSyncing(st) {
		// Before the very first snapshot lands we are not "polling" (which implies
		// we already hold data and are re-checking) — we are doing the first fetch.
		// Say so honestly, distinct from offline.
		word = "syncing…"
	}
	// The keyset poll's visible slow state wins the chip, because it is the most
	// specific true thing about what the board is doing RIGHT NOW: it is not
	// polling, not offline, not syncing — it is deliberately waiting, and it can
	// say until when. Without the retry time this reads as "stuck"; with it, the
	// operator can see the schedule and decide whether to press r.
	if st.Paused {
		word = pausedLabel
		if !st.RetryAt.IsZero() {
			word += " · retry " + retryIn(st.RetryAt, now)
		}
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
// ✓ N done[ · N/M criteria][ · N stale][ · showing N of M]   NN%`. The spinner
// rides the same heartbeat frame as the board (D38), done is teal, the criteria
// tally counts the corpus's acceptance criteria (charter D11 — momentum at
// criterion granularity, not just tasks; absent when the corpus has none), the
// stale count (when > 0) is the warn instrument, the "showing N of M" note
// (charter D40) discloses the 1000-row list clamp when the fetch is short of the
// true corpus total, and the % is right-aligned. Icons carry state; the counts
// stay dim. On a tight pane the criteria segment sheds first, then the showing
// note — the task counts + % are the primary instruments and must never be
// mid-token truncated to make room for either richer segment.
func momentumLine(b Board, st UIState, width int) string {
	spin := infoStyle.Render(spinnerGlyph(st.Frame))
	segs := []string{
		spin + " " + dimStyle.Render(fmt.Sprintf("%d in flight", b.Counts["in_progress"])),
		readyStyle.Render("○") + " " + dimStyle.Render(fmt.Sprintf("%s ready", readyCountLabel(b))),
		doneStyle.Render("✓") + " " + dimStyle.Render(fmt.Sprintf("%d done", b.Counts["done"])),
	}
	right := boldStyle.Render(fmt.Sprintf("%d%%", progressPct(b)))
	// showing N of M: the 1000-row list-clamp horizon (charter D40 / D113a). The
	// fetch returned TaskCount envelopes; the summed lifecycle Counts are the true
	// corpus total the server reports. When the fetch falls short of the corpus
	// the board is a partial queue, so it says so — dim, and on its own shed rung
	// so it drops WHOLE (never a mid-token clip) rather than let the disclosure be
	// half-truncated. Equal (or a zero fetch) means nothing was clamped: silent.
	showing := ""
	if total := summedLifecycleCounts(b); b.TaskCount > 0 && b.TaskCount < total {
		showing = dimStyle.Render(fmt.Sprintf("showing %d of %d", b.TaskCount, total))
	}
	assemble := func(withCriteria, withShowing bool) string {
		parts := segs
		if withCriteria && b.CriteriaTotal > 0 {
			parts = append(append([]string{}, segs...),
				dimStyle.Render(fmt.Sprintf("%d/%d criteria", b.CriteriaMet, b.CriteriaTotal)))
		}
		left := strings.Join(parts, dimStyle.Render(" · "))
		if b.Stale > 0 {
			left += dimStyle.Render(" · ") + warnStyle.Render(fmt.Sprintf("%d stale", b.Stale))
		}
		if withShowing && showing != "" {
			left += dimStyle.Render(" · ") + showing
		}
		return left
	}
	// Narrowing sheds one whole rung at a time: the criteria tally first (the
	// richest, least load-bearing instrument), then the showing note drops WHOLE
	// — the task counts + % are the primary instruments and are never mid-token
	// truncated to keep either optional segment.
	leftPart := assemble(true, true)
	if disp(leftPart)+disp(right)+1 > width {
		leftPart = assemble(false, true) // shed the criteria tally
	}
	if disp(leftPart)+disp(right)+1 > width {
		leftPart = assemble(false, false) // shed the showing note whole
	}
	return leftRight(leftPart, right, width)
}

// summedLifecycleCounts is the true corpus total — every lifecycle bucket the
// server reported, cancelled included. TaskCount counts every fetched envelope
// regardless of lifecycle, so the "showing N of M" disclosure's denominator (the
// M) must sum the same way, or the note would compare unlike populations.
func summedLifecycleCounts(b Board) int {
	total := 0
	for _, v := range b.Counts {
		total += v
	}
	return total
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

// progressBar is the spec §0 proportional bar (charter D40): a full-width,
// bottom-aligned half-height fill over a thin track. The unused upper half of
// the row gives the task list breathing room without consuming another line.
// "Things grow, not jump": the teal fill widens as done climbs.
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
	return doneStyle.Render(strings.Repeat("▄", filled)) + dimStyle.Render(strings.Repeat("▁", width-filled))
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

// ── Hover paint (pointer-hover row highlight) ────────────────────────────────

// hoverPaint restyles one selectable spine row as the pointer-hover highlight,
// on the chat TUI's Phases-pane selection grammar: the row's own lifecycle /
// priority hues are stripped and the whole line re-renders in the bold accent
// foreground (hoverStyle) — no background bar, no pad, and sibling rows keep
// full brightness. Styling only: the ansi-stripped text is byte-identical.
//
// HONEST DEGRADE: under a profile with no color (Ascii — a terminal that can't
// style, or the test runner's default) neither the row nor hoverStyle emits any
// SGR, so the restyle is the identity. A board without mouse reporting loses
// nothing.
func hoverPaint(line string) string {
	return hoverStyle.Render(ansi.Strip(line))
}

// ── Epic spine (scrolls) ─────────────────────────────────────────────────────

// flattenSpine renders every spine display line and reports the line index of
// the cursor-selected row.
//
// It consumes the ONE ordered spine producer (spineRows, charter D42): the shell
// and the renderer read the SAME list, so the selection index space is
// structural. The spine IS the whole cursor space (Amendment 7 — the pinned
// NEXT/NOW band is retired): each spineRow that is Selectable consumes the next
// index in emission order (headers, then their nested children, then clusters,
// then orphans). Separators, "+K more" folds and phase sub-bands are
// Selectable:false and never touch the cursor. Any divergence is impossible:
// visibleRows filters the SAME producer to its Selectable set.
func flattenSpine(b Board, st UIState, width int, now time.Time) (lines []string, targets []LineTarget, cursorLine int) {
	cursorLine = -1
	selIdx := 0
	// emit records ONE painted line together with its mouse hit-target, so the
	// hit map (HitMapFor) is built from the SAME closures as the paint and can
	// never drift (charter D42 — one producer, two consumers). Recording is
	// PER-EMIT, not per-row: a spineTask that grows to multiple lines (NOW cards,
	// future multi-line rows) tags EACH of its lines with the row's cursor index.
	emit := func(s string, tgt LineTarget) {
		lines = append(lines, s)
		targets = append(targets, tgt)
	}
	// markSel advances the selectable-row index and reports both whether this row
	// is the cursor row (for the ▎ marker) and the index itself (for the target's
	// CursorIndex). It stamps cursorLine at the row's FIRST line — the same line
	// SpineTopFor slides into view.
	markSel := func() (selected bool, idx int) {
		idx = selIdx
		selected = selIdx == st.Cursor
		if selected {
			cursorLine = len(lines)
		}
		selIdx++
		return selected, idx
	}
	rows := spineRows(b, st)
	for _, sr := range rows {
		// The hovered SELECTABLE row restyles to the accent foreground (charter
		// D94/D95 — a non-selectable Ref, e.g. a dead-epic tombstone, never
		// hovers); every other row is untouched, at full brightness. With no live
		// target paint() is the identity and the frame is byte-identical
		// (goldens, the no-mouse board, keyboard flow).
		hovered := st.HoverTarget != "" && sr.Selectable && sr.Ref == st.HoverTarget
		paint := func(s string) string {
			if hovered {
				return hoverPaint(s)
			}
			return s
		}
		switch sr.Kind {
		case spineSep:
			emit("", noneTarget)
		case spineEpicHeader, spineClusterHeader, spineOrphanHeader:
			selected, idx := markSel()
			emit(paint(renderSectionHeader(sr.hdr.title, sr.hdr.code, sr.hdr.derived, selected, sr.hdr.counts, width)),
				LineTarget{Kind: LineSpineRow, CursorIndex: idx})
		case spinePhaseBand:
			// A named phase band (W10-A): the SAME dotted-leader grammar as a
			// section header, indented one level under its epic, display-only (no
			// selection marker — the cursor never lands on a band).
			emit(renderSectionHeaderIndent(sr.hdr.title, sr.hdr.code, false, false, childIndent, sr.hdr.counts, width),
				noneTarget)
		case spineTask:
			selected, idx := markSel()
			tgt := LineTarget{Kind: LineSpineRow, CursorIndex: idx}
			for _, ln := range taskRowWithOutline(flashTitle(sr.task, st, now), selected, st.OpenTasks[sr.Ref], sr.Outline, width, st.Frame, now) {
				emit(paint(ln), tgt)
			}
		case spineMore:
			selected, idx := markSel()
			emit(paint(moreLine(sr.more, sr.Depth, width, selected)),
				LineTarget{Kind: LineSpineRow, CursorIndex: idx})
		case spineDeadEpic:
			emit(deadEpicLine(sr.hdr.title, width), noneTarget)
		case spineEmpty:
			emit(dimStyle.Render(truncate(sr.text, width)), noneTarget)
		}
	}
	return lines, targets, cursorLine
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

// retryIn renders how long until the paused poll retries, as a compact "in 4s" /
// "in 2m". It floors at "now" rather than emitting a negative: a retry the clock
// has already passed but whose tick has not landed yet is imminent, not overdue,
// and a "-1s" on the identity strip would read as a bug in the board.
func retryIn(at, now time.Time) string {
	d := at.Sub(now)
	if d <= 0 {
		return "now"
	}
	if d < time.Minute {
		return fmt.Sprintf("in %ds", int((d+time.Second-1)/time.Second))
	}
	return fmt.Sprintf("in %dm", int((d+time.Minute-1)/time.Minute))
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

// windowSpine clips the spine to `avail` lines from the slideTop-chosen top,
// marking any hidden overflow with dim ↑/↓ "N more" affordances.
func windowSpine(lines []string, top, avail, width int) []string {
	if avail <= 0 {
		return nil
	}
	if len(lines) <= avail {
		return lines
	}
	start := top
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

// pulseLine renders the now-line — `⠹ worker · pulse text · 30s` — with the
// TTL decay visibly honest (charter D9: stale never lies fresh):
//
//	fresh   (< 70% of the lease)  blue spinner, the text at full weight
//	leaning (70%…TTL)             amber spinner, the text recedes to dim
//	stale   (past the lease TTL)  NO spinner (motion is liveness and this
//	                              pulse is not live) — a dim · lead, the whole
//	                              line dim, and an explicit "stale" before the
//	                              age
//
// The grading is claimRole — the same lease arithmetic the claim glyph burns
// through, so the pulse and its row can never disagree about freshness. The
// spinner rides the board heartbeat frame (0 at rest / reduced-motion / cold
// paints, so goldens stay deterministic); every glyph is existing vocabulary.
func pulseLine(t Task, p *ClaimPulse, frame, width int, now time.Time) string {
	worker := ""
	if t.Claim != nil {
		worker = t.Claim.Worker
	}
	age := AgeBadge(p.At, now)
	role := claimRole(p.At, now)

	if role == RoleDanger { // past the lease TTL: visibly stale, never fresh
		s := "· "
		if worker != "" {
			s += worker + " · "
		}
		s += p.Text + " · stale"
		if age != "" {
			s += " " + age
		}
		return dimStyle.Render(truncate(s, width))
	}

	line := roleStyle(role).Render(spinnerGlyph(frame)) + " "
	if worker != "" {
		line += infoStyle.Render(worker) + dimStyle.Render(" · ")
	}
	textStyle := neutralStyle
	if role == RoleWarn { // the lease is leaning — the words start to fade
		textStyle = dimStyle
	}
	line += textStyle.Render(p.Text)
	if age != "" {
		line += dimStyle.Render(" · " + age)
	}
	return truncate(line, width)
}

// renderFooter is the BOARD frame's one hint line (charter D18: one line per
// frame kind — the reading frames get their own hint from the compositor). `esc
// back` teaches the navigation-shell ascend now that enter descends into a
// detail frame (charter D11). A tight pane drops the word "move" (jk next to the
// other single-key verbs still reads as motion) rather than blind-truncating the
// LAST verb off the end; the trailing truncate stays as the sub-60 safety net.
//
// The c/x/o verbs are also CLICK targets (charter D96): buildBoardFooter emits
// their column spans alongside the text, and the shell's footerVerbAt hit-tests a
// mouse click against exactly this ladder — so a clicked verb fires the same
// reducer as its key. A hovered verb (st.HoverFooterVerb) wears a background tint;
// at rest the whole line is one dim span, byte-identical to the pre-mouse footer.
func renderFooter(st UIState, width int) string {
	segs, _ := buildBoardFooter(width, st.MouseReleased)
	return renderFooterSegs(segs, width, st.HoverFooterVerb)
}

// footerSeg is one dot-separated footer segment. A non-zero verb marks a
// clickable board act-verb (c claim / x close / o studio); the nav/reading hints
// carry verb 0.
type footerSeg struct {
	text string
	verb rune
}

// footerVerbSpan is a clickable verb's [start,end) column range within the
// rendered board footer line (display columns, measured BEFORE the pane gutter
// the compositor adds). A verb that the width ladder clips loses its span, so a
// span never points at a half-painted or absent token (charter D96).
type footerVerbSpan struct {
	verb       rune
	start, end int
}

// footerSep is the dim dot leader between footer segments — one display cell.
const footerSep = " · "

// footerEtiquette is the dim mouse-mode footnote (charter D96): while the mouse
// is captured it names the terminal-owned text-selection bypass and the M toggle;
// while released it states the mode and how to re-arm. The wording is terminal-
// GENERIC — Option (iTerm2) or Shift (most xterm-family) click bypasses mouse
// reporting to select text — and never claims an app-side passthrough, which does
// not exist. It rides the shed ladder as the lowest-priority tail (sheds first).
func footerEtiquette(mouseReleased bool) string {
	if mouseReleased {
		return "mouse off · M on"
	}
	return "opt/shift-click selects · M mouse"
}

// footerEtiquetteShort is the compressed footnote the ladder falls back to when
// the full etiquette line does not fit: it keeps the M toggle discoverable at
// every canonical portrait width (Compose insets 4, so the full board note needs
// a >=102-col terminal — the whole 60–100-col portrait vision would otherwise
// never see it). Captured mode names the toggle; released mode names the re-arm.
func footerEtiquetteShort(mouseReleased bool) string {
	if mouseReleased {
		return "M on"
	}
	return "M mouse"
}

// buildBoardFooter assembles the board footer's segments at the given inner width
// and mouse mode, plus the click spans for the c/x/o verbs (charter D93/D96). The
// width ladder, widest-that-fits: the etiquette footnote COMPRESSES first (full
// note → the short M-toggle form) and sheds entirely before any verb hint, THEN
// the nav hint drops its "move" word, THEN the whole line trailing-truncates as
// the sub-60 floor. verbSpans clips a verb the truncation would cut, so the
// returned spans always align with fully-painted verb tokens.
func buildBoardFooter(width int, mouseReleased bool) (segs []footerSeg, spans []footerVerbSpan) {
	verbs := []footerSeg{
		{"enter open", 0},
		{"esc back", 0},
		{"c claim", 'c'},
		{"x close", 'x'},
		{"o studio", 'o'},
	}
	assemble := func(nav, tail string) []footerSeg {
		out := make([]footerSeg, 0, len(verbs)+2)
		out = append(out, footerSeg{nav, 0})
		out = append(out, verbs...)
		if tail != "" {
			out = append(out, footerSeg{tail, 0})
		}
		return out
	}
	for _, cand := range [][]footerSeg{
		assemble("jk move", footerEtiquette(mouseReleased)),
		assemble("jk move", footerEtiquetteShort(mouseReleased)),
		assemble("jk move", ""),
		assemble("jk", ""),
	} {
		if segsWidth(cand) <= width {
			return cand, verbSpans(cand, width)
		}
	}
	// Sub-60 floor: the shortest line, trailing-truncated to width by renderFooter;
	// verbs the cut clips drop their spans.
	segs = assemble("jk", "")
	return segs, verbSpans(segs, width)
}

// segsWidth is the display width of segments joined by the dot leader.
func segsWidth(segs []footerSeg) int {
	w := 0
	for i, s := range segs {
		if i > 0 {
			w += disp(footerSep)
		}
		w += disp(s.text)
	}
	return w
}

// footerJoin renders the plain footer line (segments + dot leaders).
func footerJoin(segs []footerSeg) string {
	parts := make([]string, len(segs))
	for i, s := range segs {
		parts[i] = s.text
	}
	return strings.Join(parts, footerSep)
}

// verbSpans locates each verb segment's [start,end) column range in the joined
// line, KEEPING only the verbs that fall entirely within width — a clipped verb
// loses its span (charter D96), so a click can never land on a token the ladder
// truncated away.
func verbSpans(segs []footerSeg, width int) []footerVerbSpan {
	var spans []footerVerbSpan
	col := 0
	for i, s := range segs {
		if i > 0 {
			col += disp(footerSep)
		}
		w := disp(s.text)
		if s.verb != 0 && col+w <= width {
			spans = append(spans, footerVerbSpan{verb: s.verb, start: col, end: col + w})
		}
		col += w
	}
	return spans
}

// renderFooterSegs paints the joined footer. At rest (hover == 0) it is one dim
// span — byte-identical ANSI to the pre-mouse footer, so the only golden churn is
// the footnote text. When a verb is hovered its whole token gets the background
// tint; the rest stays dim. A line that overflows width falls back to the plain
// dim+truncate path so a hover tint never risks cutting an ANSI escape.
func renderFooterSegs(segs []footerSeg, width int, hover rune) string {
	plain := footerJoin(segs)
	if hover == 0 || disp(plain) > width {
		return dimStyle.Render(truncate(plain, width))
	}
	var sb strings.Builder
	for i, s := range segs {
		if i > 0 {
			sb.WriteString(dimStyle.Render(footerSep))
		}
		if s.verb == hover {
			sb.WriteString(verbHoverStyle.Render(s.text))
		} else {
			sb.WriteString(dimStyle.Render(s.text))
		}
	}
	return sb.String()
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
