package main

import (
	"fmt"
	"strings"

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
// ║  MODEL                                                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

type model struct {
	panes        []Pane
	activePane   int
	path         []string // selected structure item IDs at each depth
	selectedDoc  *Doc
	editorSchema *Schema
	editorScroll int
	width        int
	height       int
	showEditor   bool
}

func initialModel() model {
	m := model{width: 120, height: 40}
	m.rebuildPanes()
	return m
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
			// Doc list is terminal for structure nav
			goto done

		case NodeDocument:
			// Singleton — show editor directly
			docs := store[child.TypeName]
			if len(docs) > 0 {
				m.selectedDoc = &docs[0]
			}
			m.editorSchema = findSchema(child.TypeName)
			m.showEditor = true
			goto done
		}
	}
done:

	maxPane := len(m.panes) - 1
	if m.showEditor {
		maxPane++
	}
	if m.activePane > maxPane {
		m.activePane = maxPane
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
	docs := queryDocs(node.TypeName, node.Filter)
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

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  INIT / UPDATE                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		return m.handleKey(msg)
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	}
	return m, nil
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {

	case "q", "ctrl+c":
		return m, tea.Quit

	// ── Switch pane ──
	case "tab", "l", "right":
		maxPane := len(m.panes) - 1
		if m.showEditor {
			maxPane++
		}
		if m.activePane < maxPane {
			m.activePane++
		}

	case "shift+tab", "h", "left":
		if m.activePane > 0 {
			m.activePane--
		}

	// ── Navigate within pane ──
	case "j", "down":
		if m.activePane < len(m.panes) {
			pane := &m.panes[m.activePane]
			if pane.Cursor < len(pane.Items)-1 {
				pane.Cursor++
				// Skip dividers
				for pane.Cursor < len(pane.Items) && pane.Items[pane.Cursor].IsDivider {
					pane.Cursor++
				}
				if pane.Cursor >= len(pane.Items) {
					pane.Cursor = len(pane.Items) - 1
				}
			}
		} else if m.showEditor {
			m.editorScroll++
		}

	case "k", "up":
		if m.activePane < len(m.panes) {
			pane := &m.panes[m.activePane]
			if pane.Cursor > 0 {
				pane.Cursor--
				for pane.Cursor > 0 && pane.Items[pane.Cursor].IsDivider {
					pane.Cursor--
				}
			}
		} else if m.showEditor && m.editorScroll > 0 {
			m.editorScroll--
		}

	// ── Drill in ──
	case "enter":
		if m.activePane < len(m.panes) {
			pane := &m.panes[m.activePane]
			if pane.Cursor < len(pane.Items) {
				item := pane.Items[pane.Cursor]
				if item.IsDivider {
					break
				}
				if pane.IsDocList {
					m.selectedDoc = item.Doc
					m.editorSchema = findSchema(pane.Node.TypeName)
					m.showEditor = true
					m.editorScroll = 0
					m.activePane = len(m.panes)
				} else {
					m.path = m.path[:m.activePane]
					m.path = append(m.path, item.ID)
					m.editorScroll = 0
					m.rebuildPanes()
					if m.activePane < len(m.panes)-1 {
						m.activePane++
					} else if m.showEditor {
						m.activePane = len(m.panes)
					}
				}
			}
		}

	// ── Go back ──
	case "backspace", "esc":
		if m.showEditor && m.activePane >= len(m.panes) {
			m.showEditor = false
			m.selectedDoc = nil
			m.activePane = len(m.panes) - 1
		} else if len(m.path) > 0 {
			m.path = m.path[:len(m.path)-1]
			m.rebuildPanes()
			if m.activePane >= len(m.panes) {
				m.activePane = len(m.panes) - 1
			}
		}
	}

	return m, nil
}

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VIEW                                                                   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

func (m model) View() string {
	if m.width == 0 {
		return "Loading…"
	}

	toolbar := m.renderToolbar()
	helpBar := m.renderHelpBar()
	paneHeight := m.height - 4

	// Calculate widths
	paneWidth := 28
	if m.width > 160 {
		paneWidth = 32
	}
	editorWidth := m.width - (len(m.panes) * (paneWidth + 1))
	if editorWidth < 40 {
		editorWidth = 40
	}

	// Render panes
	var columns []string
	for i, pane := range m.panes {
		isActive := i == m.activePane
		columns = append(columns, m.renderPane(pane, paneWidth, paneHeight, isActive))
	}

	// Editor or empty state
	if m.showEditor {
		isActive := m.activePane >= len(m.panes)
		columns = append(columns, m.renderEditor(editorWidth, paneHeight, isActive))
	} else {
		columns = append(columns, m.renderEmptyState(editorWidth, paneHeight))
	}

	body := lipgloss.JoinHorizontal(lipgloss.Top, columns...)
	return lipgloss.JoinVertical(lipgloss.Left, toolbar, body, helpBar)
}

// ── Toolbar ──────────────────────────────────────────────────────────────────

func (m model) renderToolbar() string {
	logo := lipgloss.NewStyle().Bold(true).Foreground(highlight).Render("▣ Studio")
	tabs := dimStyle.Render("[") +
		lipgloss.NewStyle().Bold(true).
			Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"}).
			Render("Structure") +
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
			bc += dimStyle.Render(" › ")
		}
		if i == len(crumbs)-1 {
			bc += breadcrumbActiveStyle.Render(truncate(c, 20))
		} else {
			bc += breadcrumbStyle.Render(truncate(c, 14))
		}
	}

	left := logo + "  " + tabs + "  " + bc
	right := dimStyle.Render("⌘K Search")

	gap := m.width - lipgloss.Width(left) - lipgloss.Width(right) - 2
	if gap < 1 {
		gap = 1
	}
	return toolbarStyle.Width(m.width).Render(left + strings.Repeat(" ", gap) + right)
}

// ── Help bar ─────────────────────────────────────────────────────────────────

func (m model) renderHelpBar() string {
	return toolbarStyle.Width(m.width).Render(
		dimStyle.Render(" ↑↓/jk navigate  ←→/hl switch pane  enter select  esc/bksp back  q quit"),
	)
}

// ── List / DocList pane ──────────────────────────────────────────────────────

func (m model) renderPane(pane Pane, width, height int, isActive bool) string {
	var lines []string

	// Header
	icon := ""
	if pane.Node.Icon != "" {
		icon = pane.Node.Icon + " "
	}
	headerText := icon + pane.Node.Title
	if pane.IsDocList {
		headerText += dimStyle.Render(fmt.Sprintf(" %d", len(pane.Items)))
	}
	lines = append(lines, headerStyle.Width(width-2).Render(headerText))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	// Visible area
	visibleHeight := height - 3
	scroll := 0
	if pane.Cursor >= visibleHeight {
		scroll = pane.Cursor - visibleHeight + 1
	}

	for i := scroll; i < len(pane.Items) && i-scroll < visibleHeight; i++ {
		item := pane.Items[i]
		if item.IsDivider {
			lines = append(lines, dimStyle.Render("  "+strings.Repeat("─", width-6)))
			continue
		}

		isSelected := i == pane.Cursor && isActive
		lines = append(lines, m.renderPaneItem(item, width-2, isSelected, pane.IsDocList)...)
	}

	// Pad
	for len(lines) < height {
		lines = append(lines, strings.Repeat(" ", width-2))
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

func (m model) renderPaneItem(item PaneItem, width int, selected, isDocList bool) []string {
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
	return []string{style.Width(width).Render(inner + strings.Repeat(" ", gap) + chevron)}
}

// ── Editor pane ──────────────────────────────────────────────────────────────

func (m model) renderEditor(width, height int, isActive bool) string {
	if m.selectedDoc == nil || m.editorSchema == nil {
		return m.renderEmptyState(width, height)
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
		" %s %s · %d fields", m.editorSchema.Icon, m.editorSchema.Title, len(m.editorSchema.Fields),
	)))
	lines = append(lines, "")

	// Render each field from schema
	for _, field := range m.editorSchema.Fields {
		lines = append(lines, m.renderField(field, width-4)...)
		lines = append(lines, "")
	}

	// Footer
	lines = append(lines, "")
	footerLeft := dimStyle.Render(fmt.Sprintf("  Edited %s", timeAgo(m.selectedDoc.UpdatedAt)))
	publishBtn := lipgloss.NewStyle().
		Background(lipgloss.Color("#2563eb")).
		Foreground(lipgloss.Color("#ffffff")).
		Bold(true).
		Padding(0, 2).
		Render("Publish")
	gap := width - lipgloss.Width(footerLeft) - lipgloss.Width(publishBtn) - 4
	if gap < 0 {
		gap = 0
	}
	lines = append(lines, footerLeft+strings.Repeat(" ", gap)+publishBtn)

	// Scroll + clip
	maxScroll := len(lines) - height + 2
	if maxScroll < 0 {
		maxScroll = 0
	}
	scroll := m.editorScroll
	if scroll > maxScroll {
		scroll = maxScroll
	}

	end := scroll + height
	if end > len(lines) {
		end = len(lines)
	}
	visible := lines[scroll:end]

	for len(visible) < height {
		visible = append(visible, strings.Repeat(" ", width-2))
	}

	content := lipgloss.JoinVertical(lipgloss.Left, visible...)
	if isActive {
		return activePaneBorder.Width(width).Height(height).Render(content)
	}
	return paneBorder.Width(width).Height(height).Render(content)
}

// renderField generates the TUI lines for a single schema field.
func (m model) renderField(field Field, width int) []string {
	var lines []string
	lines = append(lines, editorLabelStyle.Render("  "+strings.ToUpper(field.Title)))

	// Try to resolve a value from the doc
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

	switch field.Type {
	case FieldString:
		lines = append(lines, "  "+editorFieldStyle.Width(width-2).Render(placeholder("Enter "+field.Title+"…")))

	case FieldSlug:
		slug := val
		if slug == "" && m.selectedDoc != nil {
			slug = toSlug(m.selectedDoc.Title)
		}
		box := editorFieldStyle.Width(width - 8).Render(dimStyle.Render(slug))
		lines = append(lines, "  "+box+" "+dimStyle.Render("[gen]"))

	case FieldText:
		rows := field.Rows
		if rows < 2 {
			rows = 3
		}
		content := placeholder("Enter " + field.Title + "…")
		for i := 1; i < rows; i++ {
			content += "\n" + strings.Repeat(" ", width-6)
		}
		lines = append(lines, "  "+editorFieldStyle.Width(width-2).Render(content))

	case FieldRichText:
		lines = append(lines, dimStyle.Render("  B  I  U  H1  H2  ❝  🔗  📷"))
		content := dimStyle.Render("Start writing…")
		content += "\n" + strings.Repeat(" ", width-6)
		content += "\n" + strings.Repeat(" ", width-6)
		lines = append(lines, "  "+editorFieldStyle.Width(width-2).Render(content))

	case FieldImage:
		box := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.AdaptiveColor{Light: "#d4d4d8", Dark: "#3f3f46"}).
			Width(width - 2).
			Align(lipgloss.Center).
			Padding(1, 0).
			Render(dimStyle.Render("🖼  Drop image or browse"))
		lines = append(lines, "  "+box)

	case FieldSelect:
		display := ""
		current := val
		if current == "" && len(field.Options) > 0 {
			current = field.Options[0]
		}
		for _, opt := range field.Options {
			if opt == current {
				display += lipgloss.NewStyle().Bold(true).Foreground(highlight).Render(" " + opt + " ")
			} else {
				display += dimStyle.Render(" " + opt + " ")
			}
		}
		lines = append(lines, "  "+display)

	case FieldBoolean:
		toggle := "○───"
		if val == "true" {
			toggle = statusPublished.Render("───●")
		}
		lines = append(lines, "  "+toggle)

	case FieldDatetime:
		dv := placeholder("YYYY-MM-DD HH:MM")
		lines = append(lines, "  "+editorFieldStyle.Width(width-2).Render(dv))

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
			rv = dimStyle.Render("Select " + field.RefType + "…")
		}
		lines = append(lines, "  "+editorFieldStyle.Width(width-2).Render("👤 "+rv+"  "+dimStyle.Render("›")))

	case FieldArray:
		lines = append(lines, "  "+dimStyle.Render("[ ] No items yet  [+ Add]"))

	default:
		lines = append(lines, "  "+editorFieldStyle.Width(width-2).Render(placeholder("…")))
	}

	return lines
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
	lines = append(lines, dimStyle.Render("   📂"))
	lines = append(lines, "")
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
	return s[:max-1] + "…"
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
