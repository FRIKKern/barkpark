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
	highlight = lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#60a5fa"} // lit-allow: chrome accent, no generated twin — au-w4-cli-chrome-tokens
	dimText   = lipgloss.AdaptiveColor{Light: "#a1a1aa", Dark: "#52525b"} // lit-allow: chrome dim, no generated twin — au-w4-cli-chrome-tokens

	// Status dots resolve through semrole off the generated status tones — no
	// inline hex. greenDot=ok / amberDot=warn / blueDot=info (design/tokens.json).
	greenDot = roleColor("ok")
	amberDot = roleColor("warn")
	blueDot  = roleColor("info")

	paneBorder = lipgloss.NewStyle().
			Border(lipgloss.NormalBorder(), false, true, false, false).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#e4e4e7", Dark: "#27272a"}) // lit-allow: chrome border, no generated twin — au-w4-cli-chrome-tokens

	activePaneBorder = lipgloss.NewStyle().
				Border(lipgloss.NormalBorder(), false, true, false, false).
				BorderForeground(lipgloss.AdaptiveColor{Light: "#3b82f6", Dark: "#3b82f6"}) // lit-allow: chrome active-border, no generated twin — au-w4-cli-chrome-tokens

	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"}). // lit-allow: chrome ink, no generated twin — au-w4-cli-chrome-tokens
			Padding(0, 1)

	selectedItemStyle = lipgloss.NewStyle().
				Background(lipgloss.AdaptiveColor{Light: "#eff6ff", Dark: "#172554"}). // lit-allow: chrome selection bg, no generated twin — au-w4-cli-chrome-tokens
				Foreground(lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#93c5fd"})  // lit-allow: chrome selection fg, no generated twin — au-w4-cli-chrome-tokens

	normalItemStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"}) // lit-allow: chrome ink, no generated twin — au-w4-cli-chrome-tokens

	dimStyle = lipgloss.NewStyle().
			Foreground(dimText)

	statusPublished = lipgloss.NewStyle().Foreground(greenDot)
	statusDraft     = lipgloss.NewStyle().Foreground(amberDot)
	statusActive    = lipgloss.NewStyle().Foreground(blueDot)

	dividerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#e4e4e7", Dark: "#27272a"}) // lit-allow: chrome divider, no generated twin — au-w4-cli-chrome-tokens

	editorLabelStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#71717a", Dark: "#a1a1aa"}). // lit-allow: chrome label, no generated twin — au-w4-cli-chrome-tokens
				Bold(true)

	editorFieldStyle = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).
				BorderForeground(lipgloss.AdaptiveColor{Light: "#d4d4d8", Dark: "#3f3f46"}). // lit-allow: chrome field border, no generated twin — au-w4-cli-chrome-tokens
				Padding(0, 1)

	toolbarStyle = lipgloss.NewStyle().
			Background(lipgloss.AdaptiveColor{Light: "#fafafa", Dark: "#0a0a0a"}). // lit-allow: chrome toolbar bg, no generated twin — au-w4-cli-chrome-tokens
			Foreground(lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"})  // lit-allow: chrome toolbar fg, no generated twin — au-w4-cli-chrome-tokens

	breadcrumbStyle = lipgloss.NewStyle().
			Foreground(dimText)

	breadcrumbActiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#d4d4d8"}) // lit-allow: chrome breadcrumb, no generated twin — au-w4-cli-chrome-tokens

	// Styles extracted from inline NewStyle() calls
	logoStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(highlight)

	activeTabStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"}) // lit-allow: chrome active-tab, no generated twin — au-w4-cli-chrome-tokens

	publishBtnStyle = lipgloss.NewStyle().
			Background(lipgloss.Color("#2563eb")). // lit-allow: primary-CTA chrome, no generated twin — au-w4-cli-chrome-tokens
			Foreground(lipgloss.Color("#ffffff")). // lit-allow: on-primary white, no generated twin — au-w4-cli-chrome-tokens
			Bold(true).
			Padding(0, 2)

	selectActiveStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(highlight)

	inactiveCursorStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"}). // lit-allow: chrome cursor fg, no generated twin — au-w4-cli-chrome-tokens
				Background(lipgloss.AdaptiveColor{Light: "#f4f4f5", Dark: "#18181b"})  // lit-allow: chrome cursor bg, no generated twin — au-w4-cli-chrome-tokens

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
