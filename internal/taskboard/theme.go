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
