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

// genColor lifts a generated lifecycle token's light/dark hues (tokens_gen.go,
// emitted from the ONE evergreen design/tokens.json) into a lipgloss
// AdaptiveColor. It is the seam that makes the board READ the emitted token
// source instead of re-typing its hex — the de-duplication this slice installs.
// A missing key yields the zero AdaptiveColor, which the goldens catch at once.
func genColor(key string) lipgloss.AdaptiveColor {
	tok := GenLifecycle[key]
	return lipgloss.AdaptiveColor{Light: tok.ColorLight, Dark: tok.ColorDark}
}

// Palette — the design-language spec §1 terminal values (charter D37). The
// LIFECYCLE hues (info/warn/done/ready/open/cancel) are now SOURCED from
// tokens_gen.go via genColor, so they can never drift from the shared manifest
// the other surfaces read; refreshing them is a generation-time concern, never a
// role remap (RoleFor is untouched). The remaining colors have NO lifecycle twin
// and stay hand-authored: okColor is the DISTINCT green (cloud health / live-dot
// / action-strip ok — the spec's teal completion hue is doneColor, so restyling
// the done glyph never shifts deploy-table semantics), dangerColor is the
// priority-severity red, and neutral/dim/title are chrome. A later ratchet slice
// decides whether those graduate into the generated set.
var (
	okColor     = lipgloss.AdaptiveColor{Light: "#10b981", Dark: "#34d399"} // greenDot — health/live/ok-strip; NO lifecycle twin (done is teal)
	dangerColor = lipgloss.AdaptiveColor{Light: "#dc2626", Dark: "#f87171"} // P0/P1 red (spec §1); NO lifecycle twin

	infoColor   = genColor("in_progress") // in_progress blue (tokens_gen)
	warnColor   = genColor("blocked")     // blocked amber (tokens_gen)
	doneColor   = genColor("done")        // done TEAL glyph (tokens_gen) — distinct from okColor
	readyColor  = genColor("ready")       // ready ○ = full foreground (tokens_gen)
	openColor   = genColor("open")        // open ○ ≈ dim backlog (tokens_gen)
	cancelColor = genColor("cancelled")   // cancelled ✕ dim (tokens_gen)

	neutralColor = lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"} // zinc mid — chrome, no lifecycle twin
	dimColor     = lipgloss.AdaptiveColor{Light: "#a1a1aa", Dark: "#52525b"} // zinc dim — chrome, no lifecycle twin
	titleColor   = lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"} // near-fg — chrome, no lifecycle twin
)

var (
	okStyle      = lipgloss.NewStyle().Foreground(okColor)
	infoStyle    = lipgloss.NewStyle().Foreground(infoColor)
	warnStyle    = lipgloss.NewStyle().Foreground(warnColor)
	dangerStyle  = lipgloss.NewStyle().Foreground(dangerColor)
	doneStyle    = lipgloss.NewStyle().Foreground(doneColor)
	readyStyle   = lipgloss.NewStyle().Foreground(readyColor)
	openStyle    = lipgloss.NewStyle().Foreground(openColor)
	cancelStyle  = lipgloss.NewStyle().Foreground(cancelColor)
	neutralStyle = lipgloss.NewStyle().Foreground(neutralColor)

	dimStyle   = lipgloss.NewStyle().Foreground(dimColor)
	titleStyle = lipgloss.NewStyle().Foreground(titleColor).Bold(true)
	boldStyle  = lipgloss.NewStyle().Bold(true)
)

// glyphStyleFor paints the STATUS GLYPH by the spec §1 brightness+meaning ladder
// (charter D36/D37): the neutral "todo" spectrum is monochrome white (open dim →
// ready full-foreground), and color is reserved for the states that carry
// meaning — blue in_progress (escalating via the claim lease, board-only),
// amber blocked, teal done, dim cancelled. It is a RENDERING layer over RoleFor,
// never a role remap: done's glyph is teal here while roleStyle(RoleOK) still
// dims the done TITLE so finished work recedes.
func glyphStyleFor(t Task, now time.Time) lipgloss.Style {
	switch t.Lifecycle {
	case lifeInProgress:
		return roleStyle(RoleFor(t, now)) // blue when fresh, warms as the lease burns
	case lifeBlocked:
		return warnStyle
	case lifeDone, lifeClosed:
		return doneStyle
	case lifeCancelled:
		return cancelStyle
	case lifeReady:
		return readyStyle
	case lifeOpen:
		return openStyle
	default:
		return openStyle
	}
}

// priorityStyle is the color-SEVERITY of a priority token (spec §3): P0/P1 red,
// P2 amber, P3/P4 (and absent) dim. It keys on priorityRank so "0"/"P0" and a
// bare "3" all grade identically.
func priorityStyle(p string) lipgloss.Style {
	switch priorityRank(p) {
	case 0, 1:
		return dangerStyle
	case 2:
		return warnStyle
	default:
		return dimStyle
	}
}

// The per-tag chip hue engine was retired by the calm-board subtraction
// (charter D22): a label is identity, not state, and under the epic's law
// "color = state, never decoration" hued chips were decoration. Labels now render
// as dim monochrome text everywhere; only the four semantic ROLE colors above
// paint, and only where they mean state.

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
// the threshold is not yet stale), matching board.go's staleBandAfter convention.
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
