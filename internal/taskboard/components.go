package taskboard

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	runewidth "github.com/mattn/go-runewidth"
)

// disp is the display width of a possibly-styled string: ANSI-stripped, then
// runewidth-measured so CJK (2 cols) and combining marks are counted honestly.
// All layout math in this package goes through disp / truncate so a multi-byte
// title never garbles a right-aligned column.
func disp(s string) int { return runewidth.StringWidth(ansi.Strip(s)) }

// truncate is the one width-safe clip in the package — ANSI- and
// grapheme-aware (charmbracelet/x/ansi) so it never splits a rune OR an escape
// sequence and never exceeds the column budget (æøå = 1 col, CJK/emoji =
// 2 cols). Styled strings clip on their VISIBLE width: a runewidth-only cut
// would count SGR parameter bytes as columns and eat real content (on a
// truecolor terminal a styled 40-col header shrank to "⎇ …").
func truncate(s string, max int) string {
	if max <= 0 {
		return ""
	}
	return ansi.Truncate(s, max, "…")
}

// minMiddleHead is the fewest head columns a middle-out clip may keep — enough
// for "opening http…" to still read as "a link is opening" before the elision.
const minMiddleHead = 12

// truncateMiddle clips a PLAIN (unstyled) string to max display columns while
// keeping BOTH ends, eliding the middle with "…". It exists for messages whose
// tail is as load-bearing as their head — a Studio deep link ends in the task's
// doc id, the one part a reader needs, so the tail-first `truncate` above would
// drop exactly it. wantTail asks for that many trailing columns (the caller
// measures its load-bearing suffix — e.g. "/<doc-id>"); it is honored whenever
// minMiddleHead columns of preamble survive, because a doc id must come through
// WHOLE or visibly cut — real ids are 36-col UUIDs, and a balanced split on a
// 60-col pane would shave 7 leading chars off one, leaving a string that looks
// pasteable but resolves to nothing. wantTail <= 0 (or an unhonorable ask)
// falls back to a balanced split. Rune- and width-aware (æøå = 1 col, CJK = 2).
func truncateMiddle(s string, max, wantTail int) string {
	if max <= 0 {
		return ""
	}
	if runewidth.StringWidth(s) <= max {
		return s
	}
	if max <= 1 {
		return "…"
	}
	budget := max - 1 // one column for the ellipsis
	tail := wantTail
	if tail <= 0 || tail > budget-minMiddleHead {
		tail = budget / 2 // balanced: head keeps the extra column
	}
	return runewidth.Truncate(s, budget-tail, "") + "…" + lastCols(s, tail)
}

// lastCols returns the trailing `cols` display columns of a plain string,
// snapping to a rune boundary so a multi-byte suffix is never split.
func lastCols(s string, cols int) string {
	if cols <= 0 {
		return ""
	}
	rs := []rune(s)
	w, i := 0, len(rs)
	for i > 0 {
		cw := runewidth.RuneWidth(rs[i-1])
		if w+cw > cols {
			break
		}
		w += cw
		i--
	}
	return string(rs[i:])
}

// StatusGlyph is the 2-col gutter's STEADY status mark — the design-language
// spec §1 vocabulary (charter D36): a still in_progress representative (frame 0
// ⠋), `!` blocked, ✓ done|closed, ✕ cancelled, ○ ready|open (open vs ready is a
// brightness cue applied by glyphStyleFor, not a glyph change). The BOARD's
// animated in_progress spinner is boardGlyph(lifecycle, frame); this steady form
// is what non-frame contexts (the ticker, paper driven rows, a legend) paint.
// Selection is a separate marker (SelectionMarker) in the leading column;
// styling (the state hue / dim recede) is applied by callers. An unknown
// lifecycle degrades to the neutral "·" dot. Under the ASCII escape hatch the
// whole set collapses to 1-column ASCII so nothing turns to tofu (spec §3).
func StatusGlyph(lifecycle string) string {
	if asciiMode() {
		return asciiGlyph(lifecycle)
	}
	switch lifecycle {
	case "in_progress":
		return brailleFrames[0] // ⠋ — steady representative; boardGlyph animates it
	case "blocked":
		return "!"
	case "done", "closed":
		return "✓"
	case "cancelled":
		return "✕"
	case "ready", "open":
		return "○"
	default:
		return "·"
	}
}

// SelectionMarker is the cursor's ▎ left bar in the gutter's leading column — a
// calm vertical rule beside the row you'd act on (the calm-board subtraction
// retired the louder ▶ arrow). A space keeps every non-selected row's glyph
// column-aligned.
func SelectionMarker(selected bool) string {
	if selected {
		return "▎"
	}
	return " "
}

// AgeBadge is the compact "time since" token ("4m", "3h", "2d", "now"). Empty
// for a zero time. Copied from cmd/barkpark's timeAgo idiom (clock-skew clamp
// included) rather than importing package main.
func AgeBadge(t, now time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := now.Sub(t)
	if d < 0 { // server/client skew — never render "-2m"
		return "now"
	}
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

// criteriaFraction is the calm-board criteria token: the bare "met/total" digits
// ("2/3"), no ▰▱ bar (the subtraction pass retired the meter's cells; digits
// carry the same information without a second glyph vocabulary). Empty for a nil
// or zero-total Criteria, so a task with no criteria costs no token.
func criteriaFraction(c *Criteria) string {
	if c == nil || c.Total <= 0 {
		return ""
	}
	return fmt.Sprintf("%d/%d", c.Met, c.Total)
}

// (epicProgress — the old done/total tally — was retired with the ▰▱ bar and the
// done/total header token; the claim-forward rail below is sectionHint's job.)

// sectionCounts tallies a section's members for the claim-forward header rail:
// ready (immediately claimable), done (terminal, incl. the folded-away tally),
// and open (the remaining non-terminal, non-ready work — blocked / plain open /
// unclaimed in_progress). It is the shared unit behind every section header.
type sectionCounts struct{ ready, done, open int }

// countSection tallies a section's visible tasks plus its folded-done count into
// a sectionCounts. Terminal survivors (recent done still shown) join the folded
// pile in `done`, so the header's tally covers ALL finished work, not just the
// hidden rows.
func countSection(tasks []Task, doneFolded int) sectionCounts {
	sc := sectionCounts{done: doneFolded}
	for _, t := range tasks {
		switch {
		case t.Lifecycle == lifeReady:
			sc.ready++
		case isTerminal(t.Lifecycle):
			sc.done++
		default:
			sc.open++
		}
	}
	return sc
}

// sectionRollup is the ONE right-rail shared by every section header — the
// design-language phase rollup (charter D41, spec §3): an optional phase code
// then a `done/total` completion fraction:
//
//	W5 · 5/11        (code + rollup)
//	3/9              (rollup only — the epic/cluster fallback, no phase code)
//
// total is the section's non-terminal-plus-done task count (ready+open+done,
// where done folds in the hidden terminal tally); done leads the fraction so the
// needle is visible at a glance (spec §0 "progress at every scale"). A code-less
// empty section returns "" for a bare leader. Returns (plain, styled) of equal
// display width so the caller aligns on the plain width and prints the styled.
func sectionRollup(sc sectionCounts, code string) (plain, styled string) {
	total := sc.ready + sc.open + sc.done
	var pp, ss []string
	if code != "" {
		pp, ss = append(pp, code), append(ss, dimStyle.Render(code))
	}
	if total > 0 {
		f := fmt.Sprintf("%d/%d", sc.done, total)
		pp, ss = append(pp, f), append(ss, dimStyle.Render(f))
	}
	if len(pp) == 0 {
		return "", ""
	}
	return strings.Join(pp, " · "), strings.Join(ss, " · ")
}

// renderSectionHeader is the ONE dotted-leader section-header layout, shared by
// epics, derived clusters and the loose bucket so their phase rollups can never
// drift (charter D41, spec §3):
//
//	Token spine ·················· W1 · 1/4
//	Cloud GUI epic ······················ 3/9
//
// code is the section's phase code ("" when the section has no phase metadata —
// the guerrilla reality). derived marks an inferred cluster: its title renders
// monochrome-dim and trails a dim "~". selected prefixes the ▎ marker (a
// 2-column lead, so the title column never shifts). The rail is sectionRollup;
// an empty rail lets the dots run to the edge. The title is budgeted so at least
// minDots survive; extreme widths degrade to a lead + title. The final truncate
// is the width safety net.
func renderSectionHeader(title, code string, derived, selected bool, sc sectionCounts, width int) string {
	if width < 8 {
		return truncate(title, width)
	}
	railPlain, railStyled := sectionRollup(sc, code)
	railW := disp(railPlain)

	lead := "  "
	if selected {
		lead = "▎ "
	}
	suffixW := 0
	if derived {
		suffixW = 2 // " ~"
	}

	const minDots = 3
	// layout: lead + title + [ ~] + " " + dots + [ " " + rail ]
	fixed := disp(lead) + suffixW + 1 // + the space after the title block
	titleMax := width - fixed - minDots
	if railW > 0 {
		titleMax -= 1 + railW // space before rail + rail
	}
	if titleMax < 1 {
		// Extremely narrow: lead + title only, drop the rail.
		t := title
		if derived {
			t += " ~"
		}
		return truncate(lead+t, width)
	}
	title = truncate(title, titleMax)

	titleStyled := title
	if derived {
		titleStyled = dimStyle.Render(title + " ~")
	}
	left := lead + titleStyled + " "
	leftW := disp(lead) + disp(title) + suffixW + 1

	if railW == 0 {
		mid := width - leftW
		if mid < 0 {
			return truncate(left, width)
		}
		return truncate(left+dimStyle.Render(strings.Repeat("·", mid)), width)
	}
	mid := width - leftW - 1 - railW
	if mid < minDots {
		mid = minDots
	}
	return truncate(left+dimStyle.Render(strings.Repeat("·", mid))+" "+railStyled, width)
}

// EpicHeader is the dotted-leader section header for an authored epic, carrying
// its phase rollup (charter D41). A folded epic (the default) renders exactly
// this one glanceable line; the phase code is derived from the epic root's title
// / labels (phaseCode) — absent on most of the guerrilla corpus, where the
// rollup shows a bare done/total.
func EpicHeader(e Epic, width int) string {
	return renderSectionHeader(e.Root.Title, phaseCodeOf(e.Root), false, false,
		countSection(e.Children, e.DoneFolded), width)
}

// titleStyleFor gives in_progress titles weight and done titles a recede.
func titleStyleFor(lifecycle string) lipgloss.Style {
	switch lifecycle {
	case "in_progress":
		return boldStyle
	case "done", "closed":
		return dimStyle
	default:
		return lipgloss.NewStyle()
	}
}

// metaToken is one right-meta cell: the plain text (for width math) plus its
// styled render (same display width).
type metaToken struct{ plain, styled string }

// priorityLabel normalizes the wire's priority to a `P<n>` token, or "" when
// absent. The live corpus stores a bare digit ("0".."4"); a lone "0" reads as
// noise, so it is prefixed so the row shows the urgency it is (P0 most urgent).
func priorityLabel(p string) string {
	if p == "" {
		return ""
	}
	if c := p[0]; c == 'P' || c == 'p' {
		return "P" + strings.TrimLeft(p, "Pp")
	}
	if c := p[0]; c >= '0' && c <= '9' {
		return "P" + p
	}
	return p
}

// blockerCause is the amber `! cause` badge text for a blocked row (spec §3): a
// derivable short blocker ref/title when the wire carries one, else the plain
// word. The board Task envelope carries only dependency COUNTS (not the blocker
// refs), so v1 renders the honest word "blocked"; the cause enriches for free if
// a future envelope ships the blocking task's ref.
func blockerCause(t Task) string { return "blocked" }

// richRowMeta builds the spec §3 right-meta tokens for a task row, in display
// order (priority · criteria · worker · age), split into DROPPABLE tokens (shed
// right→left when the row is tight) and a STICKY blocker badge (amber, sheds
// LAST — most load-bearing). Priority is color-severity; criteria a bare
// tabular fraction; worker rides a claimed in_progress row in blue; a rotting
// non-terminal row wears its stale day-age, a terminal row its resolved age.
func richRowMeta(t Task, now time.Time) (drop []metaToken, sticky metaToken) {
	terminal := isTerminal(t.Lifecycle)
	if !terminal {
		if lbl := priorityLabel(t.Priority); lbl != "" {
			drop = append(drop, metaToken{lbl, priorityStyle(t.Priority).Render(lbl)})
		}
	}
	if f := criteriaFraction(t.Criteria); f != "" {
		drop = append(drop, metaToken{f, dimStyle.Render(f)})
	}
	if t.Lifecycle == lifeInProgress && t.Claim != nil && t.Claim.Worker != "" {
		drop = append(drop, metaToken{t.Claim.Worker, infoStyle.Render(t.Claim.Worker)})
	}
	if terminal {
		if age := AgeBadge(t.UpdatedAt, now); age != "" {
			drop = append(drop, metaToken{age, dimStyle.Render(age)})
		}
	} else if p, s := staleBadge(t, now); p != "" {
		drop = append(drop, metaToken{p, s})
	}
	if t.Lifecycle == lifeBlocked {
		cause := blockerCause(t)
		sticky = metaToken{cause, warnStyle.Render(cause)}
	}
	return drop, sticky
}

// fitRowMeta assembles the right-meta within titleBudget, shedding droppable
// tokens from the right until the title keeps at least minTitleCols columns; the
// sticky blocker badge is kept until nothing else fits, then dropped last. It
// returns the styled meta (or "") and the title budget left after reserving it.
func fitRowMeta(drop []metaToken, sticky metaToken, titleBudget int) (metaStyled string, titleLeft int) {
	const minTitleCols = 8
	build := func(keep int) (string, string) {
		var pp, ss []string
		for i := 0; i < keep && i < len(drop); i++ {
			pp, ss = append(pp, drop[i].plain), append(ss, drop[i].styled)
		}
		if sticky.plain != "" {
			pp, ss = append(pp, sticky.plain), append(ss, sticky.styled)
		}
		return strings.Join(pp, " "), strings.Join(ss, " ")
	}
	for keep := len(drop); ; keep-- {
		plain, styled := build(keep)
		if plain == "" {
			return "", titleBudget
		}
		if titleBudget-disp(plain)-2 >= minTitleCols {
			return styled, titleBudget - disp(plain) - 2
		}
		if keep == 0 { // even the sticky-only badge will not fit — drop everything
			return "", titleBudget
		}
	}
}

// staleBadge returns the day-scale age token (plain, styled) for a non-terminal
// task that has gone stale — an amber `4d` past 3 days, a red `8d` past a week —
// so an outdated open/ready/blocked row wears its neglect. Fresh (or terminal)
// tasks return "" and cost no meta slot.
func staleBadge(t Task, now time.Time) (plain, styled string) {
	sr := staleRole(t.UpdatedAt, now, t.Lifecycle)
	if sr != RoleWarn && sr != RoleDanger {
		return "", ""
	}
	age := AgeBadge(t.UpdatedAt, now)
	if age == "" {
		return "", ""
	}
	return age, roleStyle(sr).Render(age)
}

// dropMetaBelow is the width under which rows shed their right-meta and keep
// only the glyph + title (the graceful sub-60-col degrade).
const dropMetaBelow = 52

// TaskRow renders one task as a single rich line (design-language spec §3,
// charter D39):
//
//	indent [↳] ▎glyph  title  ……………  PRIORITY N/M worker
//
// The lifecycle glyph carries state by the brightness+meaning ladder (open ○
// dim-white / ready ○ full-foreground / in_progress the blue Braille spinner at
// `frame` / blocked ! amber / done ✓ teal / cancelled ✕ dim); the title stays
// monochrome (done recedes, in_progress bolds); the right-meta is color-severity
// priority + bare criteria + blue worker, with an amber blocker badge that sheds
// LAST. depth nests the row under its parent with a ↳ guide (arbitrary depth).
// Everything is width-safe: when tight the meta sheds right→left (title never
// clips below 8 cols), and below dropMetaBelow the row is glyph + title only.
func TaskRow(t Task, selected bool, depth, width, frame int, now time.Time) []string {
	marker := SelectionMarker(selected)
	glyph := glyphStyleFor(t, now).Render(boardGlyph(t.Lifecycle, frame))
	indent := childIndent + depth*2
	guide, pad := "", indent
	if depth > 0 {
		guide, pad = "↳ ", indent-2 // the ↳ guide occupies the deepest 2 indent cols
	}
	lead := strings.Repeat(" ", pad) + dimStyle.Render(guide) + marker + glyph + " "
	leadW := indent + 3 // pad + guide(2 or 0) + marker + glyph + space
	tStyle := titleStyleFor(t.Lifecycle)

	if width < dropMetaBelow {
		// Narrow degrade: glyph + title only (no meta).
		return []string{lead + tStyle.Render(truncate(t.Title, width-leadW))}
	}
	drop, sticky := richRowMeta(t, now)
	metaStyled, titleBudget := fitRowMeta(drop, sticky, width-leadW)
	title := truncate(t.Title, titleBudget)
	left := lead + tStyle.Render(title)
	if metaStyled == "" {
		return []string{left}
	}
	gap := width - disp(left) - disp(metaStyled)
	if gap < 1 {
		gap = 1
	}
	return []string{left + strings.Repeat(" ", gap) + metaStyled}
}

// NowCard is a pinned two-line claim card (spec §3 NOW band):
//
//	⠋ Wire the SSE live bridge
//	   opus-3 · 4m · 2/3 · Cloud GUI epic
//
// breadcrumb is the parent epic's title (the caller resolves ParentID). The
// glyph is the live blue Braille spinner (frame'th), tinted by the claim lease
// (info→warn→danger via glyphStyleFor). NOW cards are cursor rows (the first
// indexes in the shell's visibleRows), so like TaskRow they carry a leading
// selection-marker column: ▎ when the cursor is on this card, a space otherwise.
func NowCard(t Task, breadcrumb string, selected bool, width, frame int, now time.Time) []string {
	glyph := glyphStyleFor(t, now).Render(boardGlyph(t.Lifecycle, frame))
	title := truncate(t.Title, width-3)
	line1 := SelectionMarker(selected) + glyph + " " + titleStyle.Render(title)

	var sparts []string
	add := func(p, s string) {
		if p == "" {
			return
		}
		sparts = append(sparts, s)
	}
	if t.Claim != nil {
		add(t.Claim.Worker, dimStyle.Render(t.Claim.Worker))
		if age := AgeBadge(t.Claim.ClaimedAt, now); age != "" {
			st := roleStyle(claimRole(t.Claim.ClaimedAt, now))
			add(age, st.Render(age))
		}
	}
	if f := criteriaFraction(t.Criteria); f != "" {
		add(f, dimStyle.Render(f))
	}
	if breadcrumb != "" {
		add(breadcrumb, dimStyle.Render(breadcrumb))
	}
	// Truncate the styled join on display width so it never overruns —
	// truncate is ANSI-aware, so the claim-age tint survives the clip.
	styled := strings.Join(sparts, " · ")
	if disp(styled) > width-3 {
		styled = truncate(styled, width-3)
	}
	line2 := "   " + styled
	return []string{line1, line2}
}
