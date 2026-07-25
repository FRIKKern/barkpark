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

// rowTitle is the row's shown title — NEVER blank (charter D-C). An empty title
// used to paint a bare "○ " / "↳ ✓" line that read as broken; instead it degrades
// to the short doc-id (dim) when one is present, else a dim "(untitled)". The
// second return forces the placeholder to render dim so it reads as an ABSENCE,
// not a real title, whatever the row's lifecycle weight.
func rowTitle(t Task) (text string, placeholder bool) {
	if strings.TrimSpace(t.Title) != "" {
		return t.Title, false
	}
	if id := bareID(t.DocID); id != "" {
		return truncate(id, 16), true
	}
	return "(untitled)", true
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
	// The steady glyph per lifecycle is sourced from tokens_gen.go (GenLifecycle,
	// emitted from design/tokens.json). in_progress's ⠋ is GenBrailleFrames[0] —
	// the steady representative boardGlyph animates. An unknown lifecycle degrades
	// to the neutral "·" dot.
	if tok, ok := GenLifecycle[lifecycle]; ok {
		return tok.Glyph
	}
	return "·"
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

// rowCriteriaFraction is the fraction a task row shows: the server's
// criteria_progress when present (the authoritative count), else derived from
// the decoded checklist — so a ladder can never paint without its fraction.
// "" when the task has no criteria at all.
func rowCriteriaFraction(t Task) string {
	if f := criteriaFraction(t.Criteria); f != "" {
		return f
	}
	if len(t.CriteriaItems) == 0 {
		return ""
	}
	met := 0
	for _, it := range t.CriteriaItems {
		if it.Met {
			met++
		}
	}
	return fmt.Sprintf("%d/%d", met, len(t.CriteriaItems))
}

// ladderMaxRungs caps the criteria ladder's rung count. Past it the row keeps
// the bare fraction — a 20-criterion task would otherwise paint a 20-rune run
// that eats the title on the 80-col budget, and past a handful of rungs the
// individual locks stop being glanceable anyway (the rubric's 7-factor tasks
// all fit).
const ladderMaxRungs = 8

// livePulseCriterion is the acceptance-criteria index a LIVE pulse names on
// this task's claim, or -1: the claim must be worker-held, carry a now-pulse
// naming a criterion, and the pulse must still be within the lease TTL
// (charter D9 — staleness derives from claim.now.ts vs the lease). Exactly ONE
// rung may spin, and only while the pulse is genuinely live — a stale pulse
// spins nothing (motion is liveness; a dead pulse must not animate).
func livePulseCriterion(t Task, now time.Time) int {
	if t.Claim == nil || t.Claim.Worker == "" || t.Claim.Now == nil {
		return -1
	}
	p := t.Claim.Now
	if p.Criterion < 0 || p.At.IsZero() || now.Sub(p.At) >= leaseTTL {
		return -1
	}
	return p.Criterion
}

// criteriaLadder renders the per-criterion lock ladder (charter D11): one rung
// per acceptance criterion, in checklist order —
//
//	✓ teal   met (the seal)
//	⠹ blue   the ONE criterion a live pulse names (claim.now.criterion, spinning
//	         on the board heartbeat while the pulse is within the lease TTL)
//	! amber  an honest recorded miss (attempts without the met seal)
//	○ dim    untouched
//
// Every rune is existing board vocabulary (GenLifecycle glyphs + the braille
// spinner — ZERO new glyphs, so the glyph-budget allowlist is untouched), and
// each rung goes through StatusGlyph/spinnerGlyph so the ASCII escape hatch
// degrades the whole ladder for free. Returns ("","") when the task has no
// decoded checklist or it exceeds ladderMaxRungs — the row then keeps today's
// bare fraction. A met rung outranks a pulse naming it (sealed is truer than
// "being worked"), and the pulse rung outranks a recorded miss (the miss is
// history; the pulse is now).
func criteriaLadder(t Task, now time.Time, frame int) (plain, styled string) {
	items := t.CriteriaItems
	if len(items) == 0 || len(items) > ladderMaxRungs {
		return "", ""
	}
	live := livePulseCriterion(t, now)
	var pp, ss strings.Builder
	for i, it := range items {
		switch {
		case it.Met:
			g := StatusGlyph(lifeDone)
			pp.WriteString(g)
			ss.WriteString(doneStyle.Render(g))
		case i == live:
			g := spinnerGlyph(frame)
			pp.WriteString(g)
			ss.WriteString(infoStyle.Render(g))
		case it.Missed():
			g := StatusGlyph(lifeBlocked)
			pp.WriteString(g)
			ss.WriteString(warnStyle.Render(g))
		default:
			g := StatusGlyph(lifeOpen)
			pp.WriteString(g)
			ss.WriteString(openStyle.Render(g))
		}
	}
	return pp.String(), ss.String()
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
	return renderSectionHeaderIndent(title, code, derived, selected, 0, sc, width)
}

// renderSectionHeaderIndent is renderSectionHeader with a leading indent of
// `indent` extra columns before the 2-col lead — the seam a NAMED phase band
// (charter wave-10 W10-A) uses to sit one level under its epic header while
// reusing the exact same dotted-leader + rollup grammar (no drift possible). An
// indent of 0 is the ordinary section header.
func renderSectionHeaderIndent(title, code string, derived, selected bool, indent int, sc sectionCounts, width int) string {
	if strings.TrimSpace(title) == "" {
		title = "(untitled)" // a section header is never blank (charter D-C)
	}
	if width < 8 {
		return truncate(title, width)
	}
	railPlain, railStyled := sectionRollup(sc, code)
	railW := disp(railPlain)

	pre := strings.Repeat(" ", indent)
	lead := pre + "  "
	if selected {
		lead = pre + "▎ "
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
// styled render (same display width). A token may carry an optional NARROW
// fallback (the criteria ladder's bare fraction): fitRowMeta swaps to it
// before shedding any token, so a tight row degrades its richest cell first
// instead of dropping information outright.
type metaToken struct {
	plain, styled             string
	narrowPlain, narrowStyled string
}

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
// LAST — most load-bearing). Priority is color-severity; criteria the lock
// ladder + fraction ("✓✓!○ 2/4" — degrading to the bare fraction when the row
// is tight, see fitRowMeta); worker rides a claimed in_progress row in blue; a
// rotting non-terminal row wears its stale day-age, a terminal row its
// resolved age. frame drives the ladder's live-pulse spinner rung (0 at rest).
func richRowMeta(t Task, now time.Time, frame int) (drop []metaToken, sticky metaToken) {
	terminal := isTerminal(t.Lifecycle)
	if badge := completenessBadge(t.Completeness); badge != "" {
		style := dimStyle
		if t.Completeness.Score < t.Completeness.Total {
			style = warnStyle
		}
		drop = append(drop, metaToken{plain: badge, styled: style.Render(badge)})
	}
	if !terminal {
		if lbl := priorityLabel(t.Priority); lbl != "" {
			drop = append(drop, metaToken{plain: lbl, styled: priorityStyle(t.Priority).Render(lbl)})
		}
	}
	if f := rowCriteriaFraction(t); f != "" {
		tok := metaToken{plain: f, styled: dimStyle.Render(f)}
		if lp, ls := criteriaLadder(t, now, frame); lp != "" {
			// The rich form is ladder + fraction; the bare fraction stays as the
			// narrow fallback a tight row degrades to before any token is shed.
			tok.narrowPlain, tok.narrowStyled = tok.plain, tok.styled
			tok.plain = lp + " " + f
			tok.styled = ls + " " + dimStyle.Render(f)
		}
		drop = append(drop, tok)
	}
	if t.Lifecycle == lifeInProgress && t.Claim != nil && t.Claim.Worker != "" {
		drop = append(drop, metaToken{plain: t.Claim.Worker, styled: infoStyle.Render(t.Claim.Worker)})
		if age := AgeBadge(t.Claim.ClaimedAt, now); age != "" {
			drop = append(drop, metaToken{plain: age, styled: dimStyle.Render(age)})
		}
	}
	if terminal {
		if age := AgeBadge(t.UpdatedAt, now); age != "" {
			drop = append(drop, metaToken{plain: age, styled: dimStyle.Render(age)})
		}
	} else if p, s := staleBadge(t, now); p != "" {
		drop = append(drop, metaToken{plain: p, styled: s})
	}
	if t.Lifecycle == lifeBlocked {
		cause := blockerCause(t)
		sticky = metaToken{plain: cause, styled: warnStyle.Render(cause)}
	}
	return drop, sticky
}

// fitRowMeta assembles the right-meta within titleBudget in two phases: first
// every token in its FULL form (the criteria ladder's rungs paint when the row
// has room for everything); when that does not fit, tokens carrying a narrow
// fallback DEGRADE to it (ladder → bare fraction) and the set then sheds
// right→left until the title keeps at least minTitleCols columns — so a tight
// row loses the ladder's rungs before it loses the fraction, the worker or the
// age. The sticky blocker badge is kept until nothing else fits, then dropped
// last. It returns the styled meta (or "") and the title budget left after
// reserving it. Tokens without a narrow form behave exactly as before.
func fitRowMeta(drop []metaToken, sticky metaToken, titleBudget int) (metaStyled string, titleLeft int) {
	const minTitleCols = 8
	build := func(toks []metaToken, keep int) (string, string) {
		var pp, ss []string
		for i := 0; i < keep && i < len(toks); i++ {
			pp, ss = append(pp, toks[i].plain), append(ss, toks[i].styled)
		}
		if sticky.plain != "" {
			pp, ss = append(pp, sticky.plain), append(ss, sticky.styled)
		}
		return strings.Join(pp, " "), strings.Join(ss, " ")
	}
	// Phase 1: the full forms, everything kept.
	if plain, styled := build(drop, len(drop)); plain != "" && titleBudget-disp(plain)-2 >= minTitleCols {
		return styled, titleBudget - disp(plain) - 2
	}
	// Phase 2: degrade narrow-capable tokens, then shed right→left.
	narrowed := make([]metaToken, len(drop))
	for i, tk := range drop {
		if tk.narrowPlain != "" {
			tk.plain, tk.styled = tk.narrowPlain, tk.narrowStyled
		}
		narrowed[i] = tk
	}
	for keep := len(narrowed); ; keep-- {
		plain, styled := build(narrowed, keep)
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

// fitMetaStrip gives an active task's second line to operational metadata only.
// It first degrades rich tokens (criteria ladder → fraction), then sheds from
// the right until the strip fits. The title above receives the whole first row
// instead of competing with these facts.
func fitMetaStrip(tokens []metaToken, width int) string {
	if width < 1 {
		return ""
	}
	join := func(ts []metaToken) (plain, styled string) {
		pp := make([]string, 0, len(ts))
		ss := make([]string, 0, len(ts))
		for _, tk := range ts {
			pp = append(pp, tk.plain)
			ss = append(ss, tk.styled)
		}
		return strings.Join(pp, " · "), strings.Join(ss, dimStyle.Render(" · "))
	}
	if plain, styled := join(tokens); disp(plain) <= width {
		return styled
	}
	narrowed := make([]metaToken, len(tokens))
	for i, tk := range tokens {
		if tk.narrowPlain != "" {
			tk.plain, tk.styled = tk.narrowPlain, tk.narrowStyled
		}
		narrowed[i] = tk
	}
	for keep := len(narrowed); keep > 0; keep-- {
		if plain, styled := join(narrowed[:keep]); disp(plain) <= width {
			return styled
		}
	}
	return dimStyle.Render(truncate("in progress", width))
}

// outlineContinuation keeps the tree leg honest across an active task's second
// line: a branch with later siblings continues vertically; a final branch ends.
func outlineContinuation(outline string) string {
	if strings.HasSuffix(outline, "├─") {
		return strings.TrimSuffix(outline, "├─") + "│ "
	}
	if strings.HasSuffix(outline, "└─") {
		return strings.TrimSuffix(outline, "└─") + "  "
	}
	return strings.Repeat(" ", disp(outline))
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

// TaskRow renders ordinary tasks as one rich line and active in_progress tasks
// as a compact two-line card (design-language spec §3, charter D39):
//
//	indent [↳] ▎glyph  title  ……………  PRIORITY N/M worker
//	indent [↳] ▎glyph  full active title
//	                    PRIORITY · criteria · worker · age
//
// The lifecycle glyph carries state by the brightness+meaning ladder (open ○
// dim-white / ready ○ full-foreground / in_progress the blue Braille spinner at
// `frame` / blocked ! amber / done ✓ teal / cancelled ✕ dim); the title stays
// monochrome (done recedes, in_progress bolds); the right-meta is color-severity
// priority + the criteria lock ladder with its fraction (degrading to the bare
// fraction when tight) + blue worker, with an amber blocker badge that sheds
// LAST. depth nests the row by `depth` indent levels; `guide` draws the ↳
// subtask cue (decoupled from depth so a phase band's DIRECT child indents one
// level WITHOUT a spurious guide — charter wave-10 W10-A). Everything is
// width-safe: when tight the meta sheds right→left (title never clips below 8
// cols), and below dropMetaBelow the row is glyph + title only.
//
// `opened` marks the task the user has ENTERED (a FrameTask on the navigation
// stack — UIState.OpenTasks): its glyph column renders the reader-open diamond
// ◆ (ASCII '@') in the SAME lifecycle color — enter opens it, esc reverts it to
// the lifecycle glyph. Shape yields, color (= state) stays.
func TaskRow(t Task, selected, opened bool, depth int, guide bool, width, frame int, now time.Time) []string {
	indent := childIndent + depth*2
	guideStr, pad := "", indent
	if guide {
		guideStr, pad = "↳ ", indent-2
	}
	outline := strings.Repeat(" ", pad) + guideStr
	return taskRowWithOutline(t, selected, opened, outline, width, frame, now)
}

func taskRowWithOutline(t Task, selected, opened bool, outline string, width, frame int, now time.Time) []string {
	marker := SelectionMarker(selected)
	glyphRune := boardGlyph(t.Lifecycle, frame)
	if opened {
		glyphRune = checkedGlyph()
	}
	glyph := glyphStyleFor(t, now).Render(glyphRune)
	lead := dimStyle.Render(outline) + marker + glyph + " "
	leadW := disp(outline) + 3
	titleText, placeholder := rowTitle(t)
	tStyle := titleStyleFor(t.Lifecycle)
	if placeholder {
		tStyle = dimStyle // an empty title reads as an absence, never a real title
	}
	if t.Lifecycle == lifeInProgress {
		// Active work earns one extra row: title and telemetry no longer fight for
		// horizontal space. flattenSpine assigns both lines the same hit target.
		title := lead + tStyle.Render(truncate(titleText, width-leadW))
		drop, sticky := richRowMeta(t, now, frame)
		if t.DependentCount > 0 {
			label := fmt.Sprintf("blocks %d", t.DependentCount)
			drop = append(drop, metaToken{plain: label, styled: warnStyle.Render(label)})
		}
		if t.DependencyCount > 0 {
			label := fmt.Sprintf("blocked by %d", t.DependencyCount)
			drop = append(drop, metaToken{plain: label, styled: warnStyle.Render(label)})
		}
		if sticky.plain != "" {
			drop = append(drop, sticky)
		}
		detail := fitMetaStrip(drop, width-leadW)
		if detail == "" {
			detail = dimStyle.Render(truncate("in progress", width-leadW))
		}
		detailLead := dimStyle.Render(outlineContinuation(outline)) + "   "
		return []string{title, detailLead + detail}
	}

	if width < dropMetaBelow {
		// Narrow degrade: glyph + title only (no meta).
		return []string{lead + tStyle.Render(truncate(titleText, width-leadW))}
	}
	drop, sticky := richRowMeta(t, now, frame)
	metaStyled, titleBudget := fitRowMeta(drop, sticky, width-leadW)
	title := truncate(titleText, titleBudget)
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
