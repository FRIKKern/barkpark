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

// spinnerFrames is the in_progress heartbeat: a single dark quadrant rotating
// clockwise (upper-left → upper-right → lower-right → lower-left). Every glyph
// is display-width 1 (verified) so the fixed 2-col gutter never shifts as the
// frame advances, and frame%4==0 is a deterministic static glyph — at rest
// (Frame 0, no ticks scheduled) an in_progress row paints ◴ and never moves.
// The cycle is deliberately NOT the ◐ half-circle set: ◐ is blocked's glyph, so
// a rotating quadrant keeps "working" visually distinct from "blocked".
var spinnerFrames = [...]string{"◴", "◷", "◶", "◵"}

// StatusGlyph is the 2-col gutter's status mark, checklist-shaped at every level
// (charter decision 18): ☐ waiting (ready/open), ✓ done, ◐ blocked, and a live
// spinner for in_progress cycled from the heartbeat frame. Selection is a
// separate marker (SelectionMarker) rendered in the column before it. Styling
// (the role tint / dim recede) is applied by callers, as before. Motionless
// contexts (the ticker, any non-live render) pass frame 0 for the static glyph.
func StatusGlyph(lifecycle string, frame int) string {
	switch lifecycle {
	case "in_progress":
		if frame < 0 {
			frame = 0
		}
		return spinnerFrames[frame%len(spinnerFrames)]
	case "blocked":
		return "◐"
	case "done", "closed":
		return "✓"
	case "ready", "open":
		return "☐"
	default:
		return "·"
	}
}

// SelectionMarker is the cursor's ▶ in the gutter's leading column (the
// "ready-marker": it points at the row you'd act on). A space keeps every
// non-selected row's glyph column-aligned.
func SelectionMarker(selected bool) string {
	if selected {
		return "▶"
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

const meterCells = 5

// Meter renders the acceptance-criteria progress ("▰▰▱ 2/3"). A nil Criteria —
// or a zero-total one — renders nothing (never a bare "0/0").
func Meter(c *Criteria) string {
	if c == nil || c.Total <= 0 {
		return ""
	}
	met, total := c.Met, c.Total
	if met < 0 {
		met = 0
	}
	if met > total {
		met = total
	}
	cells := total
	filled := met
	if total > meterCells { // scale down to a fixed bar for large criteria sets
		cells = meterCells
		filled = scaleFill(met, total, meterCells)
	}
	return strings.Repeat("▰", filled) + strings.Repeat("▱", cells-filled) +
		fmt.Sprintf(" %d/%d", c.Met, c.Total)
}

// scaleFill maps met/total onto a cells-wide bar, rounding half-up but never
// lying at the edges: any progress shows at least one filled cell, and an
// unfinished bar never renders full (a "▱▱▱▱▱ 1/20" or "▰▰▰▰▰ 19/20" reads
// as broken or done when it is neither).
func scaleFill(met, total, cells int) int {
	filled := (met*cells + total/2) / total
	if filled < 1 && met > 0 {
		filled = 1
	}
	if filled >= cells && met < total {
		filled = cells - 1
	}
	if filled < 0 {
		filled = 0
	}
	if filled > cells {
		filled = cells
	}
	return filled
}

// EpicBar is the fixed-width progress bar in an epic header ("▰▰▰▰▱▱▱").
func EpicBar(done, total int) string {
	const cells = 7
	if total <= 0 {
		return strings.Repeat("▱", cells)
	}
	if done < 0 {
		done = 0
	}
	if done > total {
		done = total
	}
	filled := scaleFill(done, total, cells)
	return strings.Repeat("▰", filled) + strings.Repeat("▱", cells-filled)
}

// epicProgress returns (done, total) for an epic: folded-done are all done,
// plus any done/closed still shown among the children.
func epicProgress(e Epic) (done, total int) {
	total = len(e.Children) + e.DoneFolded
	done = e.DoneFolded
	for _, c := range e.Children {
		if c.Lifecycle == "done" || c.Lifecycle == "closed" {
			done++
		}
	}
	return done, total
}

// EpicHeader is the rule-style section header:
//
//	── Cloud GUI epic ───────────── 7/12 ▰▰▰▰▱▱▱
//
// A Dormant epic renders exactly the same header line (its children are folded
// away by the caller), so an idle goal collapses to one glanceable rule.
func EpicHeader(e Epic, width int) string {
	if width < 8 {
		return truncate(e.Root.Title, width)
	}
	done, total := epicProgress(e)
	if total == 0 {
		// No children and nothing folded (e.g. the "(no epic)" orphan bucket):
		// a rule + title with no misleading 0/0 progress rail.
		left := "── " + truncate(e.Root.Title, width-6) + " "
		mid := width - disp(left)
		if mid < 0 {
			return truncate(left, width)
		}
		return left + strings.Repeat("─", mid)
	}
	frac := fmt.Sprintf("%d/%d", done, total)
	bar := EpicBar(done, total)
	right := frac + " " + bar
	rightW := disp(right)

	const lead = "── "
	const minDashes = 3
	// Budget the title so at least minDashes fit between it and the right rail.
	titleMax := width - disp(lead) - 1 /*space after title*/ - minDashes - 1 /*space before right*/ - rightW
	title := e.Root.Title
	if titleMax < 1 {
		// Extremely narrow: rule + title only, drop the progress rail.
		return truncate(lead+title, width)
	}
	title = truncate(title, titleMax)
	left := lead + title + " "
	mid := width - disp(left) - 1 - rightW
	if mid < minDashes {
		mid = minDashes
	}
	line := left + strings.Repeat("─", mid) + " " + right
	return truncate(line, width)
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

// rowMeta is the right-aligned, state-specific meta for a collapsed task row.
// It returns the plain text plus the styled text (same display width) so the
// caller can right-align on the plain width and print the styled version.
func rowMeta(t Task, now time.Time) (plain, styled string) {
	var parts []string  // plain
	var sparts []string // styled, index-aligned with parts
	add := func(p, s string) {
		if p == "" {
			return
		}
		parts = append(parts, p)
		sparts = append(sparts, s)
	}

	if m := Meter(t.Criteria); m != "" {
		add(m, dimStyle.Render(m))
	}

	switch t.Lifecycle {
	case "in_progress":
		if t.Claim != nil && t.Claim.Worker != "" {
			add(t.Claim.Worker, dimStyle.Render(t.Claim.Worker))
			if age := AgeBadge(t.Claim.ClaimedAt, now); age != "" {
				st := roleStyle(claimRole(t.Claim.ClaimedAt, now))
				add(age, st.Render(age))
			}
		} else if p, s := staleBadge(t, now); p != "" {
			// An UNCLAIMED in_progress row has no claim-age tint to alarm it —
			// day-scale staleness must still be impossible to miss.
			add(p, s)
		}
	case "blocked":
		tok := "blocked"
		if t.DependencyCount > 0 {
			tok = fmt.Sprintf("blocked ·%d", t.DependencyCount)
		}
		add(tok, warnStyle.Render(tok))
		if p, s := staleBadge(t, now); p != "" {
			add(p, s)
		}
	case "ready", "open":
		if t.Priority != "" {
			add(t.Priority, dimStyle.Render(t.Priority))
		}
		if p, s := staleBadge(t, now); p != "" {
			add(p, s)
		}
	case "done", "closed":
		if age := AgeBadge(t.UpdatedAt, now); age != "" {
			add(age, dimStyle.Render(age))
		}
	}
	return strings.Join(parts, "  "), strings.Join(sparts, "  ")
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

// TaskRow renders one task. Collapsed = a single line
//
//	indent + ▸glyph + [⧉] + title  ·chips·  …right-meta
//
// expanded = that line plus hanging-indent detail lines. Everything is
// width-safe. sectionTag is the tag of the section the row sits under (the
// enclosing derived-cluster key; "" in epics/NOW/orphans): a chip equal to it
// is suppressed so a row never restates its own section. Column priority when
// the pane is tight: title (never below 8 cols) > chips > right-meta. Meta
// sheds first, then chips; below dropMetaBelow the row is glyph+title only.
// frame is the heartbeat index threaded down to the status glyph (an
// in_progress row spins with it); the caller passes st.Frame (0 at rest).
func TaskRow(t Task, selected, expanded bool, indent, width int, sectionTag string, frame int, now time.Time) []string {
	role := RoleFor(t, now)
	marker := SelectionMarker(selected)
	glyph := roleStyle(role).Render(StatusGlyph(t.Lifecycle, frame))
	// Gutter is a fixed 2 display columns: selection marker + status glyph.
	gutter := marker + glyph
	lead := strings.Repeat(" ", indent) + gutter + " "
	leadW := indent + 2 + 1
	tStyle := titleStyleFor(t.Lifecycle)

	// Twin marker (decision 14): a warn-tinted ⧉ layered before the title of any
	// suspected near-duplicate. Two display columns (glyph + space) charged
	// against the title budget — it never disturbs the fixed gutter.
	twin, twinW := "", 0
	if t.TwinOf != "" {
		twin = warnStyle.Render("⧉") + " "
		twinW = 2
	}

	var line string
	if width < dropMetaBelow {
		// Narrow degrade: glyph + [twin] + title only (no chips, no meta).
		line = lead + twin + tStyle.Render(truncate(t.Title, width-leadW-twinW))
	} else {
		metaPlain, metaStyled := rowMeta(t, now)
		metaW := disp(metaPlain)

		// Reserve the right-meta first — it sheds first when the row is tight.
		titleBudget := width - leadW - twinW
		if metaPlain != "" && titleBudget-metaW-2 >= 8 {
			titleBudget -= metaW + 2 // 2 = min gap before meta
		} else {
			metaPlain, metaStyled, metaW = "", "", 0
		}

		// Title takes its natural width (up to the budget); chips get the
		// leftover, after a 2-space gap — so a long title squeezes chips out
		// before it clips itself.
		title := truncate(t.Title, titleBudget)
		chipBudget := titleBudget - disp(title) - 2
		chips := ""
		if chipBudget >= chipMinBudget {
			chips = Chips(t.Labels, t.Suggested, sectionTag, chipBudget)
		}

		left := lead + twin + tStyle.Render(title)
		if chips != "" {
			left += "  " + chips
		}
		if metaPlain == "" {
			line = left
		} else {
			gap := width - disp(left) - metaW
			if gap < 1 {
				gap = 1
			}
			line = left + strings.Repeat(" ", gap) + metaStyled
		}
	}

	out := []string{line}
	if expanded {
		out = append(out, expandedDetail(t, indent, width, now)...)
	}
	return out
}

// expandedDetail is the hanging-indent body shown under an expanded row.
func expandedDetail(t Task, indent, width int, now time.Time) []string {
	hang := strings.Repeat(" ", indent+3) // align under the title column
	var lines []string
	emit := func(s string) {
		if s == "" {
			return
		}
		lines = append(lines, dimStyle.Render(truncate(hang+s, width)))
	}

	// The criteria line is a real ☐/☑ checklist (decision 18): watching an agent
	// tick a box is the board's checklists-that-fill-themselves moment. It
	// returns pre-styled lines (met ok-tinted, unmet dim) and falls back to the
	// compact "criteria ▰▰▱ 2/3" meter when only the counter survived, so it is
	// appended directly rather than through the dim-wrapping emit.
	lines = append(lines, CriteriaChecklist(t.CriteriaItems, t.Criteria, indent, width)...)
	if len(t.Labels) > 0 {
		// The detail line has room, so EVERY label paints (ChipsAll — the
		// expanded view is the one place the full tag set must be visible) with
		// its identity hue true (no outer dim wrapper), so the same tag reads
		// the same color here as on the collapsed row.
		if chips := ChipsAll(t.Labels, "", "", width-len(hang)-len("labels ")); chips != "" {
			lines = append(lines, truncate(hang+dimStyle.Render("labels ")+chips, width))
		}
	}
	if t.TwinOf != "" {
		// Name the twin partner (decision 14) in words: BuildBoard precomputes the
		// partner title onto the Task, so the expanded row reads "twin ⧉ 'Add a SUM
		// function'" instead of an opaque doc id. Fall back to the doc id only when
		// the title is unknown (empty-titled partner), so it never renders blank.
		partner := t.TwinTitle
		if partner == "" {
			partner = t.TwinOf
		}
		emit(fmt.Sprintf("twin ⧉ '%s'", partner))
	}
	deps := depSummary(t)
	emit(deps)
	if t.Priority != "" || !t.UpdatedAt.IsZero() {
		bc := t.Priority
		if age := AgeBadge(t.UpdatedAt, now); age != "" {
			if bc != "" {
				bc += " · "
			}
			bc += "updated " + age
		}
		emit(bc)
	}
	return lines
}

func depSummary(t Task) string {
	var b []string
	if t.DependencyCount > 0 {
		b = append(b, fmt.Sprintf("%d blocking", t.DependencyCount))
	}
	if t.DependentCount > 0 {
		b = append(b, fmt.Sprintf("%d dependent", t.DependentCount))
	}
	if len(b) == 0 {
		return ""
	}
	return "deps " + strings.Join(b, " · ")
}

// criteriaCap is how many checklist lines CriteriaChecklist keeps when it
// folds the remainder into a "… +N more" tail — enough to read a task's shape
// at a glance without letting a 30-criterion goal shove the spine offscreen.
// The fold only fires when it saves at least one line (N >= 2), so the tallest
// unfolded checklist is criteriaCap+1 lines.
const criteriaCap = 8

// CriteriaChecklist renders acceptance criteria as a real ☐/☑ checklist — one
// hanging-indent line per criterion, a met item ok-tinted (its ☑ reads as work
// that has LANDED, the fleet's checklists-that-fill-themselves moment) and an
// unmet item dim. It is the expanded-detail upgrade of the compact Meter: when
// the decoded item list is present it paints the text; when only the {met,total}
// counter survived (a payload without content, an older server) it falls back to
// the single "criteria ▰▰▱ 2/3" meter line so the detail is never emptier than
// before. Every line is width-safe; a long set folds past criteriaCap to a dim
// "… +N more" tail. A malformed (textless) entry keeps its slot as a bare ☐ —
// honest that an Nth criterion exists even when its text did not decode.
// nil/empty items with a nil/zero Criteria render nothing.
func CriteriaChecklist(items []CriterionItem, c *Criteria, indent, width int) []string {
	hang := strings.Repeat(" ", indent+3) // align under the title column, like expandedDetail
	if len(items) == 0 {
		if m := Meter(c); m != "" {
			return []string{dimStyle.Render(truncate(hang+"criteria "+m, width))}
		}
		return nil
	}
	// Fold only when it SAVES lines: at criteriaCap+1 items the "… +1 more"
	// tail would spend its line hiding exactly one item — same height, less
	// truth — so that one extra item paints instead.
	shown, folded := items, 0
	if len(items) > criteriaCap+1 {
		shown, folded = items[:criteriaCap], len(items)-criteriaCap
	}
	lines := make([]string, 0, len(shown)+1)
	for _, it := range shown {
		glyph, style := "☐", dimStyle
		if it.Met {
			glyph, style = "☑", okStyle
		}
		line := hang + glyph
		if it.Criterion != "" {
			line += " " + it.Criterion
		}
		lines = append(lines, style.Render(truncate(line, width)))
	}
	if folded > 0 {
		lines = append(lines, dimStyle.Render(truncate(hang+fmt.Sprintf("… +%d more", folded), width)))
	}
	return lines
}

// NowCard is a pinned two-line claim card:
//
//	◴ Wire the SSE live bridge
//	   opus-3 · 4m · ▰▰▱ 2/3 · Cloud GUI epic
//
// breadcrumb is the parent epic's title (the caller resolves ParentID).
// NOW cards are cursor rows (the first indexes in the shell's visibleRows), so
// like TaskRow they carry a leading selection-marker column: ▶ when the cursor
// is on this card, a space otherwise (keeps every card's glyph aligned).
func NowCard(t Task, breadcrumb string, selected bool, width, frame int, now time.Time) []string {
	role := RoleFor(t, now)
	glyph := roleStyle(role).Render(StatusGlyph(t.Lifecycle, frame))
	// Twin marker (decision 14), same ⧉ TaskRow wears: a claim on a suspected
	// near-duplicate is the board's loudest "two of us are doing the same work"
	// moment, so the pinned card may not hide it.
	twin, twinW := "", 0
	if t.TwinOf != "" {
		twin = warnStyle.Render("⧉") + " "
		twinW = 2
	}
	title := truncate(t.Title, width-3-twinW)
	line1 := SelectionMarker(selected) + glyph + " " + twin + titleStyle.Render(title)

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
	if m := Meter(t.Criteria); m != "" {
		add(m, dimStyle.Render(m))
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
