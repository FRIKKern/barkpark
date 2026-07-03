// Command demo renders a Bulldocs paper fixture to a scrollable terminal
// viewport, exercising the full pdrender pipeline (decode → RenderDoc →
// viewport) without touching the barkpark TUI model.
//
// Usage:
//
//	go run ./internal/pdrender/cmd/demo internal/pdrender/testdata/sample.json
//
// Keys: j/k or ↑/↓ scroll a line; PgUp/PgDn scroll a page; q / ctrl+c quit.
package main

import (
	"fmt"
	"os"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

type model struct {
	blocks  []pdrender.Block
	reg     *pdrender.Registry
	theme   pdrender.Theme
	vp      viewport.Model
	ready   bool
	width   int
	height  int
	profile pdrender.Profile
}

func (m model) Init() tea.Cmd { return nil }

// content (re)renders the doc at the current content width — called on every
// resize so the paper reflows.
func (m model) content(width int) string {
	ctx := pdrender.RenderCtx{
		Width:   width,
		Theme:   m.theme,
		Profile: m.profile,
	}
	return m.reg.RenderDoc(m.blocks, ctx)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			return m, tea.Quit
		}
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		// Reserve 1 line for the footer; a small horizontal gutter.
		const gutter = 2
		contentW := msg.Width - gutter
		if contentW < 1 {
			contentW = 1
		}
		if !m.ready {
			m.vp = viewport.New(contentW, msg.Height-1)
			m.ready = true
		} else {
			m.vp.Width = contentW
			m.vp.Height = msg.Height - 1
		}
		m.vp.SetContent(m.content(contentW))
	}

	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(msg)
	return m, cmd
}

func (m model) View() string {
	if !m.ready {
		return "loading…"
	}
	footer := lipgloss.NewStyle().
		Foreground(lipgloss.Color("241")).
		Render(fmt.Sprintf(" %d blocks · %d cols · j/k scroll · q quit ", len(m.blocks), m.vp.Width))
	return m.vp.View() + "\n" + footer
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: demo <paper.json>")
		os.Exit(2)
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "read %s: %v\n", os.Args[1], err)
		os.Exit(1)
	}
	blocks, err := pdrender.Decode(raw)
	if err != nil {
		fmt.Fprintf(os.Stderr, "decode %s: %v\n", os.Args[1], err)
		os.Exit(1)
	}

	theme := pdrender.DarkTheme()
	if !lipgloss.HasDarkBackground() {
		theme = pdrender.LightTheme()
	}

	m := model{
		blocks:  blocks,
		reg:     pdrender.DefaultRegistry(theme),
		theme:   theme,
		profile: detectProfile(),
	}

	if _, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run(); err != nil {
		fmt.Fprintf(os.Stderr, "demo: %v\n", err)
		os.Exit(1)
	}
}

// detectProfile maps the lipgloss/termenv color profile to a pdrender.Profile.
func detectProfile() pdrender.Profile {
	switch lipgloss.ColorProfile() {
	case 0: // Ascii
		return pdrender.NoColor
	case 1: // ANSI (16)
		return pdrender.ANSI16
	case 2: // ANSI256
		return pdrender.ANSI256
	default: // anything unrecognised → the safe ANSI256 floor (matches detectPaperProfile)
		return pdrender.ANSI256
	}
}
