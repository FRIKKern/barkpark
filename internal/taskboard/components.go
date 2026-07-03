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

// StatusGlyph is the 2-col gutter's status mark. Selection is a separate
// marker (SelectionMarker) rendered in the column before it.
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
		}
	case "blocked":
		tok := "blocked"
		if t.DependencyCount > 0 {
			tok = fmt.Sprintf("blocked ·%d", t.DependencyCount)
		}
		add(tok, warnStyle.Render(tok))
	case "ready", "open":
		if t.Priority != "" {
			add(t.Priority, dimStyle.Render(t.Priority))
		}
	case "done", "closed":
		if age := AgeBadge(t.UpdatedAt, now); age != "" {
			add(age, dimStyle.Render(age))
		}
	}
	return strings.Join(parts, "  "), strings.Join(sparts, "  ")
}

// dropMetaBelow is the width under which rows shed their right-meta and keep
// only the glyph + title (the graceful sub-60-col degrade).
const dropMetaBelow = 52

// TaskRow renders one task. Collapsed = a single line
// (indent + ▸glyph + title …right-meta); expanded = that line plus
// hanging-indent detail lines. Everything is width-safe.
func TaskRow(t Task, selected, expanded bool, indent, width int, now time.Time) []string {
	role := RoleFor(t, now)
	marker := SelectionMarker(selected)
	glyph := roleStyle(role).Render(StatusGlyph(t.Lifecycle))
	// Gutter is a fixed 2 display columns: selection marker + status glyph.
	gutter := marker + glyph
	lead := strings.Repeat(" ", indent) + gutter + " "
	leadW := indent + 2 + 1

	metaPlain, metaStyled := rowMeta(t, now)
	tStyle := titleStyleFor(t.Lifecycle)

	var line string
	if width < dropMetaBelow || metaPlain == "" {
		titleMax := width - leadW
		title := truncate(t.Title, titleMax)
		line = lead + tStyle.Render(title)
	} else {
		metaW := disp(metaPlain)
		titleMax := width - leadW - metaW - 2 // 2 = minimum gap
		if titleMax < 8 {                     // no room for both — meta loses
			title := truncate(t.Title, width-leadW)
			line = lead + tStyle.Render(title)
		} else {
			title := truncate(t.Title, titleMax)
			gap := width - leadW - disp(title) - metaW
			if gap < 1 {
				gap = 1
			}
			line = lead + tStyle.Render(title) + strings.Repeat(" ", gap) + metaStyled
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

	if m := Meter(t.Criteria); m != "" {
		emit("criteria " + m)
	}
	if len(t.Labels) > 0 {
		emit("labels " + strings.Join(t.Labels, ", "))
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

// NowCard is a pinned two-line claim card:
//
//	● Wire the SSE live bridge
//	   opus-3 · 4m · ▰▰▱ 2/3 · Cloud GUI epic
//
// breadcrumb is the parent epic's title (the caller resolves ParentID).
// NOW cards are cursor rows (the first indexes in the shell's visibleRows), so
// like TaskRow they carry a leading selection-marker column: ▶ when the cursor
// is on this card, a space otherwise (keeps every card's glyph aligned).
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
