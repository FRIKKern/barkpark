package main

import "github.com/charmbracelet/lipgloss"

var (
	highlight = lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#60a5fa"}
	dimText   = lipgloss.AdaptiveColor{Light: "#a1a1aa", Dark: "#52525b"}
	greenDot  = lipgloss.AdaptiveColor{Light: "#10b981", Dark: "#34d399"}
	amberDot  = lipgloss.AdaptiveColor{Light: "#f59e0b", Dark: "#fbbf24"}
	blueDot   = lipgloss.AdaptiveColor{Light: "#3b82f6", Dark: "#60a5fa"}

	paneBorder = lipgloss.NewStyle().
			Border(lipgloss.NormalBorder(), false, true, false, false).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#e4e4e7", Dark: "#27272a"})

	activePaneBorder = lipgloss.NewStyle().
				Border(lipgloss.NormalBorder(), false, true, false, false).
				BorderForeground(lipgloss.AdaptiveColor{Light: "#3b82f6", Dark: "#3b82f6"})

	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"}).
			Padding(0, 1)

	selectedItemStyle = lipgloss.NewStyle().
				Background(lipgloss.AdaptiveColor{Light: "#eff6ff", Dark: "#172554"}).
				Foreground(lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#93c5fd"})

	normalItemStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"})

	dimStyle = lipgloss.NewStyle().
			Foreground(dimText)

	statusPublished = lipgloss.NewStyle().Foreground(greenDot)
	statusDraft     = lipgloss.NewStyle().Foreground(amberDot)
	statusActive    = lipgloss.NewStyle().Foreground(blueDot)

	dividerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#e4e4e7", Dark: "#27272a"})

	editorLabelStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#71717a", Dark: "#a1a1aa"}).
				Bold(true)

	editorFieldStyle = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).
				BorderForeground(lipgloss.AdaptiveColor{Light: "#d4d4d8", Dark: "#3f3f46"}).
				Padding(0, 1)

	toolbarStyle = lipgloss.NewStyle().
			Background(lipgloss.AdaptiveColor{Light: "#fafafa", Dark: "#0a0a0a"}).
			Foreground(lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"})

	breadcrumbStyle = lipgloss.NewStyle().
			Foreground(dimText)

	breadcrumbActiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#d4d4d8"})

	// Styles extracted from inline NewStyle() calls
	logoStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(highlight)

	activeTabStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"})

	publishBtnStyle = lipgloss.NewStyle().
			Background(lipgloss.Color("#2563eb")).
			Foreground(lipgloss.Color("#ffffff")).
			Bold(true).
			Padding(0, 2)

	imageDropStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#d4d4d8", Dark: "#3f3f46"}).
			Align(lipgloss.Center).
			Padding(1, 0)

	selectActiveStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(highlight)

	scrollInfoStyle = lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#a1a1aa", Dark: "#52525b"})
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
