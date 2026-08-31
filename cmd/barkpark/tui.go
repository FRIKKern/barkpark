package main

import (
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"

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
	// ReadFailed marks a doc-list pane whose query did NOT succeed — a
	// transport error, a 401/403, a 5xx, or an undecodable body. It exists
	// because Items is empty in exactly that case too, and painting the
	// "No documents yet" placeholder over a refused read tells the user the
	// type is empty when the truth is that we never got to look. Only ever
	// set from apiclient's DocReadOutcome; a decodable 200 with zero rows is
	// an honest empty and leaves this false.
	ReadFailed bool
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
	textInput   textinput.Model   // single-line text input for current field
	dirtyValues map[string]string // unsaved field changes (fieldName -> value)
	dirty       bool              // has unsaved changes
	// Multi-line editing (FieldText + legacy-string FieldRichText): a bubbles
	// textarea takes the keystream instead of textInput. While the flag is up,
	// enter inserts a newline INSIDE the textarea and ctrl+s commits the edit
	// (esc still cancels) — see the editing branch of handleKey. The parallel
	// widget keeps the n-prompt / search prompt (always single-line, riding
	// m.textInput) untouched.
	editingMultiline bool
	textArea         textarea.Model
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
	// docReadFailed marks a NodeDocument pane whose single-document query did
	// NOT succeed. It is the editor-pane twin of Pane.ReadFailed: with no rows
	// AND no successful read, selectedDoc stays nil and renderEditor would fall
	// to the "Select a document to edit" splash — the same lie the doc-list
	// pane told with "No documents yet". Reset on every rebuildPanes.
	docReadFailed bool
	// workerID is this TUI's task-claim worker identity (BARKPARK_WORKER_ID,
	// default "tui-<hostname>"), computed once in initialModel.
	workerID string
	// Transient status line — surfaces save outcomes and neutral notices.
	// status holds the message; statusErr flags a failure (red ✕), statusInfo
	// flags a neutral notice or confirm prompt (dim ·). With both false the line
	// is a success confirmation (green ✓). The two flags are mutually exclusive —
	// setStatus/setStatusInfo are the only setters and each writes both. All three
	// fields are cleared by the next key action so the line stays ephemeral.
	status     string
	statusErr  bool
	statusInfo bool
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
	// Help overlay (`?` — help.go): the full grouped key reference.
	helpOpen   bool
	helpScroll int
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
	m.docReadFailed = false

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
			// QueryResult, not Query: a refused/unreachable read also yields
			// zero docs, and leaving selectedDoc nil sends renderEditor to the
			// "select a document" splash — indistinguishable from a type that
			// genuinely holds none.
			docs, outcome := m.ds.QueryResult(child.TypeName, "")
			if len(docs) > 0 {
				m.selectedDoc = &docs[0]
			} else if outcome.Failed() {
				m.docReadFailed = true
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
	// A structure may lead with S.divider(); start the cursor on the first real
	// item so the pane never boots highlighting a non-selectable divider.
	return Pane{Node: node, Items: items, Cursor: clampToItem(items, 0, +1)}
}

func (m *model) buildDocListPane(node *StructureNode) Pane {
	docs, outcome := m.ds.QueryResult(node.TypeName, node.Filter)
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
			Meta:     rowMeta(docs[i], preview),
		})
	}
	return Pane{Node: node, Items: items, IsDocList: true, ReadFailed: outcome != apiclient.DocReadOK}
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
