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

// sectionHint is the ONE claim-forward right rail shared by every section header
// — epics, derived clusters and the loose bucket (wave-7 decision 34):
//
//	3 ready · 7 done
//
// The READY count leads, tinted with the neutral/ready role (readiness is a
// STATE, so the tint is the legal claim cue under "color = state, never
// decoration"); the done tally trails dim. Ready is omitted at 0. A section with
// neither ready nor done shows its open count (dim) instead, and one with nothing
// to say at all returns "" for a bare rule. Returns (plain, styled) of equal
// display width so the caller aligns on the plain width and prints the styled.
func sectionHint(sc sectionCounts) (plain, styled string) {
	var pp, ss []string
	if sc.ready > 0 {
		s := fmt.Sprintf("%d ready", sc.ready)
		pp, ss = append(pp, s), append(ss, neutralStyle.Render(s))
	}
	if sc.done > 0 {
		s := fmt.Sprintf("%d done", sc.done)
		pp, ss = append(pp, s), append(ss, dimStyle.Render(s))
	}
	if len(pp) == 0 {
		if sc.open > 0 {
			s := fmt.Sprintf("%d open", sc.open)
			return s, dimStyle.Render(s)
		}
		return "", ""
	}
	return strings.Join(pp, " · "), strings.Join(ss, " · ")
}

// renderSectionHeader is the ONE rule-style section-header layout, shared by
// epics, derived clusters and the loose bucket so their claim-forward rails can
// never drift (wave-7 decision 34):
//
//	── Cloud GUI epic ───────────────────────── 3 ready · 7 done
//
// derived marks an inferred cluster: its title renders monochrome-dim and trails
// a dim "~". selected swaps the leading dash for the ▎ marker (both one column).
// The rail is sectionHint(sc); an empty rail lets the dashes run to the edge. The
// title is budgeted so at least minDashes survive; extreme widths degrade to a
// rule + title. The final truncate is the width safety net.
func renderSectionHeader(title string, derived, selected bool, sc sectionCounts, width int) string {
	if width < 8 {
		return truncate(title, width)
	}
	railPlain, railStyled := sectionHint(sc)
	railW := disp(railPlain)

	lead := "── "
	if selected {
		lead = "▎─ "
	}
	suffixW := 0
	if derived {
		suffixW = 2 // " ~"
	}

	const minDashes = 3
	// layout: lead + title + [ ~] + " " + dashes + [ " " + rail ]
	fixed := disp(lead) + suffixW + 1 // + the space after the title block
	titleMax := width - fixed - minDashes
	if railW > 0 {
		titleMax -= 1 + railW // space before rail + rail
	}
	if titleMax < 1 {
		// Extremely narrow: rule + title only, drop the rail.
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
		return truncate(left+strings.Repeat("─", mid), width)
	}
	mid := width - leftW - 1 - railW
	if mid < minDashes {
		mid = minDashes
	}
	return truncate(left+strings.Repeat("─", mid)+" "+railStyled, width)
}

// EpicHeader is the rule-style section header for an authored epic, carrying the
// claim-forward rail (wave-7 D34). The calm-board subtraction retired the ▰▱ bar;
// the rail's "N ready · M done" says what's claimable here at a glance. A folded
// epic (the default — see foldedEpic) renders exactly this one glanceable line.
func EpicHeader(e Epic, width int) string {
	return renderSectionHeader(e.Root.Title, false, false, countSection(e.Children, e.DoneFolded), width)
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
			// The live corpus stores priority as a bare digit ("0"..."4"); a lone
			// "0" on a row reads as cryptic noise. Prefix "P" so it reads as the
			// urgency it is (P0 most urgent) — matching the census/`bp` vocabulary.
			lbl := t.Priority
			if c := lbl[0]; c >= '0' && c <= '9' {
				lbl = "P" + lbl
			}
			return lbl, dimStyle.Render(lbl)
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

// TaskRow renders one task as a single calm line
//
//	indent + ▎glyph + title              …right-meta
//
// The calm-board subtraction stripped the list to its essence: ONE status glyph
// in the gutter, a monochrome-dim title, and ONE dim right-meta token — chips,
// twin ⧉ glyphs and criteria meters all moved to the detail FRAME (the
// navigation shell replaced the old inline expand with the stack, charter D11).
// Everything is width-safe; when tight the meta sheds first (title never clips
// below 8 cols), and below dropMetaBelow the row is glyph + title only.
func TaskRow(t Task, selected bool, indent, width int, now time.Time) []string {
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

	return []string{line}
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
