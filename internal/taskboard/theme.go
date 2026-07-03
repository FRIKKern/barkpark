package taskboard

import (
	"time"

	"github.com/charmbracelet/lipgloss"
)

// Role is the board's semantic color vocabulary. The names mirror PR #979's
// CLI statusRole set (ok/info/warn/danger) exactly so a later reconciliation
// slice can extract them to a shared internal package without a rename. Color
// means STATE here, never decoration — RoleFor is the single mapping point.
type Role int

const (
	RoleNeutral Role = iota // ready/open — no urgency, dim-ish default
	RoleOK                  // done/closed — resolved (rendered dim)
	RoleInfo                // in_progress — actively moving
	RoleWarn                // blocked, or a claim leaning on its lease
	RoleDanger              // a claim past its lease / offline
)

// String is the #979-compatible role name (used by mapping tests).
func (r Role) String() string {
	switch r {
	case RoleOK:
		return "ok"
	case RoleInfo:
		return "info"
	case RoleWarn:
		return "warn"
	case RoleDanger:
		return "danger"
	default:
		return "neutral"
	}
}

// Palette — hues taken verbatim from cmd/barkpark/styles.go (greenDot/amberDot/
// blueDot + the zinc dims) plus a danger red, kept as AdaptiveColor so the pane
// reads in both light and dark terminals.
var (
	okColor      = lipgloss.AdaptiveColor{Light: "#10b981", Dark: "#34d399"} // greenDot
	infoColor    = lipgloss.AdaptiveColor{Light: "#3b82f6", Dark: "#60a5fa"} // blueDot
	warnColor    = lipgloss.AdaptiveColor{Light: "#f59e0b", Dark: "#fbbf24"} // amberDot
	dangerColor  = lipgloss.AdaptiveColor{Light: "#dc2626", Dark: "#f87171"} // red
	neutralColor = lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"} // zinc mid
	dimColor     = lipgloss.AdaptiveColor{Light: "#a1a1aa", Dark: "#52525b"} // zinc dim
	titleColor   = lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"} // near-fg
)

var (
	okStyle      = lipgloss.NewStyle().Foreground(okColor)
	infoStyle    = lipgloss.NewStyle().Foreground(infoColor)
	warnStyle    = lipgloss.NewStyle().Foreground(warnColor)
	dangerStyle  = lipgloss.NewStyle().Foreground(dangerColor)
	neutralStyle = lipgloss.NewStyle().Foreground(neutralColor)

	dimStyle   = lipgloss.NewStyle().Foreground(dimColor)
	titleStyle = lipgloss.NewStyle().Foreground(titleColor).Bold(true)
	boldStyle  = lipgloss.NewStyle().Bold(true)
)

// Chip hues — IDENTITY color, one per chipSlot. Deliberately muted (pastel/300-
// level on dark, mid-600 on light) so they read one notch softer than the four
// saturated ROLE colors above: a chip can never be misread as a state signal.
// The family (violet/cyan/rose/lime/fuchsia/orange) is spread across the wheel
// so six co-visible tags stay mutually distinguishable, and each is kept clear
// of its nearest role neighbour (lime vs ok-emerald, cyan vs info-blue, orange
// vs warn-amber, rose vs danger-red). Slot 4 is fuchsia, NOT sky: sky-300 sat
// ~12° of hue from cyan-300 and next door to info-blue — three co-visible light
// blues were a glance hazard. AdaptiveColor so both terminal themes read.
var chipColors = [chipSlotCount]lipgloss.AdaptiveColor{
	{Light: "#7c3aed", Dark: "#c4b5fd"}, // 0 violet
	{Light: "#0891b2", Dark: "#67e8f9"}, // 1 cyan
	{Light: "#be123c", Dark: "#fda4af"}, // 2 rose
	{Light: "#4d7c0f", Dark: "#bef264"}, // 3 lime
	{Light: "#a21caf", Dark: "#f0abfc"}, // 4 fuchsia
	{Light: "#c2410c", Dark: "#fdba74"}, // 5 orange
}

var chipStyles = func() [chipSlotCount]lipgloss.Style {
	var s [chipSlotCount]lipgloss.Style
	for i, c := range chipColors {
		s[i] = lipgloss.NewStyle().Foreground(c)
	}
	return s
}()

// chipStyle resolves a chip slot to its identity style. Defensive modulo keeps a
// caller that hands a raw hash (rather than a chipSlot result) in bounds.
func chipStyle(slot int) lipgloss.Style {
	slot = ((slot % chipSlotCount) + chipSlotCount) % chipSlotCount
	return chipStyles[slot]
}

// roleStyle resolves a Role to its lipgloss style. Done is intentionally
// rendered dim (resolved work should recede, not shout green).
func roleStyle(r Role) lipgloss.Style {
	switch r {
	case RoleOK:
		return dimStyle
	case RoleInfo:
		return infoStyle
	case RoleWarn:
		return warnStyle
	case RoleDanger:
		return dangerStyle
	default:
		return neutralStyle
	}
}

// leaseTTL is how long a claim is considered live before its lease is spent.
// Barkpark's claim leases are 5 minutes; the tint escalates as the lease nears
// expiry so a stalling claim visibly turns amber, then red.
const leaseTTL = 5 * time.Minute

// claimRole tints a live claim by how much of its lease is burned:
// info while fresh, warn past ~70%, danger once the lease is spent.
func claimRole(claimedAt, now time.Time) Role {
	age := now.Sub(claimedAt)
	switch {
	case age >= leaseTTL:
		return RoleDanger
	case age >= leaseTTL*7/10:
		return RoleWarn
	default:
		return RoleInfo
	}
}

// Staleness thresholds — day-scale, distinct from the minute-scale claim lease.
// A live task that has not MOVED in this long is drifting; the tint warms so an
// outdated row is impossible to miss. Boundaries are exclusive (a task at exactly
// the threshold is not yet stale), matching board.go's doneFoldAfter convention.
const (
	staleWarnAfter   = 3 * 24 * time.Hour
	staleDangerAfter = 7 * 24 * time.Hour
)

// staleRole grades a task by time-since-last-update, independent of lifecycle
// role: RoleWarn past 3 days, RoleDanger past 7, RoleNeutral while fresh. A
// TERMINAL task (done/closed/cancelled) is ALWAYS neutral — finished work cannot
// go stale, so an old done row never falsely wears an alarm. This drives the
// day-scale age badge the renderer appends to aging open/ready/blocked rows
// (and to unclaimed in_progress rows, which have no claim-age tint to alarm them).
func staleRole(updatedAt, now time.Time, lifecycle string) Role {
	switch lifecycle {
	case "done", "closed", "cancelled":
		return RoleNeutral
	}
	age := now.Sub(updatedAt)
	switch {
	case age > staleDangerAfter:
		return RoleDanger
	case age > staleWarnAfter:
		return RoleWarn
	default:
		return RoleNeutral
	}
}

// RoleFor is the single lifecycle -> semantic-role mapping (charter decision 6):
// in_progress -> info (escalating via the claim lease), blocked -> warn,
// done/closed -> ok(dim), ready/open -> neutral.
func RoleFor(t Task, now time.Time) Role {
	switch t.Lifecycle {
	case "in_progress":
		if t.Claim != nil && !t.Claim.ClaimedAt.IsZero() {
			return claimRole(t.Claim.ClaimedAt, now)
		}
		return RoleInfo
	case "blocked":
		return RoleWarn
	case "done", "closed":
		return RoleOK
	default: // ready, open, unknown
		return RoleNeutral
	}
}

// stripStyle resolves an action-strip Role to its lipgloss style. Unlike
// roleStyle (where RoleOK is deliberately DIM — resolved work recedes), a
// successful action must SHOUT: an ok confirmation renders in the full green,
// so the pane visibly acknowledges the claim/close the moment it lands.
func stripStyle(r Role) lipgloss.Style {
	switch r {
	case RoleOK:
		return okStyle
	case RoleWarn:
		return warnStyle
	case RoleDanger:
		return dangerStyle
	default:
		return neutralStyle
	}
}

// connRole colors the header connection dot honestly.
func connRole(c ConnState) Role {
	switch c {
	case ConnLive:
		return RoleOK
	case ConnPolling:
		return RoleWarn
	default:
		return RoleDanger
	}
}
