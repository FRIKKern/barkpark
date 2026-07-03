package taskboard

// ─────────────────────────────────────────────────────────────────────────────
// WIRING STUB — DELETE AT MERGE.
//
// This file provides the slice-14 primitives (chip hues + chipSlot/chipStyle/
// Chips and the day-scale staleRole) that slice 16 (render + shell integration)
// is BUILT AGAINST but does not own. When slice 14 lands them in their real
// homes (chips.go + theme.go) the lead DELETES this whole file — every symbol
// here is a placeholder implementation faithful enough to build the branch,
// pass its gate, and render eyeball-able goldens, nothing more.
//
// Signatures are the charter's FROZEN wave-3 contract, so render.go/program.go
// call sites need no change when the real implementations replace these:
//
//	func chipSlot(tag string) int
//	func chipStyle(slot int) lipgloss.Style
//	func Chips(labels []string, suggested, sectionTag string, budget int) string
//	func staleRole(updatedAt, now time.Time, lifecycle string) Role
// ─────────────────────────────────────────────────────────────────────────────

import (
	"fmt"
	"hash/fnv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// stubChipColors are 6 muted identity hues — deliberately low-chroma so they can
// never be mistaken for the 4 bold semantic role colors (chips mean IDENTITY,
// roles mean STATE). AdaptiveColor pairs so they read in light and dark panes.
var stubChipColors = [6]lipgloss.AdaptiveColor{
	{Light: "#7c6f9c", Dark: "#a89bc9"}, // muted violet
	{Light: "#4d7c86", Dark: "#7fb3bd"}, // muted teal
	{Light: "#8a6d3b", Dark: "#c2a878"}, // muted ochre
	{Light: "#6d7c4d", Dark: "#a6bd7f"}, // muted olive
	{Light: "#86556d", Dark: "#bd8ba6"}, // muted mauve
	{Light: "#556d86", Dark: "#8ba6bd"}, // muted slate
}

// chipSlot maps a FULL tag string to one of 6 palette slots by FNV-1a — same
// tag, same color, forever, no config. The hash input is the full tag (so
// "proj:sheets-parity" and "area:sheets-parity" never collide by accident even
// though their chip TEXT is the same).
func chipSlot(tag string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(tag))
	return int(h.Sum32() % 6)
}

// chipStyle resolves a slot to its muted foreground style.
func chipStyle(slot int) lipgloss.Style {
	if slot < 0 || slot >= len(stubChipColors) {
		slot = 0
	}
	return lipgloss.NewStyle().Foreground(stubChipColors[slot])
}

// chipText strips the taxonomy prefix for display only ("proj:sheets-parity" →
// "sheets-parity"); the hash always keys on the full tag.
func chipText(tag string) string {
	if i := strings.IndexByte(tag, ':'); i >= 0 && i+1 < len(tag) {
		return tag[i+1:]
	}
	return tag
}

// Chips renders the card-line identity chips: at most 2 hued chips + a dim "+N"
// overflow, then a dim "+key?" suggestion chip. A chip naming the section the
// row already sits in (sectionTag) is SUPPRESSED — never say the same thing
// twice on one row. Empty when the budget is too small to say anything honest.
func Chips(labels []string, suggested, sectionTag string, budget int) string {
	if budget < 12 {
		return ""
	}
	var kept []string
	for _, l := range labels {
		if l == "" || l == sectionTag {
			continue
		}
		kept = append(kept, l)
	}

	var out []string
	used, shown := 0, 0
	for _, l := range kept {
		if shown >= 2 {
			break
		}
		text := chipText(l)
		w := disp(text)
		if shown > 0 {
			w++ // separating space
		}
		if used+w > budget {
			break
		}
		out = append(out, chipStyle(chipSlot(l)).Render(text))
		used += w
		shown++
	}
	if over := len(kept) - shown; over > 0 {
		tok := fmt.Sprintf("+%d", over)
		if used+disp(tok)+1 <= budget {
			out = append(out, dimStyle.Render(tok))
			used += disp(tok) + 1
		}
	}
	if suggested != "" && suggested != sectionTag {
		tok := "+" + chipText(suggested) + "?"
		if used+disp(tok)+1 <= budget {
			out = append(out, dimStyle.Render(tok))
		}
	}
	return strings.Join(out, " ")
}

// staleRole is the day-scale age temperature (decision 13): a non-terminal row
// untouched > 3d is warn, > 7d danger; terminal rows and zero times are always
// neutral (finished work is never "stale"). Thresholds are exclusive, matching
// the board's other age boundaries.
func staleRole(updatedAt, now time.Time, lifecycle string) Role {
	if updatedAt.IsZero() || isTerminal(lifecycle) {
		return RoleNeutral
	}
	switch age := now.Sub(updatedAt); {
	case age > 7*24*time.Hour:
		return RoleDanger
	case age > 3*24*time.Hour:
		return RoleWarn
	default:
		return RoleNeutral
	}
}
