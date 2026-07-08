package main

import (
	"github.com/FRIKKern/barkpark/internal/semrole"
	"github.com/charmbracelet/lipgloss"
)

// roleColor resolves one of the four semantic roles (ok/info/warn/danger) to its
// generated adaptive tone via the shared internal/semrole vocabulary — the CLI's
// seam onto design/tokens.json, so a status dot painted here means EXACTLY what
// the same role means in the SPA, Studio, and the portrait task board. It returns
// the AdaptiveColor unflattened, preserving the truecolor→256→16→NO_COLOR
// degradation ladder. It panics on an unknown role: callers pass compile-time
// constant role names, so a typo is a programmer error surfaced at startup rather
// than painted as an invisible zero-value colour.
func roleColor(role string) lipgloss.AdaptiveColor {
	c, ok := semrole.RoleColor(role)
	if !ok {
		panic("cmd/barkpark: unknown semrole role " + role)
	}
	return c
}

var (
	highlight = semrole.GenChromeAccent // chrome-accent
	dimText   = semrole.GenChromeDim    // chrome-dim

	// Status dots resolve through semrole off the generated status tones — no
	// inline hex. greenDot=ok / amberDot=warn / blueDot=info (design/tokens.json).
	greenDot = roleColor("ok")
	amberDot = roleColor("warn")
	blueDot  = roleColor("info")

	paneBorder = lipgloss.NewStyle().
			Border(lipgloss.NormalBorder(), false, true, false, false).
			BorderForeground(semrole.GenChromeBorder) // chrome-border

	activePaneBorder = lipgloss.NewStyle().
				Border(lipgloss.NormalBorder(), false, true, false, false).
				BorderForeground(semrole.GenChromeBorderActive) // chrome-border-active (reuse-of-info)

	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(semrole.GenChromeInk). // chrome-ink
			Padding(0, 1)

	selectedItemStyle = lipgloss.NewStyle().
				Background(semrole.GenChromeSelectionBg). // chrome-selection-bg
				Foreground(semrole.GenChromeSelectionFg)  // chrome-selection-fg

	normalItemStyle = lipgloss.NewStyle().
			Foreground(semrole.GenChromeTextSecondary) // chrome-text-secondary

	dimStyle = lipgloss.NewStyle().
			Foreground(dimText)

	statusPublished = lipgloss.NewStyle().Foreground(greenDot)
	statusDraft     = lipgloss.NewStyle().Foreground(amberDot)
	statusActive    = lipgloss.NewStyle().Foreground(blueDot)

	dividerStyle = lipgloss.NewStyle().
			Foreground(semrole.GenChromeBorder) // chrome-border (divider)

	editorLabelStyle = lipgloss.NewStyle().
				Foreground(semrole.GenChromeLabel). // chrome-label (reuse-of-muted-text)
				Bold(true)

	editorFieldStyle = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).
				BorderForeground(semrole.GenChromeFieldBorder). // chrome-field-border
				Padding(0, 1)

	toolbarStyle = lipgloss.NewStyle().
			Background(semrole.GenChromeToolbarBg).    // chrome-toolbar-bg
			Foreground(semrole.GenChromeTextSecondary) // chrome-text-secondary

	breadcrumbStyle = lipgloss.NewStyle().
			Foreground(dimText)

	breadcrumbActiveStyle = lipgloss.NewStyle().
				Foreground(semrole.GenChromeInk) // chrome-ink (Q1 fold: dark #d4d4d8→#e4e4e7)

	// Styles extracted from inline NewStyle() calls
	logoStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(highlight)

	activeTabStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(semrole.GenChromeInk) // chrome-ink (active-tab)

	publishBtnStyle = lipgloss.NewStyle().
			Background(semrole.GenChromePrimaryCta). // chrome-primary-cta (evergreen recolor)
			Foreground(semrole.GenChromeOnPrimary).  // chrome-on-primary
			Bold(true).
			Padding(0, 2)

	selectActiveStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(highlight)

	inactiveCursorStyle = lipgloss.NewStyle().
				Foreground(semrole.GenChromeTextSecondary). // chrome-text-secondary (cursor fg)
				Background(semrole.GenChromeCursorBg)       // chrome-cursor-bg

	focusedFieldStyle = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).
				BorderForeground(highlight).
				Padding(0, 1)
)

func statusStyle(status string) lipgloss.Style {
	switch status {
	case "published", "completed":
		return statusPublished
	case "active":
		return statusActive
	default:
		return statusDraft
	}
}
