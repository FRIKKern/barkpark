package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SCOPE SELECTOR                                                          ║
// ║                                                                          ║
// ║  A modal for picking the active workspace / project / dataset. The API   ║
// ║  DOES expose membership-scoped list endpoints:                           ║
// ║                                                                          ║
// ║    GET /api/workspaces                  → {workspaces:[{id,slug,name}]}  ║
// ║    GET /api/workspaces/:slug/projects   → {workspace, projects:[...]}    ║
// ║                                                                          ║
// ║  so the selector lists the workspaces the bearer token is a member of,   ║
// ║  lists that workspace's projects on pick, then takes a dataset string.   ║
// ║  If either list call fails (offline, 401/403/404, old server) the modal  ║
// ║  silently degrades to manual three-field text entry — it never crashes.  ║
// ║  Applying writes the three DataStore scope fields, reloads schemas for    ║
// ║  the new scope, and rebuilds the structure tree + panes.                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// selectorStage is the step the modal is on.
type selectorStage int

const (
	stageWorkspace    selectorStage = iota // pick a workspace from the list
	stageProject                           // pick a project from the list
	stageDataset                           // enter a dataset name
	stageManual                            // fallback: three free-text fields
	stageNewWorkspace                      // `n` on the workspace list: name prompt
	stageNewProject                        // `n` on the project list: name prompt
)

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
	stage  selectorStage

	// List-driven stages.
	workspaces []WorkspaceInfo
	projects   []ProjectInfo
	listCursor int // selected row within the active list stage

	// Chosen-so-far values carried between stages.
	chosenWorkspace string
	chosenProject   string

	// Dataset entry (stageDataset) and the manual fallback (stageManual).
	datasetInput textinput.Model
	cursor       int // active field in stageManual
	inputs       [selFieldCount]textinput.Model

	// Name prompt for the create stages (stageNewWorkspace / stageNewProject).
	// The server derives the slug from the name and seeds the child defaults
	// (workspace → Default project + production dataset; project → production).
	nameInput textinput.Model

	err string // last error, shown inline
}

// openSelector opens the modal. It tries to list the membership-scoped
// workspaces; on success it starts on the workspace-pick stage, otherwise it
// degrades to the manual three-field form seeded from the live scope.
func (m *model) openSelector() tea.Cmd {
	m.selector = selectorState{active: true}

	ws, err := m.ds.ListWorkspaces()
	if err != nil || len(ws) == 0 {
		m.seedManualSelector()
		if err != nil {
			m.selector.err = fmt.Sprintf("list unavailable (%v) — manual entry", err)
		} else {
			// Zero workspaces (fresh server) — say why we dropped to manual entry
			// instead of showing a blank prompt with no context.
			m.selector.err = "no workspaces yet — enter slugs manually, or create one in Studio"
		}
		return textinput.Blink
	}

	m.selector.workspaces = ws
	m.selector.stage = stageWorkspace
	m.selector.listCursor = indexOfWorkspace(ws, m.ds.Workspace)
	return textinput.Blink
}

// seedManualSelector configures the three free-text inputs from the live scope
// and focuses the first. Used as the offline / API-failure fallback.
func (m *model) seedManualSelector() {
	values := [selFieldCount]string{m.ds.Workspace, m.ds.Project, m.ds.Dataset}
	for i := 0; i < selFieldCount; i++ {
		ti := textinput.New()
		ti.CharLimit = 100
		ti.Width = 30
		ti.Prompt = ""
		ti.SetValue(values[i])
		m.selector.inputs[i] = ti
	}
	m.selector.stage = stageManual
	m.selector.cursor = 0
	m.selector.inputs[0].Focus()
}

// seedDatasetInput configures the dataset text field, seeded from the live
// dataset, and focuses it.
func (m *model) seedDatasetInput() {
	ti := textinput.New()
	ti.CharLimit = 100
	ti.Width = 30
	ti.Prompt = ""
	ti.SetValue(m.ds.Dataset)
	ti.Focus()
	m.selector.datasetInput = ti
	m.selector.stage = stageDataset
}

// closeSelector dismisses the modal without applying.
func (m *model) closeSelector() {
	for i := range m.selector.inputs {
		m.selector.inputs[i].Blur()
	}
	m.selector.datasetInput.Blur()
	m.selector.active = false
}

// indexOfWorkspace returns the index of the workspace whose slug matches, or 0.
func indexOfWorkspace(list []WorkspaceInfo, slug string) int {
	for i := range list {
		if list[i].Slug == slug {
			return i
		}
	}
	return 0
}

// applyScope commits the chosen scope to the DataStore, reloads schemas, and
// rebuilds the desk structure + panes. On any blank field it refuses and leaves
// the modal open with an inline error. Schema-load failure is surfaced the same
// way and the previous scope is left intact — LoadSchemasFor probes the
// prospective scope without mutating the client, and the caller-owned `schemas`
// slice is only swapped on success.
func (m *model) applyScope(ws, pr, dsName string) {
	ws = strings.TrimSpace(ws)
	pr = strings.TrimSpace(pr)
	dsName = strings.TrimSpace(dsName)

	if ws == "" || pr == "" || dsName == "" {
		m.selector.err = "all three fields are required"
		return
	}

	loaded, err := m.ds.LoadSchemasFor(ws, pr, dsName)
	if err != nil {
		m.selector.err = fmt.Sprintf("load failed: %v", err)
		return
	}
	schemas = loaded

	m.ds.Workspace = ws
	m.ds.Project = pr
	m.ds.Dataset = dsName

	buildDesk(m.ds)
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
	switch m.selector.stage {
	case stageWorkspace:
		return m.handleWorkspaceStageKey(msg)
	case stageProject:
		return m.handleProjectStageKey(msg)
	case stageDataset:
		return m.handleDatasetStageKey(msg)
	case stageNewWorkspace, stageNewProject:
		return m.handleCreateStageKey(msg)
	default:
		return m.handleManualStageKey(msg)
	}
}

// seedNameInput opens the create-name prompt for the given stage.
func (m *model) seedNameInput(stage selectorStage) {
	ti := textinput.New()
	ti.CharLimit = 100
	ti.Width = 30
	ti.Prompt = ""
	ti.Focus()
	m.selector.nameInput = ti
	m.selector.stage = stage
	m.selector.err = ""
}

// handleCreateStageKey handles the new-workspace / new-project name prompt.
// enter creates and flows FORWARD (a new workspace lists its seeded projects;
// a new project goes straight to the dataset step); esc steps back to the
// list it came from. A create failure (422 duplicate slug, network) stays on
// the prompt with the server's reason inline.
func (m model) handleCreateStageKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	creatingWorkspace := m.selector.stage == stageNewWorkspace

	switch msg.String() {
	case "esc":
		if creatingWorkspace {
			m.selector.stage = stageWorkspace
		} else {
			m.selector.stage = stageProject
		}
		m.selector.err = ""
		return m, nil
	case "enter":
		name := strings.TrimSpace(m.selector.nameInput.Value())
		if name == "" {
			m.selector.err = "name is required"
			return m, nil
		}
		if creatingWorkspace {
			return m.createWorkspaceAndAdvance(name)
		}
		return m.createProjectAndAdvance(name)
	default:
		var cmd tea.Cmd
		m.selector.nameInput, cmd = m.selector.nameInput.Update(msg)
		return m, cmd
	}
}

func (m model) createWorkspaceAndAdvance(name string) (tea.Model, tea.Cmd) {
	ws, err := m.ds.CreateWorkspace(name)
	if err != nil {
		m.selector.err = fmt.Sprintf("create failed: %v", err)
		return m, nil
	}
	m.selector.chosenWorkspace = ws.Slug
	m.selector.err = ""

	// The server seeded a Default project — list and continue the normal flow.
	projs, listErr := m.ds.ListProjects(ws.Slug)
	if listErr != nil || len(projs) == 0 {
		m.seedManualSelector()
		m.selector.inputs[selFieldWorkspace].SetValue(ws.Slug)
		m.selector.err = "created " + ws.Slug + " — finish manually"
		return m, textinput.Blink
	}
	m.selector.projects = projs
	m.selector.listCursor = 0
	m.selector.stage = stageProject
	return m, nil
}

func (m model) createProjectAndAdvance(name string) (tea.Model, tea.Cmd) {
	pr, err := m.ds.CreateProject(m.selector.chosenWorkspace, name)
	if err != nil {
		m.selector.err = fmt.Sprintf("create failed: %v", err)
		return m, nil
	}
	// The server seeded the production dataset — go straight to the dataset
	// step with the new project chosen.
	m.selector.chosenProject = pr.Slug
	m.selector.err = ""
	m.seedDatasetInput()
	return m, textinput.Blink
}

func (m model) handleWorkspaceStageKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.closeSelector()
		return m, nil
	case "down", "tab", "j":
		if m.selector.listCursor < len(m.selector.workspaces)-1 {
			m.selector.listCursor++
		}
		return m, nil
	case "up", "shift+tab", "k":
		if m.selector.listCursor > 0 {
			m.selector.listCursor--
		}
		return m, nil
	case "m":
		// Drop to manual entry on demand.
		m.seedManualSelector()
		return m, textinput.Blink
	case "n":
		// Create a new workspace (Studio-selector parity).
		m.seedNameInput(stageNewWorkspace)
		return m, textinput.Blink
	case "enter":
		sel := m.selector.workspaces[m.selector.listCursor]
		m.selector.chosenWorkspace = sel.Slug
		m.selector.err = ""

		projs, err := m.ds.ListProjects(sel.Slug)
		if err != nil || len(projs) == 0 {
			// Couldn't list projects — fall back to manual, but pre-fill the
			// workspace the user already picked.
			m.seedManualSelector()
			m.selector.inputs[selFieldWorkspace].SetValue(sel.Slug)
			if err != nil {
				m.selector.err = fmt.Sprintf("no projects listed (%v) — manual entry", err)
			} else {
				m.selector.err = "no projects in this workspace — manual entry"
			}
			return m, textinput.Blink
		}
		m.selector.projects = projs
		m.selector.listCursor = indexOfProject(projs, m.ds.Project)
		m.selector.stage = stageProject
		return m, nil
	}
	return m, nil
}

func (m model) handleProjectStageKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		// Step back to the workspace list.
		m.selector.stage = stageWorkspace
		m.selector.err = ""
		return m, nil
	case "down", "tab", "j":
		if m.selector.listCursor < len(m.selector.projects)-1 {
			m.selector.listCursor++
		}
		return m, nil
	case "up", "shift+tab", "k":
		if m.selector.listCursor > 0 {
			m.selector.listCursor--
		}
		return m, nil
	case "n":
		// Create a new project under the chosen workspace.
		m.seedNameInput(stageNewProject)
		return m, textinput.Blink
	case "enter":
		m.selector.chosenProject = m.selector.projects[m.selector.listCursor].Slug
		m.selector.err = ""
		m.seedDatasetInput()
		return m, textinput.Blink
	}
	return m, nil
}

func (m model) handleDatasetStageKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		// Step back to the project list.
		m.selector.stage = stageProject
		m.selector.err = ""
		return m, nil
	case "enter", "ctrl+s":
		m.applyScope(m.selector.chosenWorkspace, m.selector.chosenProject, m.selector.datasetInput.Value())
		return m, nil
	default:
		var cmd tea.Cmd
		m.selector.datasetInput, cmd = m.selector.datasetInput.Update(msg)
		return m, cmd
	}
}

func (m model) handleManualStageKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
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
		if m.selector.cursor < selFieldCount-1 {
			m.focusSelectorField(m.selector.cursor + 1)
			return m, nil
		}
		m.applyScope(
			m.selector.inputs[selFieldWorkspace].Value(),
			m.selector.inputs[selFieldProject].Value(),
			m.selector.inputs[selFieldDataset].Value(),
		)
		return m, nil
	case "ctrl+s":
		m.applyScope(
			m.selector.inputs[selFieldWorkspace].Value(),
			m.selector.inputs[selFieldProject].Value(),
			m.selector.inputs[selFieldDataset].Value(),
		)
		return m, nil
	default:
		var cmd tea.Cmd
		m.selector.inputs[m.selector.cursor], cmd =
			m.selector.inputs[m.selector.cursor].Update(msg)
		return m, cmd
	}
}

// focusSelectorField moves the active manual text input to idx (clamped).
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

func indexOfProject(list []ProjectInfo, slug string) int {
	for i := range list {
		if list[i].Slug == slug {
			return i
		}
	}
	return 0
}

// renderSelector draws the modal centred over the body area.
func (m model) renderSelector(width, height int) string {
	var lines []string
	lines = append(lines, headerStyle.Render(" Switch scope"))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", 34)))
	lines = append(lines, "")

	switch m.selector.stage {
	case stageWorkspace:
		lines = append(lines, editorLabelStyle.Render("  Workspace"))
		for i, ws := range m.selector.workspaces {
			lines = append(lines, renderListRow(ws.Name, ws.Slug, i == m.selector.listCursor))
		}
		lines = append(lines, "")
		lines = appendErr(lines, m.selector.err)
		lines = append(lines, dimStyle.Render("  ↑↓/jk move  enter pick  n new  m manual  esc cancel"))

	case stageProject:
		lines = append(lines, editorLabelStyle.Render("  Project — "+m.selector.chosenWorkspace))
		for i, pr := range m.selector.projects {
			lines = append(lines, renderListRow(pr.Name, pr.Slug, i == m.selector.listCursor))
		}
		lines = append(lines, "")
		lines = appendErr(lines, m.selector.err)
		lines = append(lines, dimStyle.Render("  ↑↓/jk move  enter pick  n new  esc back"))

	case stageNewWorkspace, stageNewProject:
		what := "workspace"
		if m.selector.stage == stageNewProject {
			what = "project — " + m.selector.chosenWorkspace
		}
		lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(highlight).Render("  New "+what))
		lines = append(lines, dimStyle.Render("  slug derives from the name"))
		lines = append(lines, "  "+focusedFieldStyle.Width(30).Render(m.selector.nameInput.View()))
		lines = append(lines, "")
		lines = appendErr(lines, m.selector.err)
		lines = append(lines, dimStyle.Render("  enter create  esc back"))

	case stageDataset:
		lines = append(lines, editorLabelStyle.Render(
			fmt.Sprintf("  %s / %s", m.selector.chosenWorkspace, m.selector.chosenProject)))
		lines = append(lines, "")
		lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(highlight).Render("  Dataset"))
		lines = append(lines, "  "+focusedFieldStyle.Width(30).Render(m.selector.datasetInput.View()))
		lines = append(lines, "")
		lines = appendErr(lines, m.selector.err)
		lines = append(lines, dimStyle.Render("  enter apply  ctrl+s apply  esc back"))

	default: // stageManual
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
		lines = appendErr(lines, m.selector.err)
		lines = append(lines, dimStyle.Render("  tab/↑↓ move  enter next/apply  ctrl+s apply  esc cancel"))
	}

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)

	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(highlight).
		Padding(1, 2).
		Render(body)

	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}

// renderListRow draws one selectable workspace/project row.
func renderListRow(name, slug string, selected bool) string {
	label := name
	if slug != "" && slug != name {
		label = fmt.Sprintf("%s (%s)", name, slug)
	}
	if selected {
		return lipgloss.NewStyle().Bold(true).Foreground(highlight).Render("  ▸ " + label)
	}
	return editorLabelStyle.Render("    " + label)
}

// appendErr appends an inline error line when err is non-empty.
func appendErr(lines []string, err string) []string {
	if err != "" {
		lines = append(lines, "  "+statusDraft.Render(err))
	}
	return lines
}
