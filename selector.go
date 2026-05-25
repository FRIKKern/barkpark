package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SCOPE SELECTOR                                                         ║
// ║                                                                         ║
// ║  A modal manual-entry prompt for picking the active                     ║
// ║  workspace / project / dataset. The scoped /v1/ API does not expose a   ║
// ║  list-workspaces / list-projects endpoint, so v1 is a three-field       ║
// ║  text-entry form rather than an API-listed picker. Applying the form    ║
// ║  writes the three DataStore scope fields, re-loads schemas for the new  ║
// ║  scope, and rebuilds the structure tree + panes.                        ║
// ╚══════════════════════════════════════════════════════════════════════════╝

const (
	selFieldWorkspace = iota
	selFieldProject
	selFieldDataset
	selFieldCount
)

var selFieldLabels = [selFieldCount]string{"Workspace", "Project", "Dataset"}

// selectorState holds the transient UI state for the scope selector modal.
type selectorState struct {
	active bool
	cursor int
	inputs [selFieldCount]textinput.Model
	err    string // last apply error, shown inline
}

// openSelector seeds the three inputs from the current scope and focuses the
// first field. Idempotent: re-opening always re-seeds from the live scope.
func (m *model) openSelector() tea.Cmd {
	values := [selFieldCount]string{m.ds.Workspace, m.ds.Project, m.ds.Dataset}
	for i := 0; i < selFieldCount; i++ {
		ti := textinput.New()
		ti.CharLimit = 100
		ti.Width = 30
		ti.Prompt = ""
		ti.SetValue(values[i])
		m.selector.inputs[i] = ti
	}
	m.selector.active = true
	m.selector.cursor = 0
	m.selector.err = ""
	m.selector.inputs[0].Focus()
	return textinput.Blink
}

// closeSelector dismisses the modal without applying.
func (m *model) closeSelector() {
	for i := range m.selector.inputs {
		m.selector.inputs[i].Blur()
	}
	m.selector.active = false
}

// focusSelectorField moves the active text input to idx (clamped) and toggles
// focus/blur so the cursor blinks on the right field.
func (m *model) focusSelectorField(idx int) {
	if idx < 0 {
		idx = 0
	}
	if idx >= selFieldCount {
		idx = selFieldCount - 1
	}
	m.selector.cursor = idx
	for i := 0; i < selFieldCount; i++ {
		if i == idx {
			m.selector.inputs[i].Focus()
		} else {
			m.selector.inputs[i].Blur()
		}
	}
}

// applySelector commits the entered scope to the DataStore, reloads schemas,
// and rebuilds the desk structure + panes. On any blank field it refuses and
// leaves the modal open with an inline error. Schema-load failure is surfaced
// the same way and the previous scope is restored.
func (m *model) applySelector() {
	ws := strings.TrimSpace(m.selector.inputs[selFieldWorkspace].Value())
	pr := strings.TrimSpace(m.selector.inputs[selFieldProject].Value())
	dsName := strings.TrimSpace(m.selector.inputs[selFieldDataset].Value())

	if ws == "" || pr == "" || dsName == "" {
		m.selector.err = "all three fields are required"
		return
	}

	// loadSchemas assembles its result into a local slice and only assigns the
	// package-global `schemas` on success, so a failed reload leaves the old
	// schemas (and the old scope) intact — no rollback needed here.
	if err := loadSchemas(m.ds.baseURL, m.ds.token, ws, pr, dsName); err != nil {
		m.selector.err = fmt.Sprintf("load failed: %v", err)
		return
	}

	m.ds.Workspace = ws
	m.ds.Project = pr
	m.ds.Dataset = dsName

	// Rebuild the desk structure from the freshly loaded schemas and reset
	// navigation to the new scope's root.
	initRootStructure()
	m.path = nil
	m.selectedDoc = nil
	m.editorSchema = nil
	m.dirtyValues = nil
	m.dirty = false
	m.focus = focusState{Target: FocusPane, PaneIndex: 0}
	m.rebuildPanes()

	m.closeSelector()
}

// handleSelectorKey routes key input while the selector modal is open.
func (m model) handleSelectorKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.closeSelector()
		return m, nil
	case "tab", "down":
		m.focusSelectorField(m.selector.cursor + 1)
		return m, nil
	case "shift+tab", "up":
		m.focusSelectorField(m.selector.cursor - 1)
		return m, nil
	case "enter":
		// Enter advances through fields; on the last field it applies.
		if m.selector.cursor < selFieldCount-1 {
			m.focusSelectorField(m.selector.cursor + 1)
			return m, nil
		}
		m.applySelector()
		return m, nil
	case "ctrl+s":
		// Apply from any field.
		m.applySelector()
		return m, nil
	default:
		var cmd tea.Cmd
		m.selector.inputs[m.selector.cursor], cmd =
			m.selector.inputs[m.selector.cursor].Update(msg)
		return m, cmd
	}
}

// renderSelector draws the modal centred over the body area.
func (m model) renderSelector(width, height int) string {
	var lines []string
	lines = append(lines, headerStyle.Render(" Switch scope"))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", 34)))
	lines = append(lines, "")

	for i := 0; i < selFieldCount; i++ {
		label := "  " + selFieldLabels[i]
		if i == m.selector.cursor {
			lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(highlight).Render(label))
		} else {
			lines = append(lines, editorLabelStyle.Render(label))
		}
		fieldStyle := editorFieldStyle
		if i == m.selector.cursor {
			fieldStyle = focusedFieldStyle
		}
		lines = append(lines, "  "+fieldStyle.Width(30).Render(m.selector.inputs[i].View()))
	}

	lines = append(lines, "")
	if m.selector.err != "" {
		lines = append(lines, "  "+statusDraft.Render(m.selector.err))
	}
	lines = append(lines, dimStyle.Render("  tab/↑↓ move  enter next/apply  ctrl+s apply  esc cancel"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)

	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)

	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}
