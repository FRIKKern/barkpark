package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PANE TYPES                                                             ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Pane represents one visible column in the TUI.
type Pane struct {
	Node      *StructureNode
	Items     []PaneItem
	Cursor    int
	Scroll    int
	IsDocList bool
}

// PaneItem is a single renderable row inside a Pane.
type PaneItem struct {
	ID         string
	Title      string
	Icon       string
	Status     string
	Subtitle   string
	IsDivider  bool
	SourceNode *StructureNode
	Doc        *Doc
}

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  FOCUS                                                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

type FocusTarget int

const (
	FocusPane   FocusTarget = iota // a list pane has focus
	FocusEditor                    // the editor/inspect panel has focus
)

type focusState struct {
	Target    FocusTarget
	PaneIndex int // index into m.panes; only valid when Target == FocusPane
}

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  MODEL                                                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// borderCost is the number of terminal columns added by paneBorder's right border.
const borderCost = 1

type model struct {
	ds           *DataStore
	panes        []Pane
	focus        focusState
	path         []string // selected structure item IDs at each depth
	selectedDoc  *Doc
	editorSchema *Schema
	showEditor   bool
	viewport     viewport.Model
	vpReady      bool
	width        int
	height       int
}

func initialModel(ds *DataStore) model {
	m := model{ds: ds, width: 120, height: 40}
	m.rebuildPanes()
	return m
}

// paneWidth returns the interior content width for list panes.
func (m model) paneWidth() int {
	if m.width > 160 {
		return 32
	}
	return 28
}

// calcEditorWidth computes the interior content width for the editor column.
func (m model) calcEditorWidth() int {
	pw := m.paneWidth()
	colWidth := pw + borderCost
	minEditor := 40

	maxPanes := (m.width - minEditor - borderCost) / colWidth
	if maxPanes < 1 {
		maxPanes = 1
	}

	visible := len(m.panes)
	if visible > maxPanes {
		visible = maxPanes
	}

	ew := m.width - visible*colWidth - borderCost
	if ew < minEditor {
		ew = minEditor
	}
	return ew
}

// paneHeight returns the available height for pane/editor content.
func (m model) paneHeight() int {
	h := m.height - 4 // toolbar + helpbar
	if h < 4 {
		h = 4
	}
	return h
}

// rebuildPanes resolves the current path against the structure tree
// and builds the visible pane chain.
func (m *model) rebuildPanes() {
	m.panes = nil
	m.showEditor = false
	m.selectedDoc = nil
	m.editorSchema = nil

	current := rootStructure
	m.panes = append(m.panes, m.buildListPane(current))

	for _, id := range m.path {
		var found *StructureNode
		for _, item := range current.Items {
			if item.ID == id {
				found = item
				break
			}
		}
		if found == nil {
			break
		}

		child := found.Child
		if child == nil {
			break
		}

		switch child.Type {
		case NodeList:
			m.panes = append(m.panes, m.buildListPane(child))
			current = child

		case NodeDocumentTypeList:
			m.panes = append(m.panes, m.buildDocListPane(child))
			if m.selectedDoc != nil {
				m.showEditor = true
				m.editorSchema = findSchema(child.TypeName)
			}
			goto done

		case NodeDocument:
			docs := m.ds.Query(child.TypeName, "")
			if len(docs) > 0 {
				m.selectedDoc = &docs[0]
			}
			m.editorSchema = findSchema(child.TypeName)
			m.showEditor = true
			goto done
		}
	}
done:

	// Clamp focus
	if m.focus.Target == FocusPane && m.focus.PaneIndex >= len(m.panes) {
		m.focus.PaneIndex = len(m.panes) - 1
	}
	if m.focus.Target == FocusEditor && !m.showEditor {
		m.focus.Target = FocusPane
		m.focus.PaneIndex = len(m.panes) - 1
	}
}

func (m *model) buildListPane(node *StructureNode) Pane {
	var items []PaneItem
	for _, item := range node.Items {
		if item.Type == NodeDivider {
			items = append(items, PaneItem{IsDivider: true, ID: item.ID})
			continue
		}
		items = append(items, PaneItem{
			ID:         item.ID,
			Title:      item.Title,
			Icon:       item.Icon,
			SourceNode: item,
		})
	}
	return Pane{Node: node, Items: items}
}

func (m *model) buildDocListPane(node *StructureNode) Pane {
	docs := m.ds.Query(node.TypeName, node.Filter)
	var items []PaneItem
	for i := range docs {
		items = append(items, PaneItem{
			ID:       docs[i].ID,
			Title:    docs[i].Title,
			Icon:     statusIcon(docs[i].Status),
			Status:   docs[i].Status,
			Subtitle: timeAgo(docs[i].UpdatedAt),
			Doc:      &docs[i],
		})
	}
	return Pane{Node: node, Items: items, IsDocList: true}
}

// refreshViewport rebuilds editor content and resets the viewport.
func (m *model) refreshViewport() {
	if !m.vpReady {
		return
	}
	ew := m.calcEditorWidth()
	m.viewport.Width = ew
	m.viewport.Height = m.paneHeight()
	m.viewport.SetContent(m.buildEditorContent(ew))
	m.viewport.GotoTop()
}

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  INIT / UPDATE                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case DataStoreRefreshMsg:
		m.rebuildPanes()
		if m.showEditor && m.selectedDoc != nil {
			m.refreshViewport()
		}
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(msg)
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		ew := m.calcEditorWidth()
		ph := m.paneHeight()
		if !m.vpReady {
			m.viewport = viewport.New(ew, ph)
			m.viewport.KeyMap = viewport.KeyMap{} // disable default bindings
			m.vpReady = true
		} else {
			m.viewport.Width = ew
			m.viewport.Height = ph
		}
		if m.showEditor && m.selectedDoc != nil {
			m.viewport.SetContent(m.buildEditorContent(ew))
		}
	}
	return m, nil
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {

	case "q", "ctrl+c":
		return m, tea.Quit

	// ── Switch pane / drill ──
	case "tab":
		if m.focus.Target == FocusPane {
			if m.focus.PaneIndex < len(m.panes)-1 {
				m.focus.PaneIndex++
			} else if m.showEditor {
				m.focus.Target = FocusEditor
			}
		}

	case "l", "right":
		if m.focus.Target == FocusPane {
			if m.focus.PaneIndex < len(m.panes)-1 {
				m.focus.PaneIndex++
			} else {
				// On the last pane, drill in like Enter
				return m.drillIn()
			}
		}

	case "shift+tab":
		if m.focus.Target == FocusEditor {
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
		} else if m.focus.PaneIndex > 0 {
			m.focus.PaneIndex--
		}

	case "h", "left":
		if m.focus.Target == FocusEditor {
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
		} else if m.focus.PaneIndex > 0 {
			m.focus.PaneIndex--
		} else if len(m.path) > 0 {
			// On the first pane, go back like Esc
			m.path = m.path[:len(m.path)-1]
			m.rebuildPanes()
		}

	// ── Navigate within pane ──
	case "j", "down":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			if pane.Cursor < len(pane.Items)-1 {
				pane.Cursor++
				for pane.Cursor < len(pane.Items) && pane.Items[pane.Cursor].IsDivider {
					pane.Cursor++
				}
				if pane.Cursor >= len(pane.Items) {
					pane.Cursor = len(pane.Items) - 1
				}
			}
		} else if m.focus.Target == FocusEditor {
			m.viewport.LineDown(1)
		}

	case "k", "up":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			if pane.Cursor > 0 {
				pane.Cursor--
				for pane.Cursor > 0 && pane.Items[pane.Cursor].IsDivider {
					pane.Cursor--
				}
			}
		} else if m.focus.Target == FocusEditor {
			m.viewport.LineUp(1)
		}

	// ── Drill in ──
	case "enter":
		return m.drillIn()

	// ── Go back ──
	case "backspace", "esc":
		if m.focus.Target == FocusEditor {
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
		} else if len(m.path) > 0 {
			m.path = m.path[:len(m.path)-1]
			m.rebuildPanes()
		}
	}

	return m, nil
}

// drillIn selects the highlighted item in the focused pane, same as Enter.
func (m model) drillIn() (tea.Model, tea.Cmd) {
	if m.focus.Target != FocusPane || m.focus.PaneIndex >= len(m.panes) {
		return m, nil
	}
	pane := &m.panes[m.focus.PaneIndex]
	if pane.Cursor >= len(pane.Items) {
		return m, nil
	}
	item := pane.Items[pane.Cursor]
	if item.IsDivider {
		return m, nil
	}
	if pane.IsDocList {
		m.selectedDoc = item.Doc
		m.editorSchema = findSchema(pane.Node.TypeName)
		m.showEditor = true
		m.focus.Target = FocusEditor
		m.refreshViewport()
	} else {
		m.path = m.path[:m.focus.PaneIndex]
		m.path = append(m.path, item.ID)
		m.rebuildPanes()
		if m.showEditor {
			m.focus.Target = FocusEditor
			m.refreshViewport()
		} else if m.focus.PaneIndex < len(m.panes)-1 {
			m.focus.PaneIndex++
		}
	}
	return m, nil
}

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VIEW                                                                   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

func (m model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	toolbar := m.renderToolbar()
	helpBar := m.renderHelpBar()
	ph := m.paneHeight()
	pw := m.paneWidth()
	colWidth := pw + borderCost

	// Determine visible panes
	minEditor := 40
	maxPanes := (m.width - minEditor - borderCost) / colWidth
	if maxPanes < 1 {
		maxPanes = 1
	}

	visiblePanes := len(m.panes)
	startPane := 0
	if visiblePanes > maxPanes {
		visiblePanes = maxPanes
		startPane = len(m.panes) - visiblePanes
	}

	editorWidth := m.width - visiblePanes*colWidth - borderCost
	if editorWidth < minEditor {
		editorWidth = minEditor
	}

	// Render visible panes
	var columns []string
	for i := startPane; i < len(m.panes); i++ {
		isActive := m.focus.Target == FocusPane && i == m.focus.PaneIndex
		columns = append(columns, m.renderPane(m.panes[i], pw, ph, isActive))
	}

	// Editor, preview, or empty state
	if m.showEditor {
		isActive := m.focus.Target == FocusEditor
		columns = append(columns, m.renderEditor(editorWidth, ph, isActive))
	} else if preview := m.renderPreview(editorWidth, ph); preview != "" {
		columns = append(columns, preview)
	} else {
		columns = append(columns, m.renderEmptyState(editorWidth, ph))
	}

	body := lipgloss.JoinHorizontal(lipgloss.Top, columns...)
	return lipgloss.JoinVertical(lipgloss.Left, toolbar, body, helpBar)
}

// ── Toolbar ──────────────────────────────────────────────────────────────────

func (m model) renderToolbar() string {
	logo := logoStyle.Render("▣ Studio")
	tabs := dimStyle.Render("[") +
		activeTabStyle.Render("Structure") +
		dimStyle.Render("] ") +
		dimStyle.Render("Vision")

	// Breadcrumbs
	crumbs := make([]string, 0, len(m.panes)+1)
	for _, p := range m.panes {
		crumbs = append(crumbs, p.Node.Title)
	}
	if m.selectedDoc != nil {
		crumbs = append(crumbs, m.selectedDoc.Title)
	}

	var bc string
	for i, c := range crumbs {
		if i > 0 {
			bc += dimStyle.Render(" > ")
		}
		if i == len(crumbs)-1 {
			bc += breadcrumbActiveStyle.Render(truncate(c, 20))
		} else {
			bc += breadcrumbStyle.Render(truncate(c, 14))
		}
	}

	left := logo + "  " + tabs + "  " + bc
	right := dimStyle.Render("Ctrl+K Search")

	gap := m.width - lipgloss.Width(left) - lipgloss.Width(right) - 2
	if gap < 1 {
		gap = 1
	}
	return toolbarStyle.Width(m.width).Render(left + strings.Repeat(" ", gap) + right)
}

// ── Help bar ─────────────────────────────────────────────────────────────────

func (m model) renderHelpBar() string {
	return toolbarStyle.Width(m.width).Render(
		dimStyle.Render(" j/k navigate  h/l switch pane  enter select  esc back  q quit"),
	)
}

// ── List / DocList pane ──────────────────────────────────────────────────────

func (m model) renderPane(pane Pane, width, height int, isActive bool) string {
	var lines []string

	// Header — headerStyle has Padding(0,1) which is inside Width()
	icon := ""
	if pane.Node.Icon != "" {
		icon = pane.Node.Icon + " "
	}
	headerText := icon + pane.Node.Title
	if pane.IsDocList {
		headerText += dimStyle.Render(fmt.Sprintf(" %d", len(pane.Items)))
	}
	lines = append(lines, headerStyle.Width(width).Render(headerText))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width)))

	// Visible area
	visibleHeight := height - 3
	scroll := 0
	if pane.Cursor >= visibleHeight {
		scroll = pane.Cursor - visibleHeight + 1
	}

	for i := scroll; i < len(pane.Items) && i-scroll < visibleHeight; i++ {
		item := pane.Items[i]
		if item.IsDivider {
			lines = append(lines, dimStyle.Render("  "+strings.Repeat("─", width-4)))
			continue
		}

		isSelected := i == pane.Cursor && isActive
		isCursor := i == pane.Cursor && !isActive // show dim cursor in inactive panes
		lines = append(lines, m.renderPaneItem(item, width, isSelected, isCursor, pane.IsDocList)...)
	}

	// Pad
	for len(lines) < height {
		lines = append(lines, strings.Repeat(" ", width))
	}
	if len(lines) > height {
		lines = lines[:height]
	}

	content := lipgloss.JoinVertical(lipgloss.Left, lines...)
	if isActive {
		return activePaneBorder.Width(width).Height(height).Render(content)
	}
	return paneBorder.Width(width).Height(height).Render(content)
}

func (m model) renderPaneItem(item PaneItem, width int, selected, isCursor, isDocList bool) []string {
	style := normalItemStyle
	if selected {
		style = selectedItemStyle
	}

	if isDocList {
		dot := statusStyle(item.Status).Render(item.Icon)
		title := truncate(item.Title, width-6)
		line1 := fmt.Sprintf(" %s %s", dot, style.Render(title))
		line2 := fmt.Sprintf("     %s", dimStyle.Render(item.Subtitle))
		if selected {
			line1 = selectedItemStyle.Width(width).Render(fmt.Sprintf(" %s %s", dot, title))
			line2 = selectedItemStyle.Width(width).Render(fmt.Sprintf("     %s", item.Subtitle))
		} else if isCursor {
			// Dim highlight for cursor in unfocused pane
			cursorStyle := lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"}).
				Background(lipgloss.AdaptiveColor{Light: "#f4f4f5", Dark: "#18181b"})
			line1 = cursorStyle.Width(width).Render(fmt.Sprintf(" %s %s", dot, title))
			line2 = cursorStyle.Width(width).Render(fmt.Sprintf("     %s", item.Subtitle))
		}
		return []string{line1, line2}
	}

	// Structure list item
	icon := item.Icon
	if icon == "" {
		icon = " "
	}
	title := truncate(item.Title, width-8)
	chevron := dimStyle.Render("›")
	inner := fmt.Sprintf(" %s %s", icon, title)
	gap := width - lipgloss.Width(inner) - 2
	if gap < 0 {
		gap = 0
	}
	line := style.Width(width).Render(inner + strings.Repeat(" ", gap) + chevron)
	if isCursor && !selected {
		cursorStyle := lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"}).
			Background(lipgloss.AdaptiveColor{Light: "#f4f4f5", Dark: "#18181b"})
		line = cursorStyle.Width(width).Render(inner + strings.Repeat(" ", gap) + chevron)
	}
	return []string{line}
}

// ── Editor pane ──────────────────────────────────────────────────────────────

func (m model) renderEditor(width, height int, isActive bool) string {
	if m.selectedDoc == nil || m.editorSchema == nil {
		return m.renderEmptyState(width, height)
	}

	// Use viewport for scrolling
	var content string
	if m.vpReady {
		content = m.viewport.View()
	} else {
		// Fallback before first WindowSizeMsg
		content = m.buildEditorContent(width)
	}

	if isActive {
		return activePaneBorder.Width(width).Height(height).Render(content)
	}
	return paneBorder.Width(width).Height(height).Render(content)
}

// buildEditorContent renders the full editor content as a string.
// The viewport handles scrolling and clipping.
func (m model) buildEditorContent(width int) string {
	if m.selectedDoc == nil || m.editorSchema == nil {
		return ""
	}

	var lines []string

	// Header
	dot := statusStyle(m.selectedDoc.Status).Render(statusIcon(m.selectedDoc.Status))
	title := truncate(m.selectedDoc.Title, width-20)
	badge := dimStyle.Render("[" + m.selectedDoc.Status + "]")
	lines = append(lines, fmt.Sprintf(" %s %s %s", dot, headerStyle.Render(title), badge))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	// Schema info
	lines = append(lines, dimStyle.Render(fmt.Sprintf(
		" %s %s  |  %d fields", m.editorSchema.Icon, m.editorSchema.Title, len(m.editorSchema.Fields),
	)))
	lines = append(lines, "")

	// Fields
	fieldWidth := width - 4
	if fieldWidth < 20 {
		fieldWidth = 20
	}
	for i, field := range m.editorSchema.Fields {
		lines = append(lines, m.renderField(field, fieldWidth)...)
		if i < len(m.editorSchema.Fields)-1 {
			lines = append(lines, "")
		}
	}

	// Footer
	lines = append(lines, "")
	lines = append(lines, dividerStyle.Render(" "+strings.Repeat("─", width-4)))
	footerLeft := dimStyle.Render(fmt.Sprintf("  Edited %s", timeAgo(m.selectedDoc.UpdatedAt)))
	publishBtn := publishBtnStyle.Render("Publish")
	gap := width - lipgloss.Width(footerLeft) - lipgloss.Width(publishBtn) - 4
	if gap < 0 {
		gap = 0
	}
	lines = append(lines, footerLeft+strings.Repeat(" ", gap)+publishBtn)

	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// renderField generates the TUI lines for a single schema field.
func (m model) renderField(field Field, width int) []string {
	var lines []string
	lines = append(lines, editorLabelStyle.Render("  "+strings.ToUpper(field.Title)))

	val := ""
	if m.selectedDoc != nil {
		switch field.Name {
		case "title", "name":
			val = m.selectedDoc.Title
		case "status":
			val = m.selectedDoc.Status
		default:
			if m.selectedDoc.Values != nil {
				val = m.selectedDoc.Values[field.Name]
			}
		}
	}

	placeholder := func(ph string) string {
		if val != "" {
			return val
		}
		return dimStyle.Render(ph)
	}

	// Interior width for editorFieldStyle: subtract border (2) + padding (2) + indent (2)
	fieldContentWidth := width - 6
	if fieldContentWidth < 10 {
		fieldContentWidth = 10
	}

	switch field.Type {
	case FieldString:
		lines = append(lines, "  "+editorFieldStyle.Width(fieldContentWidth).Render(placeholder("Enter "+field.Title+"...")))

	case FieldSlug:
		slug := val
		if slug == "" && m.selectedDoc != nil {
			slug = toSlug(m.selectedDoc.Title)
		}
		slugWidth := fieldContentWidth - 6
		if slugWidth < 10 {
			slugWidth = 10
		}
		box := editorFieldStyle.Width(slugWidth).Render(dimStyle.Render(slug))
		lines = append(lines, "  "+box+" "+dimStyle.Render("[gen]"))

	case FieldText:
		rows := field.Rows
		if rows < 2 {
			rows = 3
		}
		content := placeholder("Enter " + field.Title + "...")
		for i := 1; i < rows; i++ {
			content += "\n"
		}
		lines = append(lines, "  "+editorFieldStyle.Width(fieldContentWidth).Render(content))

	case FieldRichText:
		lines = append(lines, dimStyle.Render("  B  I  U  H1  H2  \"  ~  #"))
		content := dimStyle.Render("Start writing...")
		content += "\n"
		content += "\n"
		lines = append(lines, "  "+editorFieldStyle.Width(fieldContentWidth).Render(content))

	case FieldImage:
		lines = append(lines, "  "+imageDropStyle.Width(fieldContentWidth).Render(dimStyle.Render("Drop image or browse")))

	case FieldSelect:
		display := ""
		current := val
		if current == "" && len(field.Options) > 0 {
			current = field.Options[0]
		}
		for _, opt := range field.Options {
			if opt == current {
				display += selectActiveStyle.Render(" " + opt + " ")
			} else {
				display += dimStyle.Render(" " + opt + " ")
			}
		}
		lines = append(lines, "  "+display)

	case FieldBoolean:
		toggle := dimStyle.Render("○───")
		if val == "true" {
			toggle = statusPublished.Render("───●")
		}
		lines = append(lines, "  "+toggle)

	case FieldDatetime:
		dv := placeholder("YYYY-MM-DD HH:MM")
		lines = append(lines, "  "+editorFieldStyle.Width(fieldContentWidth).Render(dv))

	case FieldColor:
		cv := val
		if cv == "" {
			cv = "#3b82f6"
		}
		swatch := lipgloss.NewStyle().Background(lipgloss.Color(cv)).Render("    ")
		lines = append(lines, "  "+swatch+" "+editorFieldStyle.Render(cv))

	case FieldReference:
		rv := val
		if rv == "" {
			rv = dimStyle.Render("Select " + field.RefType + "...")
		}
		lines = append(lines, "  "+editorFieldStyle.Width(fieldContentWidth).Render(rv+"  "+dimStyle.Render(">")))

	case FieldArray:
		lines = append(lines, "  "+dimStyle.Render("[ ] No items yet  [+ Add]"))

	default:
		lines = append(lines, "  "+editorFieldStyle.Width(fieldContentWidth).Render(placeholder("...")))
	}

	return lines
}

// ── Preview pane ────────────────────────────────────────────────────────────

// renderPreview shows a preview of the highlighted item's content in the right
// pane — the same thing you'd see if you pressed Enter.
func (m model) renderPreview(width, height int) string {
	if m.focus.Target != FocusPane {
		return ""
	}
	pane := m.panes[m.focus.PaneIndex]
	if pane.Cursor >= len(pane.Items) {
		return ""
	}
	item := pane.Items[pane.Cursor]
	if item.IsDivider {
		return ""
	}

	// Document list item → show document detail preview
	if pane.IsDocList && item.Doc != nil {
		schema := findSchema(pane.Node.TypeName)
		if schema == nil {
			return ""
		}
		content := m.buildDocPreview(item.Doc, schema, width)
		return paneBorder.Width(width).Height(height).Render(content)
	}

	// Structure item → show what its child contains
	if item.SourceNode == nil || item.SourceNode.Child == nil {
		return ""
	}
	child := item.SourceNode.Child

	switch child.Type {
	case NodeDocumentTypeList:
		content := m.buildDocListPreview(child, width)
		return paneBorder.Width(width).Height(height).Render(content)
	case NodeList:
		content := m.buildListPreview(child, width)
		return paneBorder.Width(width).Height(height).Render(content)
	case NodeDocument:
		docs := m.ds.Query(child.TypeName, "")
		schema := findSchema(child.TypeName)
		if len(docs) > 0 && schema != nil {
			content := m.buildDocPreview(&docs[0], schema, width)
			return paneBorder.Width(width).Height(height).Render(content)
		}
	}
	return ""
}

// buildDocPreview renders a document's fields, same as the editor content.
func (m model) buildDocPreview(doc *Doc, schema *Schema, width int) string {
	// Value receiver — safe to mutate the copy to reuse buildEditorContent
	m.selectedDoc = doc
	m.editorSchema = schema
	return m.buildEditorContent(width)
}

// buildDocListPreview renders a list of documents for a type, like the doc list pane.
func (m model) buildDocListPreview(node *StructureNode, width int) string {
	var lines []string

	// Header
	icon := ""
	if node.Icon != "" {
		icon = node.Icon + " "
	}
	docs := m.ds.Query(node.TypeName, node.Filter)
	headerText := icon + node.Title + dimStyle.Render(fmt.Sprintf(" %d", len(docs)))
	lines = append(lines, headerStyle.Width(width-2).Render(headerText))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	if len(docs) == 0 {
		lines = append(lines, "")
		lines = append(lines, dimStyle.Render("   No documents yet"))
		return lipgloss.JoinVertical(lipgloss.Left, lines...)
	}

	for _, doc := range docs {
		dot := statusStyle(doc.Status).Render(statusIcon(doc.Status))
		title := truncate(doc.Title, width-8)
		lines = append(lines, fmt.Sprintf(" %s %s", dot, normalItemStyle.Render(title)))
		lines = append(lines, fmt.Sprintf("     %s", dimStyle.Render(timeAgo(doc.UpdatedAt))))
	}
	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// buildListPreview renders a structure list's children as a summary.
func (m model) buildListPreview(node *StructureNode, width int) string {
	var lines []string

	icon := ""
	if node.Icon != "" {
		icon = node.Icon + " "
	}
	lines = append(lines, headerStyle.Width(width-2).Render(icon+node.Title))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	for _, item := range node.Items {
		if item.Type == NodeDivider {
			lines = append(lines, dimStyle.Render("  "+strings.Repeat("─", width-6)))
			continue
		}
		itemIcon := item.Icon
		if itemIcon == "" {
			itemIcon = " "
		}
		title := truncate(item.Title, width-8)
		chevron := dimStyle.Render("›")
		inner := fmt.Sprintf(" %s %s", itemIcon, title)
		gap := width - 2 - lipgloss.Width(inner) - 2
		if gap < 0 {
			gap = 0
		}
		lines = append(lines, normalItemStyle.Render(inner+strings.Repeat(" ", gap)+chevron))
	}
	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// ── Empty state ──────────────────────────────────────────────────────────────

func (m model) renderEmptyState(width, height int) string {
	var lines []string
	mid := height / 2
	for i := 0; i < mid-2; i++ {
		lines = append(lines, "")
	}
	msg := "Select a content type to begin"
	if len(m.path) > 0 {
		msg = "Select a document to edit"
	}
	lines = append(lines, dimStyle.Render("   "+msg))

	for len(lines) < height {
		lines = append(lines, "")
	}

	content := lipgloss.JoinVertical(lipgloss.Left, lines...)
	return paneBorder.Width(width).Height(height).Render(content)
}

// ── Helpers ──────────────────────────────────────────────────────────────────

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	if max < 4 {
		return s[:max]
	}
	return s[:max-1] + "..."
}

func toSlug(s string) string {
	s = strings.ToLower(s)
	s = strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			return r
		}
		return '-'
	}, s)
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-")
	}
	return strings.Trim(s, "-")
}
