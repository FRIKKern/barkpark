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

// StatusGlyph is the 2-col gutter's status mark — ONE steady 4-glyph vocabulary
// (the calm-board subtraction, charter D14): ● in_progress, ◐ blocked,
// ○ ready|open, ✓ done|closed. There is no animation: liveness is carried by the
// NOW band's ticking claim age and the flash-on-change emphasis, never a spinning
// glyph, so a resting row is dead still. Selection is a separate marker
// (SelectionMarker) rendered in the column before it; styling (the role tint /
// dim recede) is applied by callers, as before. An unknown lifecycle degrades to
// the neutral "·" dot.
func StatusGlyph(lifecycle string) string {
	switch lifecycle {
	case "in_progress":
		return "●"
	case "blocked":
		return "◐"
	case "done", "closed":
		return "✓"
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
//	── Cloud GUI epic ───────────────────────────── 7/12
//
// The calm-board subtraction retired the ▰▱ progress bar; the dim "7/12" digits
// carry the same completion at a glance without a second glyph vocabulary. A
// Dormant epic renders exactly the same header line (its children are folded
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
	right := fmt.Sprintf("%d/%d", done, total)
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

// rowMeta is the ONE dim right-aligned token a collapsed spine row wears (the
// calm-board subtraction, charter D14): criteria meters, twin glyphs and
// suggested chips all left the list — they reappear in the detail view where a
// reader asked for them. It returns the plain text plus the styled text (same
// display width) so the caller can right-align on the plain width and print the
// styled version. One token per state:
//
//   - in_progress: "worker age" (claim-age tinted by the lease), or the stale
//     day-age when the row is in_progress but unclaimed (no lease to alarm it);
//   - blocked:     "blocked" (warn), or the stale day-age once it has rotted;
//   - ready/open:  the stale day-age when stale, else the priority;
//   - done/closed: the resolved age.
func rowMeta(t Task, now time.Time) (plain, styled string) {
	switch t.Lifecycle {
	case "in_progress":
		if t.Claim != nil && t.Claim.Worker != "" {
			worker := t.Claim.Worker
			if age := AgeBadge(t.Claim.ClaimedAt, now); age != "" {
				st := roleStyle(claimRole(t.Claim.ClaimedAt, now))
				return worker + " " + age, dimStyle.Render(worker) + " " + st.Render(age)
			}
			return worker, dimStyle.Render(worker)
		}
		// An UNCLAIMED in_progress row has no claim-age tint — day-scale
		// staleness must still be impossible to miss.
		return staleBadge(t, now)
	case "blocked":
		if p, s := staleBadge(t, now); p != "" {
			return p, s
		}
		return "blocked", warnStyle.Render("blocked")
	case "ready", "open":
		if p, s := staleBadge(t, now); p != "" {
			return p, s
		}
		if t.Priority != "" {
			return t.Priority, dimStyle.Render(t.Priority)
		}
		return "", ""
	case "done", "closed":
		if age := AgeBadge(t.UpdatedAt, now); age != "" {
			return age, dimStyle.Render(age)
		}
		return "", ""
	default:
		return staleBadge(t, now)
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

// TaskRow renders one task. Collapsed = a single calm line
//
//	indent + ▎glyph + title              …right-meta
//
// expanded = that line plus a minimal hanging-indent detail stub. The calm-board
// subtraction stripped the list to its essence: ONE status glyph in the gutter,
// a monochrome-dim title, and ONE dim right-meta token — chips, twin ⧉ glyphs and
// criteria meters all moved to the detail view. Everything is width-safe; when
// tight the meta sheds first (title never clips below 8 cols), and below
// dropMetaBelow the row is glyph + title only.
func TaskRow(t Task, selected, expanded bool, indent, width int, now time.Time) []string {
	role := RoleFor(t, now)
	marker := SelectionMarker(selected)
	glyph := roleStyle(role).Render(StatusGlyph(t.Lifecycle))
	// Gutter is a fixed 2 display columns: selection marker + status glyph.
	gutter := marker + glyph
	lead := strings.Repeat(" ", indent) + gutter + " "
	leadW := indent + 2 + 1
	tStyle := titleStyleFor(t.Lifecycle)

	var line string
	if width < dropMetaBelow {
		// Narrow degrade: glyph + title only (no meta).
		line = lead + tStyle.Render(truncate(t.Title, width-leadW))
	} else {
		metaPlain, metaStyled := rowMeta(t, now)
		metaW := disp(metaPlain)

		// Reserve the right-meta first — it sheds first when the row is tight.
		titleBudget := width - leadW
		if metaPlain != "" && titleBudget-metaW-2 >= 8 {
			titleBudget -= metaW + 2 // 2 = min gap before meta
		} else {
			metaPlain, metaStyled, metaW = "", "", 0
		}

		title := truncate(t.Title, titleBudget)
		left := lead + tStyle.Render(title)
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

// expandedDetail is the MINIMAL hanging-indent stub shown under an expanded row
// (charter D23): the subtraction pass shrank inline expand to a criteria stub +
// one dim meta line so `enter` stays alive until the navigation shell replaces
// the whole mechanism with a real detail frame next wave. Labels, twin naming and
// dependency prose all moved to that frame — here a thin task stays thin.
func expandedDetail(t Task, indent, width int, now time.Time) []string {
	hang := strings.Repeat(" ", indent+3) // align under the title column
	var lines []string

	// The criteria stub is a real ○/✓ checklist — watching an agent tick a box is
	// the board's checklists-that-fill-themselves moment. It returns pre-styled
	// lines (met ok-tinted, unmet dim), so it is appended directly.
	lines = append(lines, CriteriaChecklist(t.CriteriaItems, t.Criteria, indent, width)...)

	if t.Priority != "" || !t.UpdatedAt.IsZero() {
		bc := t.Priority
		if age := AgeBadge(t.UpdatedAt, now); age != "" {
			if bc != "" {
				bc += " · "
			}
			bc += "updated " + age
		}
		if bc != "" {
			lines = append(lines, dimStyle.Render(truncate(hang+bc, width)))
		}
	}
	return lines
}

// criteriaCap is how many checklist lines CriteriaChecklist keeps when it
// folds the remainder into a "… +N more" tail — enough to read a task's shape
// at a glance without letting a 30-criterion goal shove the spine offscreen.
// The fold only fires when it saves at least one line (N >= 2), so the tallest
// unfolded checklist is criteriaCap+1 lines.
const criteriaCap = 8

// CriteriaChecklist renders acceptance criteria as a real ○/✓ checklist — one
// hanging-indent line per criterion, a met item ok-tinted (its ✓ reads as work
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
		glyph, style := "○", dimStyle
		if it.Met {
			glyph, style = "✓", okStyle
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
//	● Wire the SSE live bridge
//	   opus-3 · 4m · 2/3 · Cloud GUI epic
//
// breadcrumb is the parent epic's title (the caller resolves ParentID).
// NOW cards are cursor rows (the first indexes in the shell's visibleRows), so
// like TaskRow they carry a leading selection-marker column: ▎ when the cursor
// is on this card, a space otherwise (keeps every card's glyph aligned). The
// calm-board subtraction retired the animated glyph, the ▰▱ meter (digits stay)
// and the twin ⧉ marker (it lives in the detail view now).
func NowCard(t Task, breadcrumb string, selected bool, width int, now time.Time) []string {
	role := RoleFor(t, now)
	glyph := roleStyle(role).Render(StatusGlyph(t.Lifecycle))
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
