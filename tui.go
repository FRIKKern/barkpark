package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
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
	// Badge / Meta are the schema's list_preview values for this document
	// (Studio parity: badge right-aligned on the title row, meta dimmed on the
	// subtitle row). Empty ("" — no declaration or no value) renders the row
	// byte-identically to the pre-list_preview TUI.
	Badge string
	Meta  string
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

const (
	// borderCost is the number of terminal columns added by paneBorder's right border.
	borderCost = 1
	// minTitleWithBadge is the minimum column budget a doc-list row's TITLE must
	// keep for the right-aligned list_preview badge to render at all — below it
	// the badge is dropped first (the toolbar's tiered-degradation convention).
	minTitleWithBadge = 10
	// minEditorWidth is the PREFERRED minimum interior content width for the editor
	// column in the multi-pane (Miller-columns) layout. When the budget can host at
	// least one list column plus an editor this wide, we stay multi-pane.
	minEditorWidth = 40
	// minEditorUsable is the smallest interior editor width we will squeeze the
	// editor down to (dropping additional list columns first) before giving up on
	// multi-pane and collapsing to a single full-width column.
	minEditorUsable = 24
	// minFrameWidth is the horizontal twin of the m.height<5 guard: below it there
	// is no usable column at all, so View() emits the one-line "too small" message.
	minFrameWidth = 16
)

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
	// Editor field editing
	fieldCursor int               // which field is highlighted in editor
	editing     bool              // actively editing a field
	textInput   textinput.Model   // text input for current field
	dirtyValues map[string]string // unsaved field changes (fieldName -> value)
	dirty       bool              // has unsaved changes
	// New-document prompt (`n` in a doc-list pane): creating gates the one-line
	// title input (rendered in the help bar, like a vim command line) and
	// creatingType holds the schema type of the doc-list pane it was opened
	// from. The prompt reuses m.textInput — the field-edit input mechanics.
	creating     bool
	creatingType string
	// Delete confirm (`D`, two-press arming): the first D on a doc-list row or
	// an open editor doc arms the confirm (status-bar prompt); the second D
	// within the armed state deletes. esc disarms silently; any other key
	// disarms and then handles normally. The target is resolved at ARM time —
	// the id/type pair below — so the confirm always deletes what was prompted.
	deleteArmed   bool
	deleteDocID   string
	deleteDocType string
	// Armed discard-draft confirm (`R`×2) — same two-press shape as delete.
	// Armed only for a DRAFT whose published twin exists (probed at arm time:
	// the server does not twin-guard, and discarding the only draft would
	// delete the document — that's D's job, with its own confirm).
	discardArmed   bool
	discardDocID   string // the BARE published id (what the mutation takes)
	discardDocType string
	// workerID is this TUI's task-claim worker identity (BARKPARK_WORKER_ID,
	// default "tui-<hostname>"), computed once in initialModel.
	workerID string
	// Transient status line — surfaces save outcomes (errors + confirmations).
	// status holds the message; statusErr flags it as a failure (red vs green).
	// Both are cleared by the next key action so the line stays ephemeral.
	status    string
	statusErr bool
	// Scope selector (workspace/project/dataset picker)
	selector selectorState
	// Reference-field picker (enter on a focused reference field — refpicker.go).
	refPicker refPickerState
	// refTitles caches referenced-doc titles keyed by their BARE published id
	// (the stored wire value), so a reference field renders the target's TITLE
	// with the id dim beside it. Populated by the picker's fetch and by
	// cacheRefTitlesFor on editor open; never invalidated mid-session (titles
	// are display sugar — a stale one re-resolves on the next picker open).
	refTitles map[string]string
	// Search (`/` on a focused pane — search.go): searching gates the help-bar
	// query input (reuses m.textInput, the n-prompt mechanics); searchOpen +
	// searchHits/searchCursor/searchQuery hold the transient results modal.
	searching    bool
	searchOpen   bool
	searchQuery  string
	searchHits   []Doc
	searchCursor int
	// Diff view (`d` in the editor — diff.go): a transient draft↔published
	// field-diff modal. diffLines is pre-rendered at open; diffScroll windows
	// it (the modal is read-only, so no cursor — just scroll). diffLegend
	// names the two sides — the history view reuses the modal with
	// "- revision  + current".
	diffOpen   bool
	diffLines  []string
	diffScroll int
	diffLegend string
	// History view (`H` in the editor — history.go): the doc's revision rows,
	// newest first. enter diffs the highlighted revision against the current
	// editor values (the diff modal opens OVER the list; esc returns to it).
	historyOpen   bool
	historyRevs   []apiclient.Revision
	historyCursor int
	// Bulk marks (space on doc-list rows — bulk.go): bare published id → type.
	// ctrl+p / U over the set when focus is a pane; esc clears first.
	marked map[string]string
	// ── Paper rendering (pdrender) ──────────────────────────────────────────
	// paperRegistry/paperTheme/paperProfile are built ONCE in runTUI and reused
	// for every paper render. selectedPaperBlocks holds the decoded block tree of
	// the currently selected paper (nil for non-papers); it is re-parsed on
	// selection and on every DataStoreRefreshMsg so a Studio edit re-renders live.
	paperRegistry       *pdrender.Registry
	paperTheme          pdrender.Theme
	paperProfile        pdrender.Profile
	selectedPaperBlocks []pdrender.Block
}

func initialModel(ds *DataStore) model {
	// Build the pdrender theme/profile/registry ONCE: the theme mirrors styles.go
	// (chroma style + heading accents picked by terminal background), the profile
	// is detected once and reused, and the registry is the shared composition root
	// every paper render dispatches through.
	theme := barkparkPaperTheme()
	m := model{
		ds:            ds,
		width:         120,
		height:        40,
		workerID:      workerIdentity(),
		paperTheme:    theme,
		paperProfile:  detectPaperProfile(),
		paperRegistry: pdrender.DefaultRegistry(theme),
	}
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

// calcEditorWidth computes the interior content width for the editor column for
// the CURRENT terminal width. It delegates to the single horizontal-layout
// planner (computeLayout) so the viewport's content-wrap width always matches
// what View() will actually render — including the narrow collapse where the
// editor takes the whole frame (m.width - border).
func (m model) calcEditorWidth() int {
	return m.computeLayout().editorWidth
}

// layoutPlan is the result of the single horizontal-layout planner. Every
// width decision flows through computeLayout so View() and the viewport agree.
//
//	collapsed       — true when the frame is too narrow for even one list column
//	                  plus a usable editor; only ONE full-width column is shown.
//	startPane       — first list pane index to render (multi-pane windowing).
//	showListPanes   — true when list columns are rendered (always in multi-pane;
//	                  in collapse only when the focused column is a list pane).
//	editorWidth     — interior width for the editor/preview/empty column.
//	listWidth       — interior width for each rendered list column (== paneWidth
//	                  in multi-pane; == editorWidth in a collapsed-to-list view).
type layoutPlan struct {
	collapsed     bool
	startPane     int
	showListPanes bool
	editorWidth   int
	listWidth     int
}

// computeLayout is the ONE place horizontal space is divided. The hard budget is
// m.width; every returned column's physical width (interior + borderCost) sums to
// EXACTLY m.width, so the JoinHorizontal body equals m.width and never pads the
// toolbar/helpbar past the terminal.
//
// Multi-pane (Miller columns) is kept whenever the budget hosts at least one list
// column plus an editor of at least minEditorUsable interior columns. We first
// drop trailing-most LIST columns (oldest-first windowing, like before), then
// shrink the editor toward minEditorUsable, before falling back to collapse.
//
// Collapse renders a SINGLE full-width column = m.width: the editor/preview when
// the editor has focus or a doc is open, otherwise the focused LIST pane.
func (m model) computeLayout() layoutPlan {
	pw := m.paneWidth()
	colWidth := pw + borderCost // physical width of one bordered list column

	// How many list columns we'd LIKE to show (the full chain, capped later).
	want := len(m.panes)
	if want < 1 {
		want = 1
	}

	// Tier 1 — PREFERRED multi-pane, byte-identical to the pre-change layout: how
	// many list columns fit while leaving the editor at least minEditorWidth (40)
	// interior columns. At wide widths this is exactly the old windowing, so the
	// wide layout is UNCHANGED.
	maxListPreferred := (m.width - minEditorWidth - borderCost) / colWidth
	if maxListPreferred >= 1 {
		shown := want
		if shown > maxListPreferred {
			shown = maxListPreferred
		}
		start := len(m.panes) - shown
		if start < 0 {
			start = 0
		}
		editorWidth := m.width - shown*colWidth - borderCost
		if editorWidth < minEditorWidth {
			editorWidth = minEditorWidth
		}
		return layoutPlan{
			collapsed:     false,
			startPane:     start,
			showListPanes: true,
			editorWidth:   editorWidth,
			listWidth:     pw,
		}
	}

	// Tier 2 — SQUEEZED multi-pane: the editor can't reach 40 but a list column
	// plus an editor of at least minEditorUsable still fits. Drop extra list
	// columns first, then shrink the editor toward minEditorUsable. The summed
	// physical width stays == m.width, so no overflow.
	maxList := (m.width - minEditorUsable - borderCost) / colWidth
	if maxList >= 1 {
		shown := want
		if shown > maxList {
			shown = maxList
		}
		start := len(m.panes) - shown
		if start < 0 {
			start = 0
		}
		editorWidth := m.width - shown*colWidth - borderCost
		if editorWidth < minEditorUsable {
			editorWidth = minEditorUsable
		}
		return layoutPlan{
			collapsed:     false,
			startPane:     start,
			showListPanes: true,
			editorWidth:   editorWidth,
			listWidth:     pw,
		}
	}

	// Collapse: one full-width column that FOLLOWS FOCUS, so h/l/tab visibly move
	// between the single list column and the editor. Focus on a list pane shows
	// that pane; focus on the editor shows the editor. Only when there is no list
	// focus AND a doc is open do we default to the editor/preview surface.
	full := m.width - borderCost
	if full < 1 {
		full = 1
	}
	focusList := m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes)
	showList := focusList
	start := len(m.panes) - 1
	if start < 0 {
		start = 0
	}
	if focusList {
		start = m.focus.PaneIndex
	}
	return layoutPlan{
		collapsed:     true,
		startPane:     start,
		showListPanes: showList,
		editorWidth:   full,
		listWidth:     full,
	}
}

// paneHeight returns the interior content height passed to each column's
// .Height(ph). The border adds +2 rows on top of ph (verified: lipgloss .Height
// sets CONTENT height, then the border wraps outside it), so a border-wrapped
// column is ph+2 physical and the joined frame is toolbar(1) + (ph+2) +
// helpBar(1) = ph + 4. To keep the frame ≤ m.height we use ph = m.height - 4,
// floored at 1 (NOT 4 — the old floor let a small terminal overflow). View()
// short-circuits when the bounded frame still cannot fit (m.height < 5).
func (m model) paneHeight() int {
	ph := m.height - 4 // toolbar(1) + 2 border rows + helpbar(1)
	if ph < 1 {
		ph = 1
	}
	return ph
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

	// Re-decode the (possibly new) selected paper's blocks. Covers the cleared
	// case (selectedDoc == nil) and the NodeDocument auto-select above; the
	// DataStoreRefreshMsg path runs through here too, so a Studio edit re-parses.
	m.syncSelectedPaper()
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
	preview := schemaListPreview(node.TypeName)
	var items []PaneItem
	for i := range docs {
		items = append(items, PaneItem{
			ID:       docs[i].ID,
			Title:    docs[i].Title,
			Icon:     statusIcon(docs[i].Status),
			Status:   docs[i].Status,
			Subtitle: timeAgo(docs[i].UpdatedAt),
			Doc:      &docs[i],
			Badge:    previewValue(docs[i], preview.Badge),
			Meta:     previewValue(docs[i], preview.Meta),
		})
	}
	return Pane{Node: node, Items: items, IsDocList: true}
}

// refreshViewport rebuilds editor content without resetting scroll position.
func (m *model) refreshViewport() {
	if !m.vpReady {
		return
	}
	ew := m.calcEditorWidth()
	m.viewport.Width = ew
	m.viewport.Height = m.paneHeight()
	m.viewport.SetContent(m.buildEditorContent(ew))
}

// resetViewport rebuilds editor content and scrolls to top (for new document selection).
func (m *model) resetViewport() {
	m.refreshViewport()
	if m.vpReady {
		m.viewport.GotoTop()
	}
}

// syncSelectedPaper (re)decodes the selected document's block tree into
// m.selectedPaperBlocks when it is a paper, and clears it otherwise. It is the
// single seam where a Doc's raw block JSON becomes []pdrender.Block — called on
// selection (drillIn / rebuildPanes) and on every live refresh, so a paper
// edited in Studio re-parses and re-renders. Decoding lives HERE (in an Update
// path), never in View(), keeping View pure and synchronous.
func (m *model) syncSelectedPaper() {
	m.selectedPaperBlocks = nil
	if m.selectedDoc == nil || m.selectedDoc.Type != "paper" {
		return
	}
	raw := m.selectedDoc.PaperBlocks()
	if len(raw) == 0 {
		return
	}
	blocks, err := pdrender.Decode(raw)
	if err != nil {
		// A malformed block tree falls back to the existing view rather than
		// crashing — selectedPaperBlocks stays nil, isCurrentPaper() is false.
		return
	}
	m.selectedPaperBlocks = blocks
}

// isCurrentPaper reports whether the editor should render the selected document
// as a paper (a paper with a successfully decoded, non-empty block tree). When
// false, the editor falls through to the existing field-form path.
func (m model) isCurrentPaper() bool {
	return m.selectedDoc != nil &&
		m.selectedDoc.Type == "paper" &&
		len(m.selectedPaperBlocks) > 0
}

// findDocInPanes returns the (freshly-queried) Doc with the given id from the
// current doc-list panes, or nil. Used after a refresh to re-point selectedDoc
// at the rebuilt slice so its blocks reflect the latest server state. Type is a
// soft filter — matched when non-empty so two types sharing an id don't collide.
func (m *model) findDocInPanes(id, docType string) *Doc {
	for pi := range m.panes {
		pane := &m.panes[pi]
		if !pane.IsDocList {
			continue
		}
		for ii := range pane.Items {
			d := pane.Items[ii].Doc
			if d != nil && d.ID == id && (docType == "" || d.Type == docType) {
				return d
			}
		}
	}
	return nil
}

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  INIT / UPDATE                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case DataStoreRefreshMsg:
		m.refreshDocViews()
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
		// Re-clamp every pane's persisted scroll against the new interior height
		// so a shrink can't strand the window past the end. The window re-derives
		// from Cursor next render anyway; this keeps Pane.Scroll honest meanwhile.
		ih := m.listInteriorHeight(ph)
		pw := m.paneWidth()
		for i := range m.panes {
			m.panes[i].Scroll = m.listScrollOffset(m.panes[i], pw, ih)
		}
	}
	return m, nil
}

// refreshDocViews re-queries every pane and re-points an open editor at the
// freshly-fetched copy of the same document. rebuildPanes nils selectedDoc and
// the doc-list case does not restore it, so the restore here is what lets a
// Studio edit (or a TUI mutation's optimistic re-query) re-render live —
// shared by the DataStoreRefreshMsg handler and the task quick-actions.
func (m *model) refreshDocViews() {
	prevID, prevType, hadEditor := "", "", m.showEditor
	prevFocus := m.focus
	if m.selectedDoc != nil {
		prevID, prevType = m.selectedDoc.ID, m.selectedDoc.Type
	}
	m.rebuildPanes()
	// Re-resolve the previously-selected doc against the freshly-queried panes
	// so its (possibly edited) blocks re-parse. Only needed when rebuildPanes
	// did not itself restore a selection (the doc-list drill-in case).
	if hadEditor && m.selectedDoc == nil && prevID != "" {
		if doc := m.findDocInPanes(prevID, prevType); doc != nil {
			m.selectedDoc = doc
			m.editorSchema = findSchema(prevType)
			m.showEditor = true
			m.syncSelectedPaper()
			// Restore editor focus too: rebuildPanes nils the editor state
			// before its focus clamp runs, so the clamp demoted FocusEditor to
			// the pane. Without this, EVERY SSE refresh while a doc is open
			// silently kicked focus out of the editor — the next ctrl+p/ctrl+s
			// landed on the pane and did nothing (caught live: publish right
			// after n-create no-opped because the create's own SSE echo had
			// stolen focus).
			if prevFocus.Target == FocusEditor {
				m.focus = prevFocus
			}
		}
	}
	if m.showEditor && m.selectedDoc != nil {
		m.refreshViewport()
	}
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()

	// Any keystroke dismisses the transient status line. saveDocument re-sets
	// it after this, so the save outcome still surfaces on the ctrl+s press.
	m.clearStatus()

	// ── Scope selector modal: all input goes to the selector ──
	if m.selector.active {
		return m.handleSelectorKey(msg)
	}

	// ── Reference picker modal: all input goes to the picker ──
	if m.refPicker.active {
		return m.handleRefPickerKey(msg)
	}

	// ── Search results modal: j/k/enter/esc on the transient hit list ──
	if m.searchOpen {
		return m.handleSearchResultsKey(msg)
	}

	// ── Diff modal: j/k scroll, esc/q/d dismiss (diff.go). Checked BEFORE
	//    history so a revision diff stacks over the list — closing it falls
	//    back to the still-open history modal. ──
	if m.diffOpen {
		return m.handleDiffKey(msg)
	}

	// ── History modal: j/k/enter/esc on the revision list (history.go) ──
	if m.historyOpen {
		return m.handleHistoryKey(msg)
	}

	// ── Search query prompt: all input goes to the text input ──
	if m.searching {
		switch key {
		case "esc":
			// Cancel the prompt, discard the typed query.
			m.searching = false
		case "enter":
			return m.commitSearch()
		default:
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			return m, cmd
		}
		return m, nil
	}

	// ── New-document title prompt: all input goes to the text input ──
	if m.creating {
		switch key {
		case "esc":
			// Cancel the prompt, discard the typed title.
			m.creating = false
		case "enter":
			return m.commitCreateDoc()
		default:
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			return m, cmd
		}
		return m, nil
	}

	// ── Editing mode: all input goes to the text input ──
	if m.editing {
		switch key {
		case "esc":
			// Cancel edit, discard input
			m.editing = false
		case "enter":
			// Commit edit to dirty values
			m.commitFieldEdit()
			m.editing = false
		default:
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			// Re-render so the typed text appears LIVE in the field box. Without
			// this the keystroke is captured (Enter would commit it) but the
			// viewport is never rebuilt, so you can't see what you're typing.
			m.refreshViewport()
			return m, cmd
		}
		m.refreshViewport()
		return m, nil
	}

	// ── Armed delete confirm: the second D deletes the doc resolved at ARM
	//    time; esc disarms silently (swallowed — it must not also navigate
	//    back); any other key disarms and then handles normally below. ──
	if m.deleteArmed {
		armedID, armedType := m.deleteDocID, m.deleteDocType
		m.deleteArmed = false
		m.deleteDocID, m.deleteDocType = "", ""
		switch key {
		case "D":
			return m.performDelete(armedID, armedType)
		case "esc":
			return m, nil
		}
	}

	// ── Armed discard-draft confirm: same two-press contract as delete. ──
	if m.discardArmed {
		armedID, armedType := m.discardDocID, m.discardDocType
		m.discardArmed = false
		m.discardDocID, m.discardDocType = "", ""
		switch key {
		case "R":
			return m.performDiscard(armedID, armedType)
		case "esc":
			return m, nil
		}
	}

	// ── Read-only paper: the editor is a scroll surface, not a field form ──
	// A focused paper BYPASSES every field-editing handler (startFieldEdit,
	// toggleField, commitFieldEdit, ctrl+s save) — a paper is read-only in the
	// TUI (the documented v1 constraint; editing happens in Studio). Scroll the
	// viewport directly; the ~3-lines-per-field scrollToField heuristic does not
	// apply to free-form blocks. Pane/back navigation still works.
	if m.focus.Target == FocusEditor && m.isCurrentPaper() {
		switch key {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "s":
			return m, m.openSelector()
		case "j", "down":
			if m.vpReady {
				m.viewport.ScrollDown(1)
			}
			return m, nil
		case "k", "up":
			if m.vpReady {
				m.viewport.ScrollUp(1)
			}
			return m, nil
		case "ctrl+d", "pgdown":
			if m.vpReady {
				m.viewport.HalfPageDown()
			}
			return m, nil
		case "ctrl+u", "pgup":
			if m.vpReady {
				m.viewport.HalfPageUp()
			}
			return m, nil
		case " ":
			if m.vpReady {
				m.viewport.PageDown()
			}
			return m, nil
		case "g", "home":
			if m.vpReady {
				m.viewport.GotoTop()
			}
			return m, nil
		case "G", "end":
			if m.vpReady {
				m.viewport.GotoBottom()
			}
			return m, nil
		case "h", "left", "shift+tab", "backspace", "esc":
			// Leave the paper, back to the last pane (mirrors the field editor).
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
			return m, nil
		}
		// Any other key is a no-op on a read-only paper (no edit, no toggle).
		return m, nil
	}

	// ── Save ──
	if key == "ctrl+s" && m.focus.Target == FocusEditor && m.dirty {
		m.saveDocument()
		m.refreshViewport()
		return m, nil
	}

	// ── Publish (publish-only by design: ctrl+p never unpublishes) ──
	if key == "ctrl+p" && m.focus.Target == FocusEditor {
		m.publishDocument()
		m.refreshViewport()
		return m, nil
	}

	// ── Unpublish (`U`, editor only) — ctrl+p's peer on a separate key so
	//    neither action can fat-finger into the other. Inert on drafts. ──
	if key == "U" && m.focus.Target == FocusEditor {
		m.unpublishDocument()
		m.refreshViewport()
		return m, nil
	}

	// ── Bulk publish/unpublish (Studio-E3 parity — bulk.go): the same two
	//    keys, widened to the marked set when the focus is a list pane. ──
	if key == "ctrl+p" && m.focus.Target == FocusPane && len(m.marked) > 0 {
		m.bulkPublish()
		return m, nil
	}
	if key == "U" && m.focus.Target == FocusPane && len(m.marked) > 0 {
		m.bulkUnpublish()
		return m, nil
	}

	// ── Diff (`d`, editor only) — draft↔published field diff (diff.go).
	//    The look-before-you-leap step for ctrl+p / R×2. ──
	if key == "d" && m.focus.Target == FocusEditor {
		m.openDiffView()
		return m, nil
	}

	// ── History (`H`, editor only) — revision list + diff-vs-current
	//    (history.go). Read-only; restore stays in Studio / the API. ──
	if key == "H" && m.focus.Target == FocusEditor {
		m.openHistoryView()
		return m, nil
	}

	switch key {

	case "q", "ctrl+c":
		return m, tea.Quit

	// ── Open scope selector (workspace/project/dataset) ──
	case "s":
		return m, m.openSelector()

	// ── Switch pane / drill ──
	case "tab":
		if m.focus.Target == FocusPane {
			if m.focus.PaneIndex < len(m.panes)-1 {
				m.focus.PaneIndex++
			} else if m.showEditor {
				m.focus.Target = FocusEditor
				m.fieldCursor = 0
			}
		}

	case "l", "right":
		// → / l ENTERS the highlighted item (Miller-column navigation): drill into
		// it exactly like Enter — open its children as the next column and move
		// focus there, or open a document in the editor. Re-drilling after the
		// cursor moved replaces any stale rightward columns (drillIn truncates the
		// path at the focused pane). tab still cycles focus between already-open
		// panes without drilling; ← / h leaves (focus to the parent column, pop at
		// the root, exit the editor).
		if m.focus.Target == FocusPane {
			return m.drillIn()
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
			m.path = m.path[:len(m.path)-1]
			m.rebuildPanes()
		}

	// ── Navigate within pane / editor fields ──
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
			m.syncPaneScroll(pane)
		} else if m.focus.Target == FocusEditor && m.editorSchema != nil {
			if m.fieldCursor < len(m.editorSchema.Fields)-1 {
				m.fieldCursor++
			}
			m.scrollToField()
			m.refreshViewport()
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
			m.syncPaneScroll(pane)
		} else if m.focus.Target == FocusEditor {
			if m.fieldCursor > 0 {
				m.fieldCursor--
			}
			m.scrollToField()
			m.refreshViewport()
		}

	// ── Page / jump within a list pane (parity with the editor's scroll keys;
	//    the FocusEditor paper-scroll branch above owns these when the editor is
	//    focused, so there is no collision). ──
	case "pgdown":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.movePaneCursor(pane, +m.listInteriorHeight(m.paneHeight()))
		}

	case "pgup":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.movePaneCursor(pane, -m.listInteriorHeight(m.paneHeight()))
		}

	case "home", "g":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.jumpPaneCursor(pane, 0)
		}

	case "end", "G":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.jumpPaneCursor(pane, len(pane.Items)-1)
		}

	// ── New document (doc-list panes only — a pane that lists documents of a
	//    type, never a structure pane). Opens the one-line title prompt. ──
	case "n":
		if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) &&
			m.panes[m.focus.PaneIndex].IsDocList {
			m.startCreateDoc()
			return m, textinput.Blink
		}

	// ── Search (`/` on a focused pane only — never while editing text: the
	//    editing/creating/search-prompt branches above own those keystrokes,
	//    and the editor surfaces don't bind it). Opens the help-bar query
	//    input; enter runs the scoped search (see search.go). ──
	case "/":
		if m.focus.Target == FocusPane {
			m.startSearch()
			return m, textinput.Blink
		}

	// ── Delete (two-press confirm): the first D arms the status-bar prompt
	//    for the highlighted doc-list row or the open editor doc; the armed
	//    branch above handles the second press. ctrl+d was deliberately NOT
	//    used — it is the paper viewer's half-page-down. ──
	case "D":
		if doc, typeName := m.deleteTarget(); doc != nil {
			m.deleteArmed = true
			m.deleteDocID = doc.ID
			m.deleteDocType = typeName
			m.setStatus(fmt.Sprintf("delete %q? press D again to confirm · esc cancel", doc.Title), true)
		}
		return m, nil

	// ── Duplicate (`y` — yank a copy): clones the highlighted doc-list row or
	//    the open editor doc into a fresh draft titled "<title> (copy)",
	//    matching Studio's Duplicate header action, then drills into the new
	//    draft. Same target resolution as delete; inert on other surfaces.
	//    The paper viewer never reaches here (its branch above owns its keys),
	//    and Duplicate refuses papers anyway. ──
	case "y":
		if doc, typeName := m.deleteTarget(); doc != nil {
			return m.performDuplicate(doc, typeName)
		}

	// ── Discard draft (`R`×2 — revert to published): drops the highlighted
	//    or open doc's DRAFT, keeping the published version. Twin-guarded at
	//    arm time (the server isn't): a draft with no published twin refuses
	//    with a pointer to D, and a published doc has nothing to discard. ──
	case "R":
		if doc, typeName := m.deleteTarget(); doc != nil {
			m.armDiscard(doc, typeName)
		}
		return m, nil

	// ── Task quick actions (task doc-lists + an editor holding a task only;
	//    inert on every other surface) ──
	case "c":
		if doc := m.taskTarget(); doc != nil {
			m.claimTask(doc)
			return m, nil
		}

	case "x":
		if doc := m.taskTarget(); doc != nil {
			m.closeTask(doc)
			return m, nil
		}

	// ── Drill in / start editing ──
	case "enter":
		if m.focus.Target == FocusEditor && m.editorSchema != nil {
			m.startFieldEdit()
			m.refreshViewport()
			return m, textinput.Blink
		}
		return m.drillIn()

	// ── Toggle for boolean/select; mark for bulk on doc-list rows ──
	case " ":
		if m.focus.Target == FocusEditor && m.editorSchema != nil {
			m.toggleField()
			m.refreshViewport()
		} else if m.focus.Target == FocusPane {
			m.toggleMark()
		}

	// ── Go back (esc clears bulk marks first — second esc navigates) ──
	case "backspace", "esc":
		if m.focus.Target == FocusPane && len(m.marked) > 0 {
			m.clearMarks()
		} else if m.focus.Target == FocusEditor {
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
		} else if len(m.path) > 0 {
			m.path = m.path[:len(m.path)-1]
			m.rebuildPanes()
		}
	}

	return m, nil
}

// startFieldEdit begins editing the field at fieldCursor.
func (m *model) startFieldEdit() {
	if m.fieldCursor >= len(m.editorSchema.Fields) {
		return
	}
	field := m.editorSchema.Fields[m.fieldCursor]

	// Only string, text, slug, datetime, color, image fields are text-editable
	switch field.Type {
	case FieldString, FieldText, FieldSlug, FieldDatetime, FieldColor, FieldImage:
		m.editing = true
		m.textInput = textinput.New()
		m.textInput.Focus()
		m.textInput.CharLimit = 500
		m.textInput.Width = m.calcEditorWidth() - 12
		m.textInput.Prompt = ""

		// Pre-fill with current value. Image values may be a JSON envelope
		// ({"url","assetId"}) — edit the URL part, not the raw JSON.
		val := m.getFieldValue(field.Name)
		if field.Type == FieldImage {
			val, _ = parseImageValue(val)
		}
		m.textInput.SetValue(val)
	case FieldSelect:
		m.toggleField()
	case FieldBoolean:
		m.toggleField()
	case FieldReference:
		// Enter on a reference field opens the picker modal (refpicker.go)
		// instead of a text input — the value is a document id, never typed.
		m.openRefPicker(field)
	}
}

// commitFieldEdit saves the text input value to dirtyValues.
func (m *model) commitFieldEdit() {
	if m.fieldCursor >= len(m.editorSchema.Fields) {
		return
	}
	field := m.editorSchema.Fields[m.fieldCursor]
	val := m.textInput.Value()

	// Image fields edit the URL part of the value. An unchanged URL keeps
	// the original stored value verbatim (preserving the assetId linkage a
	// library pick carries); a new or cleared URL stores the bare string —
	// the asset linkage no longer matches a hand-entered URL.
	if field.Type == FieldImage {
		orig := m.getFieldValue(field.Name)
		if u, _ := parseImageValue(orig); strings.TrimSpace(val) == u {
			val = orig
		} else {
			val = strings.TrimSpace(val)
		}
	}

	if m.dirtyValues == nil {
		m.dirtyValues = make(map[string]string)
	}
	m.dirtyValues[field.Name] = val
	m.dirty = true

	// Also update the in-memory doc for immediate display
	m.applyDirtyToDoc()
}

// toggleField cycles select options or toggles boolean.
func (m *model) toggleField() {
	if m.fieldCursor >= len(m.editorSchema.Fields) {
		return
	}
	field := m.editorSchema.Fields[m.fieldCursor]

	if m.dirtyValues == nil {
		m.dirtyValues = make(map[string]string)
	}

	current := m.getFieldValue(field.Name)

	switch field.Type {
	case FieldBoolean:
		if current == "true" {
			m.dirtyValues[field.Name] = "false"
		} else {
			m.dirtyValues[field.Name] = "true"
		}
	case FieldSelect:
		if len(field.Options) > 0 {
			idx := 0
			for i, opt := range field.Options {
				if opt == current {
					idx = (i + 1) % len(field.Options)
					break
				}
			}
			m.dirtyValues[field.Name] = field.Options[idx]
		}
	}
	m.dirty = true
	m.applyDirtyToDoc()
}

// parseImageValue splits an image field's stored value into (url, assetId).
// Two accepted shapes, mirroring the Studio picker's bpParseMediaValue:
// a JSON object `{"url":…,"assetId":…}` (library/upload selections) or a
// bare URL string (legacy + hand-entered). Unparseable JSON degrades to
// treating the whole string as a URL, never an error.
func parseImageValue(v string) (string, string) {
	trimmed := strings.TrimSpace(v)
	if trimmed == "" {
		return "", ""
	}
	if strings.HasPrefix(trimmed, "{") {
		var o struct {
			URL     string `json:"url"`
			AssetID string `json:"assetId"`
			ID      string `json:"id"`
		}
		if err := json.Unmarshal([]byte(trimmed), &o); err == nil {
			if o.AssetID == "" {
				o.AssetID = o.ID
			}
			return o.URL, o.AssetID
		}
	}
	return trimmed, ""
}

// getFieldValue gets the current value for a field, checking dirty values first.
func (m model) getFieldValue(fieldName string) string {
	if m.dirtyValues != nil {
		if v, ok := m.dirtyValues[fieldName]; ok {
			return v
		}
	}
	if m.selectedDoc == nil {
		return ""
	}
	switch fieldName {
	case "title", "name":
		return m.selectedDoc.Title
	case "status":
		return m.selectedDoc.Status
	default:
		if m.selectedDoc.Values != nil {
			return m.selectedDoc.Values[fieldName]
		}
	}
	return ""
}

// applyDirtyToDoc updates the in-memory doc with dirty values for display.
func (m *model) applyDirtyToDoc() {
	if m.selectedDoc == nil || m.dirtyValues == nil {
		return
	}
	for k, v := range m.dirtyValues {
		switch k {
		case "title", "name":
			m.selectedDoc.Title = v
		case "status":
			m.selectedDoc.Status = v
		default:
			if m.selectedDoc.Values == nil {
				m.selectedDoc.Values = make(map[string]string)
			}
			m.selectedDoc.Values[k] = v
		}
	}
}

// saveDocument sends dirty values to the API as a patch mutation.
func (m *model) saveDocument() {
	if m.selectedDoc == nil || !m.dirty || len(m.dirtyValues) == 0 {
		return
	}

	setFields := make(map[string]interface{})
	for k, v := range m.dirtyValues {
		setFields[k] = v
	}

	mutation := map[string]interface{}{
		"patch": map[string]interface{}{
			"id":   m.selectedDoc.ID,
			"type": m.editorSchema.Name,
			"set":  setFields,
		},
	}

	if err := m.ds.Mutate([]map[string]interface{}{mutation}); err != nil {
		// Surface the failure — a tenancy 403, a 422 validation reject, or a
		// network drop would otherwise vanish and leave the doc dirty with no
		// feedback. The error string carries the status code + server body.
		m.setStatus(fmt.Sprintf("save failed: %v", err), true)
		return
	}
	m.dirtyValues = nil
	m.dirty = false
	m.setStatus("saved", false)
}

// publishDocument promotes the selected DRAFT to published via the publish
// mutation. Publish-only by design: a non-draft document is a silent no-op
// (the footer renders "published ✓" with no action). Unsaved changes block the
// publish — the server copies ITS draft to the published id, so unsaved local
// edits would silently miss the published document.
func (m *model) publishDocument() {
	if m.selectedDoc == nil || m.editorSchema == nil || m.selectedDoc.Status != "draft" {
		return
	}
	if m.dirty {
		m.setStatus("save first (ctrl+s)", true)
		return
	}
	// The mutate contract takes the BARE published id ({"publish":{"id":"x",
	// "type":"post"}}) — strip the drafts. prefix; the server derives the
	// drafts. twin itself.
	id := strings.TrimPrefix(m.selectedDoc.ID, "drafts.")
	if err := m.ds.Publish(m.editorSchema.Name, id); err != nil {
		m.setStatus(fmt.Sprintf("publish failed: %v", err), true)
		return
	}
	// Optimistic flip, like saveDocument's in-memory apply — the SSE refresh
	// will re-query and confirm. The published doc now lives at the bare id.
	m.selectedDoc.Status = "published"
	m.selectedDoc.ID = id
	m.setStatus("published", false)
}

// unpublishDocument demotes the open PUBLISHED doc back to a draft (`U` in
// the editor) — the missing peer of ctrl+p, which stays publish-only by
// design (separate keys so neither action can fat-finger into the other).
// The mutate contract takes the bare published id ({"unpublish":{"id":"x",
// "type":…}}); the server moves the row to its drafts. twin, mirrored here
// by the optimistic flip.
func (m *model) unpublishDocument() {
	if m.selectedDoc == nil || m.editorSchema == nil || m.selectedDoc.Status != "published" {
		return
	}
	id := strings.TrimPrefix(m.selectedDoc.ID, "drafts.")
	if err := m.ds.Unpublish(m.editorSchema.Name, id); err != nil {
		m.setStatus(fmt.Sprintf("unpublish failed: %v", err), true)
		return
	}
	m.selectedDoc.Status = "draft"
	m.selectedDoc.ID = "drafts." + id
	m.setStatus("unpublished — now a draft", false)
}

// startCreateDoc opens the one-line title prompt for a new document of the
// focused doc-list pane's type. Reuses the field-edit textinput mechanics;
// the input renders in the help bar (see renderHelpBar's creating branch).
func (m *model) startCreateDoc() {
	pane := m.panes[m.focus.PaneIndex]
	m.creating = true
	m.creatingType = pane.Node.TypeName
	m.textInput = textinput.New()
	m.textInput.Focus()
	m.textInput.CharLimit = 200
	m.textInput.Width = maxInt(m.width-30, 20)
	m.textInput.Prompt = ""
}

// creatingTypeTitle returns the human title of the schema being created
// ("Post"), falling back to the machine type name when the schema is unknown.
func (m model) creatingTypeTitle() string {
	if s := findSchema(m.creatingType); s != nil && s.Title != "" {
		return s.Title
	}
	return m.creatingType
}

// commitCreateDoc sends the create mutation for the typed title — with NO _id,
// so the server assigns drafts.<type>-<n> — then re-queries the panes and
// drills into the new document's editor. Esc never reaches here (the creating
// branch handles it); an empty title cancels with an error status.
func (m model) commitCreateDoc() (tea.Model, tea.Cmd) {
	m.creating = false
	title := strings.TrimSpace(m.textInput.Value())
	if title == "" {
		m.setStatus("title required", true)
		return m, nil
	}
	id, err := m.ds.Create(m.creatingType, title)
	if err != nil {
		m.setStatus(fmt.Sprintf("create failed: %v", err), true)
		return m, nil
	}
	// Optimistic refresh: re-query the panes NOW (the SSE refresh will also
	// fire) so the new doc appears in its list, then select + drill in.
	m.rebuildPanes()
	m.selectAndOpenDoc(id, m.creatingType)
	m.setStatus("created "+title, false)
	return m, nil
}

// selectAndOpenDoc parks the doc-list cursor on the (just re-queried) doc and
// drills into its editor — the shared landing for create and duplicate. A doc
// not found in any pane (e.g. filtered out) is a no-op; the status line still
// reports the outcome.
func (m *model) selectAndOpenDoc(id, typeName string) {
	doc := m.findDocInPanes(id, typeName)
	if doc == nil {
		return
	}
	// Park the doc-list cursor on the new doc so esc-back lands on it.
	for pi := range m.panes {
		pane := &m.panes[pi]
		if !pane.IsDocList {
			continue
		}
		for ii := range pane.Items {
			if pane.Items[ii].Doc != nil && pane.Items[ii].Doc.ID == id {
				pane.Cursor = ii
				m.focus = focusState{Target: FocusPane, PaneIndex: pi}
				m.syncPaneScroll(pane)
			}
		}
	}
	m.selectedDoc = doc
	m.editorSchema = findSchema(typeName)
	m.showEditor = true
	m.focus.Target = FocusEditor
	m.fieldCursor = 0
	m.syncSelectedPaper()
	m.resetViewport()
}

// performDuplicate clones the doc via Client.Duplicate — the same shape
// Studio's duplicate-doc lands server-side (fresh draft, " (copy)" title,
// content copied verbatim) — then re-queries and drills into the new draft,
// mirroring Studio's push_patch onto the duplicate. Papers refuse inside
// Duplicate with a pointer to Studio.
func (m model) performDuplicate(src *Doc, typeName string) (tea.Model, tea.Cmd) {
	id, err := m.ds.Duplicate(typeName, src.ID)
	if err != nil {
		m.setStatus(fmt.Sprintf("duplicate failed: %v", err), true)
		return m, nil
	}
	m.rebuildPanes()
	m.selectAndOpenDoc(id, typeName)
	m.setStatus("duplicated as "+id, false)
	return m, nil
}

// deleteTarget resolves the document a D-press would delete: the highlighted
// row of the focused doc-list pane, or the open editor doc when the editor has
// focus. Returns (nil, "") on every other surface (structure panes, dividers,
// no selection) so D stays inert there.
func (m model) deleteTarget() (*Doc, string) {
	if m.focus.Target == FocusEditor && m.selectedDoc != nil && m.editorSchema != nil {
		return m.selectedDoc, m.editorSchema.Name
	}
	if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) {
		pane := m.panes[m.focus.PaneIndex]
		if pane.IsDocList && pane.Node != nil && pane.Cursor < len(pane.Items) {
			if doc := pane.Items[pane.Cursor].Doc; doc != nil {
				return doc, pane.Node.TypeName
			}
		}
	}
	return nil, ""
}

// performDelete deletes the armed document via the delete mutation
// ({"delete":{"id":…,"type":…}}, matching Content.apply_one's delete arm).
// The id goes over the wire EXACTLY as listed — drafts. prefix included — per
// the API contract for drafts vs published rows. If the deleted doc is open
// in the editor we pop out first; either way the panes re-query so the row
// disappears now (the SSE refresh will confirm).
func (m model) performDelete(docID, typeName string) (tea.Model, tea.Cmd) {
	if !m.ds.Delete(typeName, docID) {
		m.setStatus("delete failed", true)
		return m, nil
	}
	if m.showEditor && m.selectedDoc != nil && m.selectedDoc.ID == docID {
		// Pop out of the deleted doc's editor — there is nothing left to show.
		m.showEditor = false
		m.selectedDoc = nil
		m.editorSchema = nil
		m.dirty = false
		m.dirtyValues = nil
		m.focus = focusState{Target: FocusPane, PaneIndex: maxInt(len(m.panes)-1, 0)}
		m.rebuildPanes()
	} else {
		// Keep any open editor pointed at its (unrelated) doc across the re-query.
		m.refreshDocViews()
	}
	m.setStatus("deleted", false)
	return m, nil
}

// armDiscard arms the R×2 discard confirm for doc — a DRAFT whose published
// twin exists. The twin probe (Get on the bare id) runs here at arm time
// because the server's discardDraft does NOT twin-guard: discarding the only
// draft deletes the document outright, which is D's job with its own confirm.
func (m *model) armDiscard(doc *Doc, typeName string) {
	if doc.Status != "draft" {
		m.setStatus("nothing to discard — not a draft", true)
		return
	}
	bare := strings.TrimPrefix(doc.ID, "drafts.")
	if _, ok := m.ds.Get(typeName, bare); !ok {
		m.setStatus("no published twin — D deletes the draft outright", true)
		return
	}
	m.discardArmed = true
	m.discardDocID = bare
	m.discardDocType = typeName
	m.setStatus(fmt.Sprintf("discard draft of %q, revert to published? press R again · esc cancel", doc.Title), true)
}

// performDiscard sends the discardDraft mutation ({"discardDraft":{"id":
// <bare>,"type":…}}, matching Content.discard_draft's bare-id contract),
// then re-queries and lands on the PUBLISHED doc — the surviving version is
// what the user reverts to, mirroring Studio's post-discard navigation.
func (m model) performDiscard(bareID, typeName string) (tea.Model, tea.Cmd) {
	if err := m.ds.DiscardDraft(typeName, bareID); err != nil {
		m.setStatus(fmt.Sprintf("discard failed: %v", err), true)
		return m, nil
	}
	m.rebuildPanes()
	m.selectAndOpenDoc(bareID, typeName)
	m.setStatus("draft discarded — showing published", false)
	return m, nil
}

// taskTarget resolves the doc the task quick-actions (c claim / x close)
// operate on: the highlighted row of a doc-list pane whose type is "task", or
// the open editor doc when the editor holds a task. nil everywhere else, so
// c/x stay inert outside task contexts.
func (m model) taskTarget() *Doc {
	if m.focus.Target == FocusEditor && m.selectedDoc != nil &&
		m.editorSchema != nil && m.editorSchema.Name == "task" {
		return m.selectedDoc
	}
	if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) {
		pane := m.panes[m.focus.PaneIndex]
		if pane.IsDocList && pane.Node != nil && pane.Node.TypeName == "task" &&
			pane.Cursor < len(pane.Items) {
			return pane.Items[pane.Cursor].Doc
		}
	}
	return nil
}

// claimTask claims the targeted task for this TUI's worker identity via the
// flat POST /v1/tasks/:doc_id/claim endpoint. On success the panes re-query
// (so the fresh doc carries the server's claim object — what closeTask reads
// the epoch from) and the status bar shows the fencing epoch; an ok:false
// envelope surfaces the server's reason string verbatim.
func (m *model) claimTask(doc *Doc) {
	epoch, err := m.ds.TaskClaim(doc.ID, m.workerID)
	if err != nil {
		m.setStatus(err.Error(), true)
		return
	}
	m.refreshDocViews()
	m.setStatus(fmt.Sprintf("claimed (epoch %d)", epoch), false)
}

// closeTask closes the targeted task via the flat POST /v1/tasks/:doc_id/close
// endpoint, echoing the claim-time fencing epoch read from the doc's claim
// object (Extra["claim"].epoch). An unclaimed task errors LOCALLY — the server
// would only fence it off anyway — and an ok:false envelope surfaces the
// server's reason verbatim (fenced_off, not_claimed, …).
func (m *model) closeTask(doc *Doc) {
	epoch, ok := doc.ClaimEpoch()
	if !ok {
		m.setStatus("not claimed — claim first (c)", true)
		return
	}
	if err := m.ds.TaskClose(doc.ID, m.workerID, epoch); err != nil {
		m.setStatus(err.Error(), true)
		return
	}
	m.refreshDocViews()
	m.setStatus("closed", false)
}

// workerIdentity computes the TUI's task-claim worker id once per process:
// BARKPARK_WORKER_ID when set, else "tui-<hostname>" ("tui-unknown" when the
// hostname is unreadable).
func workerIdentity() string {
	if v := os.Getenv("BARKPARK_WORKER_ID"); v != "" {
		return v
	}
	host, err := os.Hostname()
	if err != nil || host == "" {
		return "tui-unknown"
	}
	return "tui-" + host
}

// setStatus stores a transient status-line message. ok=false marks it an error
// (rendered red); ok=true marks it a confirmation (rendered green). The message
// is cleared by clearStatus on the next key action.
func (m *model) setStatus(msg string, isErr bool) {
	m.status = msg
	m.statusErr = isErr
}

// clearStatus wipes any pending status message. Called at the top of each key
// action so a status line only lingers until the user's next keystroke.
func (m *model) clearStatus() {
	m.status = ""
	m.statusErr = false
}

// scrollToField adjusts viewport to keep the focused field visible.
func (m *model) scrollToField() {
	// EXACT line offset, mirroring buildEditorContent's assembly: 4 header
	// lines, then each field's real rendered height + 1 separator. The old
	// ~3-lines-per-field approximation undershot badly on boxed fields
	// (label + 3 box rows + gap ≈ 5–6 lines), so the viewport stopped
	// following around field ~13 and the tail of a long form (a task's
	// claim/dependencies) was unreachable by keyboard.
	if !m.vpReady || m.editorSchema == nil {
		return
	}
	targetLine := 4
	fieldWidth := m.calcEditorWidth() - 4
	if fieldWidth < 20 {
		fieldWidth = 20
	}
	for i := 0; i < m.fieldCursor && i < len(m.editorSchema.Fields); i++ {
		targetLine += len(m.renderField(m.editorSchema.Fields[i], fieldWidth, false, false)) + 1
	}
	if targetLine > m.viewport.YOffset+m.viewport.Height-6 {
		m.viewport.SetYOffset(targetLine - m.viewport.Height + 8)
	} else if targetLine < m.viewport.YOffset+2 {
		m.viewport.SetYOffset(maxInt(targetLine-2, 0))
	}
}

// syncPaneScroll recomputes and persists the pane's scroll offset for the
// current focused-pane box height, so cursor-follow windowing survives across
// renders. Called after every cursor move in a list pane.
func (m *model) syncPaneScroll(pane *Pane) {
	ih := m.listInteriorHeight(m.paneHeight())
	pane.Scroll = m.listScrollOffset(*pane, m.paneWidth(), ih)
}

// movePaneCursor moves the cursor by delta items (clamped, skipping dividers in
// the direction of travel) and re-persists the scroll offset. Used by pgup/pgdn.
func (m *model) movePaneCursor(pane *Pane, delta int) {
	if len(pane.Items) == 0 {
		return
	}
	target := pane.Cursor + delta
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	// Skip a landing on a divider in the direction of travel.
	step := 1
	if delta < 0 {
		step = -1
	}
	for target >= 0 && target < len(pane.Items) && pane.Items[target].IsDivider {
		target += step
	}
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	pane.Cursor = target
	m.syncPaneScroll(pane)
}

// jumpPaneCursor sets the cursor to a specific index (clamped, skipping a
// trailing/leading divider) and re-persists the scroll offset. Used by g/G.
func (m *model) jumpPaneCursor(pane *Pane, target int) {
	if len(pane.Items) == 0 {
		return
	}
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	// If the extreme is a divider, walk inward to the nearest real item.
	step := 1
	if target == len(pane.Items)-1 {
		step = -1
	}
	for target >= 0 && target < len(pane.Items) && pane.Items[target].IsDivider {
		target += step
	}
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	pane.Cursor = target
	m.syncPaneScroll(pane)
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
		m.fieldCursor = 0
		m.syncSelectedPaper()
		m.cacheRefTitlesFor(m.editorSchema)
		m.resetViewport()
	} else {
		m.path = m.path[:m.focus.PaneIndex]
		m.path = append(m.path, item.ID)
		m.rebuildPanes()
		if m.showEditor {
			m.focus.Target = FocusEditor
			m.fieldCursor = 0
			m.resetViewport()
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

	// Terminal too small on EITHER axis: emit a single truncated line so the
	// frame can never exceed m.height OR m.width. The vertical floor is 5 (the
	// smallest bounded frame is ph(1) + 2 border + 2 bars); the horizontal floor
	// is minFrameWidth (below it no usable column survives). One combined guard.
	if m.height < 5 || m.width < minFrameWidth {
		return clampLine(truncate("terminal too small", m.width), m.width)
	}

	toolbar := m.renderToolbar()
	helpBar := m.renderHelpBar()
	ph := m.paneHeight()

	plan := m.computeLayout()

	// Render columns against the planned budget. The summed physical width of the
	// returned columns equals m.width, so the JoinHorizontal body is EXACTLY
	// m.width — the toolbar/helpbar are never padded past the terminal.
	var columns []string
	if plan.collapsed {
		// Single full-width column following focus.
		if plan.showListPanes && plan.startPane < len(m.panes) {
			isActive := m.focus.Target == FocusPane && plan.startPane == m.focus.PaneIndex
			columns = append(columns, m.renderPane(m.panes[plan.startPane], plan.listWidth, ph, isActive))
		} else if m.showEditor {
			isActive := m.focus.Target == FocusEditor
			columns = append(columns, m.renderEditor(plan.editorWidth, ph, isActive))
		} else if preview := m.renderPreview(plan.editorWidth, ph); preview != "" {
			columns = append(columns, preview)
		} else {
			columns = append(columns, m.renderEmptyState(plan.editorWidth, ph))
		}
	} else {
		// Multi-pane (Miller columns): list windows + editor/preview/empty.
		for i := plan.startPane; i < len(m.panes); i++ {
			isActive := m.focus.Target == FocusPane && i == m.focus.PaneIndex
			columns = append(columns, m.renderPane(m.panes[i], plan.listWidth, ph, isActive))
		}
		if m.showEditor {
			isActive := m.focus.Target == FocusEditor
			columns = append(columns, m.renderEditor(plan.editorWidth, ph, isActive))
		} else if preview := m.renderPreview(plan.editorWidth, ph); preview != "" {
			columns = append(columns, preview)
		} else {
			columns = append(columns, m.renderEmptyState(plan.editorWidth, ph))
		}
	}

	var body string
	switch {
	case m.selector.active:
		// Replace the column body with the centred scope-selector modal.
		body = m.renderSelector(m.width, ph)
	case m.refPicker.active:
		body = m.renderRefPicker(m.width, ph)
	case m.searchOpen:
		body = m.renderSearchResults(m.width, ph)
	case m.diffOpen:
		body = m.renderDiffView(m.width, ph)
	case m.historyOpen:
		body = m.renderHistoryView(m.width, ph)
	default:
		body = lipgloss.JoinHorizontal(lipgloss.Top, columns...)
	}

	// Per-line width backstop: clamp every body row to m.width. computeLayout
	// already keeps the sum at m.width, but this guarantees no row can overflow
	// horizontally even in odd transient states (mid-resize, modal, rounding).
	body = clampBlock(body, m.width)

	frame := lipgloss.JoinVertical(lipgloss.Left, toolbar, body, helpBar)
	return clampBlock(frame, m.width)
}

// clampLine truncates a single line to at most w display columns (ANSI/width
// aware, no ellipsis — the caller chooses the message). Never widens.
func clampLine(s string, w int) string {
	if w < 0 {
		w = 0
	}
	return ansi.Truncate(s, w, "")
}

// clampBlock applies clampLine to every line of a multi-line block. The
// horizontal safety net: nothing the body emits can exceed m.width.
func clampBlock(s string, w int) string {
	lines := strings.Split(s, "\n")
	for i, ln := range lines {
		if lipgloss.Width(ln) > w {
			lines[i] = clampLine(ln, w)
		}
	}
	return strings.Join(lines, "\n")
}

// clampItemLines flattens a list-item's rendered lines into line-accurate,
// width-bounded physical rows: any embedded newline (lipgloss soft-wrap) is
// split out and every resulting segment is hard-truncated to w columns. This
// keeps renderListInterior's per-item row count truthful so the window can never
// overflow the box height, and keeps each row within the column width.
func clampItemLines(il []string, w int) []string {
	var out []string
	for _, seg := range il {
		for _, line := range strings.Split(seg, "\n") {
			if lipgloss.Width(line) > w {
				line = clampLine(line, w)
			}
			out = append(out, line)
		}
	}
	return out
}

// ── Toolbar ──────────────────────────────────────────────────────────────────

func (m model) renderToolbar() string {
	logo := logoStyle.Render("▣ Studio")
	tabs := dimStyle.Render("[") +
		activeTabStyle.Render("Structure") +
		dimStyle.Render("] ") +
		dimStyle.Render("Vision")
	prefix := logo + "  " + tabs // highest-value left segment — kept longest

	// Breadcrumbs (the elastic, lowest-priority left segment).
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

	scope := fmt.Sprintf("%s/%s/%s", m.ds.Workspace, m.ds.Project, m.ds.Dataset)
	right := breadcrumbStyle.Render("⌗ "+scope) + dimStyle.Render("  s switch")

	// Assemble with graceful degradation so the content always fits on ONE line
	// of width m.width — lipgloss soft-wraps any content wider than the style
	// width, which would steal extra rows from the body budget (ph = h-4).
	//
	// Tier 1: prefix + breadcrumb + gap + right (full)
	// Tier 2: prefix + gap + right            (drop breadcrumb)
	// Tier 3: prefix + gap + "s switch"       (drop scope, keep switch hint)
	// Tier 4: ansi.Truncate(prefix+breadcrumb, m.width)  (no room for the right rail)
	// Backstop: ansi.Truncate the chosen line to m.width with an ellipsis.
	const minGap = 2 // breathing room between left and right rails
	rightW := lipgloss.Width(right)
	switchOnly := dimStyle.Render("s switch")
	switchW := lipgloss.Width(switchOnly)

	var content string
	switch {
	case lipgloss.Width(prefix)+lipgloss.Width("  "+bc)+minGap+rightW <= m.width:
		// Tier 1 — everything fits.
		left := prefix + "  " + bc
		gap := m.width - lipgloss.Width(left) - rightW
		content = left + strings.Repeat(" ", gap) + right
	case lipgloss.Width(prefix)+minGap+rightW <= m.width:
		// Tier 2 — drop the breadcrumb, keep prefix + full right rail.
		gap := m.width - lipgloss.Width(prefix) - rightW
		content = prefix + strings.Repeat(" ", gap) + right
	case lipgloss.Width(prefix)+minGap+switchW <= m.width:
		// Tier 3 — drop the scope, keep prefix + the "s switch" affordance.
		gap := m.width - lipgloss.Width(prefix) - switchW
		content = prefix + strings.Repeat(" ", gap) + switchOnly
	default:
		// Tier 4 — no room for any right rail; show as much of the left as fits.
		content = prefix + "  " + bc
	}

	// Hard backstop: clamp to exactly m.width display columns (ANSI/width-aware,
	// ellipsis tail). Guarantees one physical line ≤ m.width even at width=20.
	content = ansi.Truncate(content, m.width, "…")
	return toolbarStyle.Width(m.width).MaxHeight(1).Render(content)
}

// ── Help bar ─────────────────────────────────────────────────────────────────

func (m model) renderHelpBar() string {
	// New-document title prompt takes over the bar (vim-command-line style):
	// the one-line input lives HERE, in the chrome row, not in a pane.
	if m.creating {
		prompt := dimStyle.Render(" Title for new "+m.creatingTypeTitle()+": ") + m.textInput.View()
		prompt = ansi.Truncate(prompt, m.width, "…")
		return toolbarStyle.Width(m.width).MaxHeight(1).Render(prompt)
	}

	// Search query prompt — same vim-command-line takeover as the n-prompt.
	if m.searching {
		prompt := dimStyle.Render(" Search: ") + m.textInput.View()
		prompt = ansi.Truncate(prompt, m.width, "…")
		return toolbarStyle.Width(m.width).MaxHeight(1).Render(prompt)
	}

	// A pending status message takes over the bar — a failed save (red) or a
	// "saved" confirmation (green) must be impossible to miss.
	if m.status != "" {
		style := statusPublished // green = ok
		prefix := "✓ "
		if m.statusErr {
			style = statusDraft // amber/red = error
			prefix = "✕ "
		}
		styled := style.Bold(true).Render(" " + prefix + m.status)
		// Clamp the styled line to one physical row ≤ m.width (ANSI/width-aware)
		// so a long status can never soft-wrap and steal a body row.
		styled = ansi.Truncate(styled, m.width, "…")
		return toolbarStyle.Width(m.width).MaxHeight(1).Render(styled)
	}

	var help string
	if m.selector.active {
		help = " tab/j/k move  enter next/apply  ctrl+s apply  esc cancel"
	} else if m.refPicker.active {
		help = " j/k move  enter select  esc cancel"
	} else if m.searchOpen {
		help = " j/k move  enter open  esc dismiss"
	} else if m.editing {
		help = " type to edit  enter confirm  esc cancel"
	} else if m.focus.Target == FocusEditor && m.isCurrentPaper() {
		help = " j/k scroll  ctrl+d/u half-page  g/G top/bottom  read-only  esc back"
	} else if m.focus.Target == FocusEditor {
		if m.editorSchema != nil && m.editorSchema.Name == "task" {
			// Editor holding a task: the c/x quick actions work here too (see
			// taskTarget) — advertise them where they apply, like the task list does.
			help = " j/k fields  enter edit  ctrl+s save  c claim  x close  y dup  esc back"
		} else {
			help = " j/k fields  enter edit  space toggle  ctrl+s save  ctrl+p publish  U unpub  d diff  H hist  R discard  y dup  s scope  esc back"
		}
	} else if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) &&
		m.panes[m.focus.PaneIndex].IsDocList {
		if node := m.panes[m.focus.PaneIndex].Node; node != nil && node.TypeName == "task" {
			// Task list: the quick-action verbs lead — claim/close at terminal speed.
			help = " j/k navigate  c claim  x close  y dup  D delete  n new  / search  enter select  esc back"
		} else if len(m.marked) > 0 {
			// Marks present: the bulk verbs lead (Studio's floating action bar).
			help = fmt.Sprintf(" %d marked  space mark  ctrl+p publish marked  U unpub marked  esc clear", len(m.marked))
		} else {
			// Doc-list pane: surface the n-new / D-delete affordances, subtle, in hint order.
			help = " j/k navigate  space mark  n new  y dup  R discard  D delete  / search  enter select  s scope  esc back  q quit"
		}
	} else {
		help = " j/k navigate  / search  h/l switch pane  enter select  s scope  esc back  q quit"
	}
	// Clamp to one physical row ≤ m.width before styling so the bar never
	// soft-wraps at narrow widths; a shorter/elided help string is fine.
	styled := ansi.Truncate(dimStyle.Render(help), m.width, "…")
	return toolbarStyle.Width(m.width).MaxHeight(1).Render(styled)
}

// ── List / DocList pane ──────────────────────────────────────────────────────

// maxInt returns the larger of two ints (avoids negative repeat counts).
func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// renderListInterior is the single, line-accurate windowing primitive for every
// list pane — both the focused renderPane and the right-pane previews route
// through it so they can never diverge. It returns the exact interior lines for
// the items (NOT the header/divider/border), windowed so pane.Cursor's full
// rendered line span is always inside the window, with the partially-visible
// trailing row hard-truncated so it NEVER emits more than interiorHeight lines.
//
// interiorHeight is the rows available for items PLUS the affordance row. When
// the content is clipped (top or bottom hidden), one interior row is reserved
// for the dim "↑ N more" / "↓ N more" counter; when the list fits, no row is
// reserved and the output is byte-identical to the pre-change flush render.
//
// isActive drives the selected (active pane) vs dim-cursor (inactive/preview)
// styling of the cursor row. above/below count items hidden above / below the
// window (0/0 == the list fits and no affordance row is emitted).
func (m model) renderListInterior(pane Pane, width, interiorHeight int, isActive bool) (lines []string, above, below int) {
	if interiorHeight < 1 {
		interiorHeight = 1
	}

	// Render every item to its physical lines once, recording each item's start
	// line + span. Doc-list items are 2 lines (title + subtitle); structure
	// items and dividers are 1 line — line-accurate, no item-vs-line miscount.
	rsStart := make([]int, len(pane.Items))
	rsLen := make([]int, len(pane.Items))
	var allLines []string
	for i, item := range pane.Items {
		rsStart[i] = len(allLines)
		var il []string
		if item.IsDivider {
			il = []string{dimStyle.Render("  " + strings.Repeat("─", maxInt(width-4, 0)))}
		} else {
			isSelected := i == pane.Cursor && isActive
			isCursor := i == pane.Cursor && !isActive
			il = m.renderPaneItem(item, width, isSelected, isCursor, pane.IsDocList)
		}
		// Line-accuracy backstop: a styled item whose content exceeds `width`
		// soft-wraps into a single string carrying embedded newlines — len(il)
		// would then undercount physical rows and the window would overflow the
		// box (and the column would exceed its width). Split any embedded newlines
		// and hard-truncate each physical segment to `width` so rsLen matches the
		// real rendered height and nothing can spill horizontally. Items that fit
		// (the common case — real icons are short) pass through byte-identical.
		il = clampItemLines(il, width)
		rsLen[i] = len(il)
		allLines = append(allLines, il...)
	}
	total := len(allLines)

	// Short list: fits flush, no affordance — byte-identical to today.
	if total <= interiorHeight {
		return allLines, 0, 0
	}

	// Clipped: reserve one row for the affordance, so items get interiorHeight-1.
	itemRows := interiorHeight - 1
	if itemRows < 1 {
		itemRows = 1
	}

	// Cursor-follow window: keep pane.Cursor's full line span inside the window.
	cursor := pane.Cursor
	if cursor < 0 {
		cursor = 0
	}
	if cursor >= len(pane.Items) {
		cursor = len(pane.Items) - 1
	}
	cStart := rsStart[cursor]
	cEnd := cStart + rsLen[cursor] // exclusive

	// Start from the persisted offset, then nudge to satisfy cursor-follow.
	scroll := pane.Scroll
	if scroll < 0 {
		scroll = 0
	}
	if cStart < scroll {
		scroll = cStart // cursor above window → align top to cursor
	}
	if cEnd > scroll+itemRows {
		scroll = cEnd - itemRows // cursor below window → align bottom to cursor
	}
	// Clamp so we never scroll past the end or below zero.
	maxScroll := total - itemRows
	if maxScroll < 0 {
		maxScroll = 0
	}
	if scroll > maxScroll {
		scroll = maxScroll
	}
	if scroll < 0 {
		scroll = 0
	}

	// Emit exactly itemRows lines from the window, hard-truncating any partial
	// trailing row beyond the budget.
	end := scroll + itemRows
	if end > total {
		end = total
	}
	out := append([]string(nil), allLines[scroll:end]...)

	// Count items fully hidden above / below the window.
	for i := range pane.Items {
		if rsStart[i]+rsLen[i] <= scroll {
			above++
		} else if rsStart[i] >= end {
			below++
		}
	}

	// Affordance row (dim chrome). The bottom counter wins the single reserved
	// row when both edges are clipped — it signals there is more to scroll into.
	var aff string
	if below > 0 {
		aff = dimStyle.Render(fmt.Sprintf(" ↓ %d more", below))
	} else if above > 0 {
		aff = dimStyle.Render(fmt.Sprintf(" ↑ %d more", above))
	}
	out = append(out, aff)
	if len(out) > interiorHeight {
		out = out[:interiorHeight]
	}
	return out, above, below
}

// listScrollOffset recomputes the persisted Pane.Scroll for the given interior
// height so cursor-follow windowing survives across renders and resizes. Mirrors
// the windowing math in renderListInterior; called on cursor moves and resize.
func (m model) listScrollOffset(pane Pane, width, interiorHeight int) int {
	if interiorHeight < 1 {
		interiorHeight = 1
	}
	// Total rendered lines (2 per doc-list item, 1 otherwise).
	total := 0
	starts := make([]int, len(pane.Items))
	lens := make([]int, len(pane.Items))
	for i, item := range pane.Items {
		starts[i] = total
		n := 1
		if !item.IsDivider && pane.IsDocList {
			n = 2
		}
		lens[i] = n
		total += n
	}
	if total <= interiorHeight {
		return 0
	}
	itemRows := interiorHeight - 1
	if itemRows < 1 {
		itemRows = 1
	}
	cursor := pane.Cursor
	if cursor < 0 {
		cursor = 0
	}
	if cursor >= len(pane.Items) {
		cursor = len(pane.Items) - 1
	}
	cStart := starts[cursor]
	cEnd := cStart + lens[cursor]
	scroll := pane.Scroll
	if scroll < 0 {
		scroll = 0
	}
	if cStart < scroll {
		scroll = cStart
	}
	if cEnd > scroll+itemRows {
		scroll = cEnd - itemRows
	}
	maxScroll := total - itemRows
	if maxScroll < 0 {
		maxScroll = 0
	}
	if scroll > maxScroll {
		scroll = maxScroll
	}
	if scroll < 0 {
		scroll = 0
	}
	return scroll
}

// listInteriorHeight returns the item+affordance budget for a list pane whose
// content area is boxHeight lines (the lines slice is truncated to boxHeight
// before the border wraps it). Header(1) + divider(1) are subtracted; the
// border's +2 rows live outside the lines slice, so they are NOT subtracted
// here. Floored at 1.
func (m model) listInteriorHeight(boxHeight int) int {
	ih := boxHeight - 2 // header + divider
	if ih < 1 {
		ih = 1
	}
	return ih
}

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

	// Interior: header + divider already consumed 2 of the box's content rows;
	// the box is height tall (border counts toward .Height), so the item area is
	// height - 4 (border 2 + header + divider). renderListInterior windows it,
	// clips to budget, and reserves an affordance row only when actually clipped.
	interiorHeight := m.listInteriorHeight(height)
	interior, _, _ := m.renderListInterior(pane, width, interiorHeight, isActive)
	lines = append(lines, interior...)

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
		// list_preview extras (schema-declared; Studio parity). The meta value
		// joins the subtitle row (dim, " · "-separated); the badge right-aligns
		// on the title row, bracketed dim like the editor header's "[status]"
		// badge. Degradation order mirrors the toolbar tiers: the badge is the
		// FIRST thing dropped when the pane narrows — the title keeps at least
		// minTitleWithBadge columns or the badge goes. With no declaration
		// (item.Badge == "" and item.Meta == "") every string below is
		// byte-identical to the pre-list_preview rendering.
		sub := item.Subtitle
		if item.Meta != "" {
			if sub == "" {
				sub = item.Meta
			} else {
				sub += " · " + item.Meta
			}
		}
		titleMax := width - 6
		badge := ""
		if item.Badge != "" {
			b := "[" + item.Badge + "]"
			if titleMax-(lipgloss.Width(b)+1) >= minTitleWithBadge {
				badge = b
				titleMax -= lipgloss.Width(b) + 1
			}
		}

		dot := statusStyle(item.Status).Render(item.Icon)
		title := truncate(item.Title, titleMax)
		pad := ""
		if badge != "" {
			// Right-align the badge: leading " %s %s" is 2 cols + icon + title.
			gap := width - 2 - lipgloss.Width(item.Icon) - lipgloss.Width(title) -
				lipgloss.Width(badge) - 1
			if gap < 1 {
				gap = 1
			}
			pad = strings.Repeat(" ", gap)
		}

		// Bulk mark (space — bulk.go): marked rows swap the leading space for
		// a highlighted ✓, same physical width so nothing shifts.
		lead := " "
		if item.Doc != nil && m.marked != nil {
			if _, ok := m.marked[strings.TrimPrefix(item.Doc.ID, "drafts.")]; ok {
				lead = lipgloss.NewStyle().Bold(true).Foreground(highlight).Render("✓")
			}
		}

		line1 := fmt.Sprintf("%s%s %s", lead, dot, style.Render(title))
		if badge != "" {
			line1 += pad + dimStyle.Render(badge)
		}
		line2 := fmt.Sprintf("     %s", dimStyle.Render(sub))
		if selected {
			line1 = selectedItemStyle.Width(width).Render(fmt.Sprintf(" %s %s", dot, title) + pad + badge)
			line2 = selectedItemStyle.Width(width).Render(fmt.Sprintf("     %s", sub))
		} else if isCursor {
			line1 = inactiveCursorStyle.Width(width).Render(fmt.Sprintf(" %s %s", dot, title) + pad + badge)
			line2 = inactiveCursorStyle.Width(width).Render(fmt.Sprintf("     %s", sub))
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
		line = inactiveCursorStyle.Width(width).Render(inner + strings.Repeat(" ", gap) + chevron)
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

	// Paper branch: a paper with a decoded block tree renders as a real document
	// via pdrender, NOT as a field form. buildDocPreview routes through here too,
	// so papers render in the preview pane for free. Any non-paper (or a paper
	// with no/undecodable blocks) falls through to the field-form loop unchanged.
	if m.isCurrentPaper() {
		return m.buildPaperContent(width)
	}

	var lines []string

	// Header
	dot := statusStyle(m.selectedDoc.Status).Render(statusIcon(m.selectedDoc.Status))
	title := truncate(m.selectedDoc.Title, width-20)
	header := fmt.Sprintf(" %s %s", dot, headerStyle.Render(title))
	if m.selectedDoc.Status != "" {
		header += " " + dimStyle.Render("["+m.selectedDoc.Status+"]")
	}
	lines = append(lines, header)
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", maxInt(width-2, 0))))

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
	isEditorFocused := m.focus.Target == FocusEditor
	for i, field := range m.editorSchema.Fields {
		isFocused := isEditorFocused && i == m.fieldCursor
		isEditing := isFocused && m.editing
		lines = append(lines, m.renderField(field, fieldWidth, isFocused, isEditing)...)
		if i < len(m.editorSchema.Fields)-1 {
			lines = append(lines, "")
		}
	}

	// Footer
	lines = append(lines, "")
	lines = append(lines, dividerStyle.Render(" "+strings.Repeat("─", maxInt(width-4, 0))))

	footerLeft := dimStyle.Render(fmt.Sprintf("  Edited %s", timeAgo(m.selectedDoc.UpdatedAt)))

	// Publish affordance reflects the doc's real state (the old static
	// "Publish" button was wired to nothing): a draft advertises the ctrl+p
	// binding; a published doc shows a dim, action-free checkmark; any other
	// status (e.g. a select-field "active") shows neither.
	var publishBtn string
	switch m.selectedDoc.Status {
	case "draft":
		publishBtn = publishBtnStyle.Render("Ctrl+P publish")
	case "published":
		publishBtn = dimStyle.Render("published ✓ · U unpublish")
	}

	var footerRight string
	if m.dirty {
		footerRight = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#f59e0b")).Bold(true).
			Render("* Unsaved") + "  " +
			dimStyle.Render("Ctrl+S save")
		if publishBtn != "" {
			footerRight += "  " + publishBtn
		}
	} else {
		footerRight = publishBtn
	}
	gap := width - lipgloss.Width(footerLeft) - lipgloss.Width(footerRight) - 4
	if gap < 0 {
		gap = 0
	}
	lines = append(lines, footerLeft+strings.Repeat(" ", gap)+footerRight)

	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// indentLines prefixes n spaces to EVERY line of s. lipgloss box styles
// (RoundedBorder etc.) render to a multi-line string (top border / content
// row(s) / bottom border); a bare `"  " + box` concat only indents the first
// line, shifting the top border right while content + bottom border stay at
// column 0. Indenting every line keeps the whole box a clean rectangle.
func indentLines(s string, n int) string {
	pad := strings.Repeat(" ", n)
	parts := strings.Split(s, "\n")
	for i, p := range parts {
		parts[i] = pad + p
	}
	return strings.Join(parts, "\n")
}

// renderField generates the TUI lines for a single schema field.
func (m model) renderField(field Field, width int, isFocused, isEditing bool) []string {
	var lines []string

	// Label — highlight when focused. A right-aligned dim annotation (e.g. the
	// slug field's [gen]) rides on the label line so every field box can keep the
	// same full width and all the box right edges line up.
	labelText := "  " + strings.ToUpper(field.Title)
	labelStyle := editorLabelStyle
	if isFocused {
		labelStyle = lipgloss.NewStyle().Bold(true).Foreground(highlight)
	}
	annotation := ""
	if field.Type == FieldSlug {
		annotation = dimStyle.Render("[gen]")
	}
	if annotation != "" {
		gap := width - lipgloss.Width(labelText) - lipgloss.Width(annotation)
		if gap < 1 {
			gap = 1
		}
		lines = append(lines, labelStyle.Render(labelText)+strings.Repeat(" ", gap)+annotation)
	} else {
		lines = append(lines, labelStyle.Render(labelText))
	}

	val := m.getFieldValue(field.Name)

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

	// Active field border style
	activeFieldStyle := editorFieldStyle
	if isFocused {
		activeFieldStyle = focusedFieldStyle
	}

	switch field.Type {
	case FieldString:
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(placeholder("Enter "+field.Title+"...")), 2))
		}

	case FieldSlug:
		slug := val
		if slug == "" && m.selectedDoc != nil {
			slug = toSlug(m.selectedDoc.Title)
		}
		// Full width like every other field — the [gen] hint moved to the label
		// line above so all the box right edges align.
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(dimStyle.Render(slug)), 2))
		}

	case FieldText:
		rows := field.Rows
		if rows < 2 {
			rows = 3
		}
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			content := placeholder("Enter " + field.Title + "...")
			for i := 1; i < rows; i++ {
				content += "\n"
			}
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(content), 2))
		}

	case FieldRichText:
		lines = append(lines, dimStyle.Render("  B  I  U  H1  H2  \"  ~  #"))
		content := dimStyle.Render("Start writing...")
		content += "\n"
		content += "\n"
		lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(content), 2))

	case FieldImage:
		// Value-aware, like every other field: show the stored image URL
		// (with its asset linkage when present), or a quiet hint when unset.
		// Enter edits the URL as text — there is no drop or browse in a
		// terminal, so the old static "Drop image or browse" card was a dead
		// affordance that also hid whether an image was set at all.
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			url, assetID := parseImageValue(val)
			var content string
			switch {
			case url != "":
				content = url
				if assetID != "" {
					content += "\n" + dimStyle.Render("asset "+assetID)
				}
			case assetID != "":
				content = dimStyle.Render("asset ") + assetID
			default:
				content = dimStyle.Render("No image — enter a URL")
			}
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(content), 2))
		}

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
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			dv := placeholder("YYYY-MM-DD HH:MM")
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(dv), 2))
		}

	case FieldColor:
		cv := val
		if cv == "" {
			cv = "#3b82f6"
		}
		// The bordered value box is multi-line (border top/content/bottom), so the
		// swatch must be joined as a column beside the whole box — not concatenated
		// onto line 1 only — and the composite indented uniformly.
		swatch := lipgloss.NewStyle().Background(lipgloss.Color(cv)).Render("    ")
		var box string
		if isEditing {
			box = activeFieldStyle.Render(m.textInput.View())
		} else {
			box = activeFieldStyle.Render(cv)
		}
		composite := lipgloss.JoinHorizontal(lipgloss.Center, swatch, " ", box)
		lines = append(lines, indentLines(composite, 2))

	case FieldReference:
		// The stored value is the referenced doc's BARE published id (the
		// Studio's select-ref wire format). Render the resolved TITLE with the
		// id dim beside it when the cache knows it (picker fetch / editor-open
		// resolve); fall back to the bare id, and to the dim placeholder when
		// unset. Enter opens the picker (startFieldEdit's FieldReference case).
		var rv string
		switch {
		case val == "":
			rv = dimStyle.Render("Select " + field.RefType + "...")
		case m.refTitles[val] != "":
			rv = m.refTitles[val] + " " + dimStyle.Render(val)
		default:
			rv = val
		}
		lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(rv+"  "+dimStyle.Render(">")), 2))

	case FieldArray:
		// An array WITH data shows it (clamped raw JSON) — "[ ] No items yet"
		// over a populated dependencies list was a lie.
		if raw := m.rawFieldJSON(field.Name); raw != "" {
			lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(dimStyle.Render(raw)), 2))
		} else {
			lines = append(lines, "  "+dimStyle.Render("[ ] No items yet  [+ Add]"))
		}

	case FieldRaw:
		// D12 (masterplan-20260425-085425): the Go TUI is read-only for v2 /
		// non-scalar field types — object, composite, arrayOf, codelist,
		// localizedText. Editing happens in the LiveView Studio.
		//
		// Read-only ≠ invisible: when the document CARRIES data for the field
		// — a task's claim {worker, epoch, resources}, its history — the raw
		// value renders as clamped pretty JSON, so the terminal shows the
		// same truth Studio's read-only panels do. Empty stays a placeholder.
		if raw := m.rawFieldJSON(field.Name); raw != "" {
			lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(dimStyle.Render(raw)), 2))
		} else {
			lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(dimStyle.Render("— (edit in Studio)")), 2))
		}

	default:
		lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(placeholder("...")), 2))
	}

	return lines
}

// rawFieldJSON renders a doc's raw NON-SCALAR field value (claim,
// dependencies, history, …) as pretty JSON for the read-only editor surface.
// Returns "" when there is no open doc, the field is absent/null/empty, or
// the bytes fail to parse — the caller then falls back to the placeholder.
// Clamped to a few lines so a deep history object cannot flood the form;
// the full value is one `bp task get` away.
func (m model) rawFieldJSON(name string) string {
	if m.selectedDoc == nil || m.selectedDoc.Extra == nil {
		return ""
	}
	raw, ok := m.selectedDoc.Extra[name]
	if !ok {
		return ""
	}
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" || trimmed == "{}" || trimmed == "[]" || trimmed == `""` {
		return ""
	}
	var v any
	if json.Unmarshal([]byte(trimmed), &v) != nil {
		return ""
	}
	pretty, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return ""
	}
	const maxRawJSONLines = 8
	lines := strings.Split(string(pretty), "\n")
	if len(lines) > maxRawJSONLines {
		lines = append(lines[:maxRawJSONLines], "…")
	}
	return strings.Join(lines, "\n")
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

	// Document list item → show document detail preview. The doc-content preview
	// reuses buildEditorContent, which for a long paper produces hundreds of
	// lines; unlike the editor it is NOT viewport-clipped, and .Height() only
	// pads. Clip to the box height so this preview column can never push the
	// joined frame past the terminal. (The editor proper and the M2 read-only
	// paper-scroll surface use the viewport and are untouched.)
	if pane.IsDocList && item.Doc != nil {
		schema := findSchema(pane.Node.TypeName)
		if schema == nil {
			return ""
		}
		content := clipContentToHeight(m.buildDocPreview(item.Doc, schema, width), height)
		return paneBorder.Width(width).Height(height).Render(content)
	}

	// Structure item → show what its child contains
	if item.SourceNode == nil || item.SourceNode.Child == nil {
		return ""
	}
	child := item.SourceNode.Child

	switch child.Type {
	case NodeDocumentTypeList:
		content := m.buildDocListPreview(child, width, height)
		return paneBorder.Width(width).Height(height).Render(content)
	case NodeList:
		content := m.buildListPreview(child, width, height)
		return paneBorder.Width(width).Height(height).Render(content)
	case NodeDocument:
		docs := m.ds.Query(child.TypeName, "")
		schema := findSchema(child.TypeName)
		if len(docs) > 0 && schema != nil {
			content := clipContentToHeight(m.buildDocPreview(&docs[0], schema, width), height)
			return paneBorder.Width(width).Height(height).Render(content)
		}
	}
	return ""
}

// buildDocPreview renders a document's fields, same as the editor content.
func (m model) buildDocPreview(doc *Doc, schema *Schema, width int) string {
	// Value receiver — safe to mutate the copy to reuse buildEditorContent.
	m.selectedDoc = doc
	m.editorSchema = schema
	// Decode the PREVIEW doc's own blocks into the copy so isCurrentPaper /
	// buildPaperContent see this doc, not whatever paper is selected in the
	// editor. syncSelectedPaper clears selectedPaperBlocks for non-papers, so a
	// non-paper preview falls through to the field-form path unchanged.
	m.syncSelectedPaper()
	return m.buildEditorContent(width)
}

// buildDocListPreview renders a list of documents for a type, like the doc list
// pane. THE CORE FIX: it no longer emits an unclamped header + 2-lines-per-doc
// (which fed an 83-doc, ~168-line body into a .Height(height) box that only pads
// and never truncates, overflowing the terminal). It builds the same Pane the
// focused doc-list pane uses and routes the interior through renderListInterior,
// so the body is line-accurately clipped to the box height before the border
// wraps it — the affordance row appears only when the list is actually clipped.
func (m model) buildDocListPreview(node *StructureNode, width, height int) string {
	var lines []string

	// Header (preview headers use width-2, matching the pre-change layout).
	icon := ""
	if node.Icon != "" {
		icon = node.Icon + " "
	}
	pane := m.buildDocListPane(node)
	headerText := icon + node.Title + dimStyle.Render(fmt.Sprintf(" %d", len(pane.Items)))
	lines = append(lines, headerStyle.Width(width-2).Render(headerText))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	if len(pane.Items) == 0 {
		lines = append(lines, "")
		lines = append(lines, dimStyle.Render("   No documents yet"))
		return lipgloss.JoinVertical(lipgloss.Left, lines...)
	}

	// isActive=false: the preview is never the focused pane. Cursor defaults to
	// the pane's Cursor (0 for a fresh preview), so the window starts at the top.
	interior, _, _ := m.renderListInterior(pane, width-2, m.listInteriorHeight(height), false)
	lines = append(lines, interior...)
	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// buildListPreview renders a structure list's children as a summary. Like
// buildDocListPreview, it now routes the interior through renderListInterior so
// a long structure list can never overflow the box (today these are short, so
// this is behaviourally a no-op — but it removes the unclamped-emission
// divergence between the two surfaces).
func (m model) buildListPreview(node *StructureNode, width, height int) string {
	var lines []string

	icon := ""
	if node.Icon != "" {
		icon = node.Icon + " "
	}
	lines = append(lines, headerStyle.Width(width-2).Render(icon+node.Title))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	pane := m.buildListPane(node)
	interior, _, _ := m.renderListInterior(pane, width-2, m.listInteriorHeight(height), false)
	lines = append(lines, interior...)
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

// clipContentToHeight truncates a multi-line content string to at most height
// physical lines. Used to cap the doc-content preview column (which reuses the
// unbounded editor content) so it can never push the joined frame past the
// terminal. A no-op when the content already fits.
func clipContentToHeight(content string, height int) string {
	if height < 1 {
		height = 1
	}
	lines := strings.Split(content, "\n")
	if len(lines) <= height {
		return content
	}
	return strings.Join(lines[:height], "\n")
}

func truncate(s string, max int) string {
	if max < 0 {
		max = 0
	}
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
