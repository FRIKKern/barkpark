package taskboard

import (
	"time"

	"github.com/FRIKKern/barkpark/internal/semrole"
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

// palette is the board's theme-resolved color set. buildPalette(theme) is the
// RELOCATION ts-w4c installs: the lifecycle/status/chrome hues that were bound at
// package init (flattening the evergreen skin into the styles below) now derive
// inside a builder that takes a theme id, so a resolved theme can flow to the
// board instead of being hardwired. Only "evergreen" exists today, so the
// defaultPalette bound below is byte-identical to the former init bindings — the
// goldens stay frozen — and a later wave threads a config/env theme id into the
// board Model to rebuild the palette per theme.
type palette struct {
	ok, danger                          lipgloss.AdaptiveColor
	info, warn, done, ready, open, canc lipgloss.AdaptiveColor
	neutral, dim, title, accent         lipgloss.AdaptiveColor
	pressedBg                           lipgloss.AdaptiveColor
}

// buildPalette resolves one theme id's board palette. The LIFECYCLE hues
// (info/warn/done/ready/open/cancel) READ the emitted lifecycle tokens via
// Resolve(theme) (tokens_gen.go, from design/tokens.json); the STATUS hues
// (ok/danger) READ semrole's generated status tones via RoleColorFor; and the
// neutral/dim/title CHROME reads semrole's cliChrome roles via ChromeColorFor —
// none re-type hex, so the board can never drift from the shared manifest the
// other surfaces read, and a theme change moves all three together. Panics on an
// unknown semrole role/chrome key (a compile-time-constant programmer error).
func buildPalette(theme string) palette {
	life := Resolve(theme).Lifecycle
	genColor := func(key string) lipgloss.AdaptiveColor {
		tok := life[key]
		return lipgloss.AdaptiveColor{Light: tok.ColorLight, Dark: tok.ColorDark}
	}
	statusTone := func(role string) lipgloss.AdaptiveColor {
		c, ok := semrole.RoleColorFor(theme, role)
		if !ok {
			panic("taskboard: unknown semrole role " + role)
		}
		return c
	}
	chrome := func(role string) lipgloss.AdaptiveColor {
		c, ok := semrole.ChromeColorFor(theme, role)
		if !ok {
			panic("taskboard: unknown semrole chrome role " + role)
		}
		return c
	}
	return palette{
		ok:     statusTone("ok"),     // GRADUATED: generated status.ok; distinct from done teal
		danger: statusTone("danger"), // GRADUATED: generated status.danger; P0/P1 severity

		info:  genColor("in_progress"), // in_progress blue (tokens_gen)
		warn:  genColor("blocked"),     // blocked amber (tokens_gen)
		done:  genColor("done"),        // done TEAL glyph (tokens_gen) — distinct from ok
		ready: genColor("ready"),       // ready ○ = full foreground (tokens_gen)
		open:  genColor("open"),        // open ○ ≈ dim backlog (tokens_gen)
		canc:  genColor("cancelled"),   // cancelled ✕ dim (tokens_gen)

		neutral: chrome("chrome-text-secondary"), // zinc mid chrome (chrome_gen)
		dim:     chrome("chrome-dim"),            // zinc dim chrome (chrome_gen)
		title:   chrome("chrome-ink"),            // near-fg title chrome (chrome_gen)
		accent:  chrome("chrome-accent"),         // pointer-hover row highlight (chrome_gen)

		// The board's ONE legitimate background state (charter D94/D95), read from
		// an EXISTING chrome role — zero new colors: the stronger selection tint
		// reserved for ttm-s4's verb affordances (the desk's selected-item bg,
		// styles.go:48). Rows never wear a background — a hovered row restyles its
		// FOREGROUND to accent instead (hoverStyle).
		pressedBg: chrome("chrome-selection-bg"), // pressed affordance — reserved for ttm-s4
	}
}

// defaultPalette is the evergreen board palette, bound at package init from the
// emitted tokens. The style vars below read it, so every board render uses the
// default skin until a wave threads a resolved theme id to the Model.
var defaultPalette = buildPalette(DefaultTheme)

// The design-language spec §1 terminal values (charter D37), projected from
// defaultPalette so every existing call site keeps its byte-frozen colour.
var (
	okColor     = defaultPalette.ok
	dangerColor = defaultPalette.danger

	infoColor   = defaultPalette.info
	warnColor   = defaultPalette.warn
	doneColor   = defaultPalette.done
	readyColor  = defaultPalette.ready
	openColor   = defaultPalette.open
	cancelColor = defaultPalette.canc

	neutralColor = defaultPalette.neutral
	dimColor     = defaultPalette.dim
	titleColor   = defaultPalette.title
	accentColor  = defaultPalette.accent

	// pressedBgColor is the verb-affordance background tint verbHoverStyle
	// paints on a hovered footer verb (charter D94/D95) — the board's only
	// background state now that row hover is a foreground restyle.
	pressedBgColor = defaultPalette.pressedBg
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

	// hoverStyle is the pointer-hover row highlight, on the chat TUI's
	// Phases-pane selection grammar (chat/render.go focusBar + titleStyle): the
	// hovered row re-renders whole in the bold accent FOREGROUND — no background
	// bar, and sibling rows keep full brightness (the earlier bg-tint +
	// faint-recede picker law is retired). hoverPaint strips the row's own
	// lifecycle/priority hues first so the accent reads uniformly, the way the
	// selected phase row does. Transient pointer state only; with no live hover
	// the frame is byte-identical, so goldens and the at-rest aliveness budget
	// are untouched.
	hoverStyle = lipgloss.NewStyle().Foreground(accentColor).Bold(true)

	// verbHoverStyle is the pointer-hover affordance on a clickable footer verb
	// (charter D96), on the D94 background vocabulary: verbs wear the STRONGER
	// chrome-selection-bg tint (pressedBg — rows keep the subtle chrome-cursor-bg
	// hover), never a new color. The tint is a near-surface shade, so lifting the
	// ink from dim to title keeps the token legible AND brighter than its rest
	// state — the hover reads as "lit up", not inverted. Transient pointer state
	// only, painted while a verb is under the cursor; "color = state" stays intact.
	verbHoverStyle = lipgloss.NewStyle().Foreground(titleColor).Background(pressedBgColor)

	// The wide divider steps through three pointer states without changing
	// geometry: subdued at rest, readable on hover, and bold accent while held.
	// Terminal cells have no alpha channel, so palette brightness is the honest
	// opacity analogue.
	dividerRestStyle    = lipgloss.NewStyle().Foreground(dimColor)
	dividerHoverStyle   = lipgloss.NewStyle().Foreground(neutralColor)
	dividerGrabbedStyle = lipgloss.NewStyle().Foreground(accentColor).Bold(true)
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
