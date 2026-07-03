// Package taskboard is the portrait task TUI behind `bp tasks`: a tall, narrow,
// always-glanceable live pane organized by epics, active work on top, latest
// movement first, connected to the repo you are standing in.
//
// This file is the Bubble Tea SHELL — a thin tea.Model that holds the fetched
// Board + interaction UIState and drives navigation, inline expansion, and the
// live-refresh loop (live.go). All the opinion lives elsewhere: BuildBoard
// (data-spine slice) decides the organization, Render (render slice) paints it.
// The shell only navigates a flattened list of visible rows and asks Render to
// draw the current Board+UIState. Pure, injected seams (fetch/build/now/delays)
// keep every behaviour unit-testable without a real terminal, server, or clock.
package taskboard

import (
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
)

// Config is the resolved connection + scope the board runs against. It mirrors
// the fields the CLI's resolveContext produces (internal/cli/config.go): a
// server BaseURL + Token and the workspace/project scope. The CLI maps its
// manifest.Context onto this so the board and every other `bp` command can
// never drift on "which server am I talking to".
type Config struct {
	BaseURL   string
	Token     string
	Workspace string
	Project   string
	// Dataset scopes the SSE change stream (/v1/data/listen/<dataset>). The
	// /v1/tasks reads are flat, but the live loop listens per-dataset — dropping
	// this would pin the listener to the apiclient's "production" default and
	// silently strand a `-d`/BARKPARK_DATASET-scoped board on backstop polling.
	Dataset string
}

// default live-loop timings. Fields on Model so tests can shrink them.
const (
	defaultDebounceDelay = 750 * time.Millisecond
	defaultBackstopEvery = 30 * time.Second
	// defaultLiveStale is how long a single SSE event keeps the stream trusted
	// as "live". It sits just above the backstop interval so one healthy frame
	// per poll cycle is enough to hold ConnLive; a gap longer than a backstop
	// tick with no event honestly reads as ConnPolling.
	defaultLiveStale = 35 * time.Second
)

// rowKind identifies what a flattened visible row is, which is all the cursor
// and the enter/h/l actions need to know.
type rowKind int

const (
	rowNow        rowKind = iota // a NOW-band card (an unexpired claim)
	rowEpicHeader                // an epic section header
	rowChild                     // a visible child task inside an expanded epic
	rowOrphan                    // a task with no epic, under "(no epic)"
)

// row is one navigable line. docID is the task's doc id for task rows, or the
// epic ROOT's doc id for a header row (what CollapsedEpics is keyed by).
type row struct {
	kind  rowKind
	docID string
}

// Model is the Bubble Tea shell. It is intentionally a passive holder: the
// Board is truth (rebuilt wholesale on every refetch), UIState is interaction,
// and the injected seams make it deterministic under test.
type Model struct {
	client *apiclient.Client
	token  string
	cfg    Config
	repo   RepoContext

	board Board
	ui    UIState

	width  int
	height int

	// live-loop state
	dirty         bool
	debounceGen   int
	lastLiveEvent time.Time

	// injected seams (defaults wired in newModel; tests override)
	fetch func(*apiclient.Client) (Snapshot, error)
	build func(Snapshot, RepoContext, time.Time) Board
	now   func() time.Time

	debounceDelay time.Duration
	backstopEvery time.Duration
	liveStale     time.Duration
}

// newModel constructs a Model with live seams wired to the real package funcs
// and interaction maps initialized. Conn starts at ConnPolling: after the
// initial direct fetch we HAVE data, but the SSE stream has not yet proven
// itself live — the first real mutation frame flips it to ConnLive, and a
// failed refetch flips it to ConnOffline. That is the honest starting truth.
func newModel(client *apiclient.Client, token string, cfg Config) Model {
	return Model{
		client: client,
		token:  token,
		cfg:    cfg,
		ui: UIState{
			Expanded:       map[string]bool{},
			CollapsedEpics: map[string]bool{},
			Conn:           ConnPolling,
		},
		fetch:         FetchSnapshot,
		build:         BuildBoard,
		now:           time.Now,
		debounceDelay: defaultDebounceDelay,
		backstopEvery: defaultBackstopEvery,
		liveStale:     defaultLiveStale,
	}
}

// Init starts the periodic backstop ticker. The SSE listener is started
// separately in Run (it needs the *tea.Program handle to push changeMsgs).
func (m Model) Init() tea.Cmd {
	return m.scheduleBackstop()
}

// Update is the single message reducer. Navigation and expansion mutate
// UIState in place; the live messages drive the refetch loop in live.go.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(msg)
	case changeMsg:
		return m.handleChange(msg)
	case debounceMsg:
		return m.handleDebounce(msg)
	case backstopMsg:
		return m.handleBackstop()
	case snapshotMsg:
		return m.applySnapshot(msg)
	}
	return m, nil
}

// View renders the whole portrait frame from the current Board + UIState.
func (m Model) View() string {
	return Render(m.board, m.ui, m.width, m.height, m.now())
}

// handleKey is the tiny interaction surface: navigate, expand/collapse, quit.
// No editing, no modes — the layout is the opinion (charter decision #8).
func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "j", "down":
		m.moveCursor(1)
		return m, nil
	case "k", "up":
		m.moveCursor(-1)
		return m, nil
	case "g", "home":
		m.ui.Cursor = 0
		return m, nil
	case "G", "end":
		if n := len(m.visibleRows()); n > 0 {
			m.ui.Cursor = n - 1
		}
		return m, nil
	case "enter":
		return m.activate(), nil
	case "h":
		return m.setEpicFoldUnderCursor(true), nil
	case "l":
		return m.setEpicFoldUnderCursor(false), nil
	}
	return m, nil
}

// currentRow returns the row under the cursor and whether the cursor is valid.
func (m Model) currentRow() (row, bool) {
	rows := m.visibleRows()
	if m.ui.Cursor < 0 || m.ui.Cursor >= len(rows) {
		return row{}, false
	}
	return rows[m.ui.Cursor], true
}

// activate is enter on the row under the cursor:
//
//   - on an epic header → fold/unfold the epic (flip its EFFECTIVE fold state,
//     so enter also wakes a dormant, auto-collapsed epic — an auto-fold the
//     user cannot override would be a dead end).
//   - on a task row     → open/close the inline detail (toggle Expanded).
//
// Collapsing an epic can shrink the visible-row list under the cursor, so we
// clamp afterward to keep the selection on a real row.
func (m Model) activate() Model {
	r, ok := m.currentRow()
	if !ok {
		return m
	}
	switch r.kind {
	case rowEpicHeader:
		if e, found := m.epicByRoot(r.docID); found {
			m.ui.CollapsedEpics[r.docID] = !m.epicFolded(e)
			m.clampCursor()
		}
	case rowNow, rowChild, rowOrphan:
		m.ui.Expanded[r.docID] = !m.ui.Expanded[r.docID]
	}
	return m
}

// setEpicFoldUnderCursor is h (fold) / l (unfold): deterministic, idempotent
// fold controls that act ONLY when the cursor is on an epic header — exactly
// what the help text promises ("h / l  fold / unfold"). On any task row it is
// a deliberate no-op: h/l are the tree's fold controls, not a second expand
// key. l on a dormant epic wakes it (the explicit entry overrides the
// auto-fold, see epicFolded).
func (m Model) setEpicFoldUnderCursor(folded bool) Model {
	r, ok := m.currentRow()
	if !ok || r.kind != rowEpicHeader {
		return m
	}
	m.ui.CollapsedEpics[r.docID] = folded
	m.clampCursor()
	return m
}

// epicByRoot finds the epic whose root task has the given doc id.
func (m Model) epicByRoot(rootID string) (Epic, bool) {
	for _, e := range m.board.Epics {
		if e.Root.DocID == rootID {
			return e, true
		}
	}
	return Epic{}, false
}

// epicFolded is the ONE rule for whether an epic's children are hidden: the
// user's explicit choice (a CollapsedEpics entry, whatever its value) always
// wins; absent an entry, the board's automatic policy applies (Dormant folds).
// Presence-as-override is what lets enter/l wake a dormant epic, and what
// stops a phantom collapsed=true from sticking to an epic the user tried to
// OPEN while it was dormant — when the epic later wakes, only a deliberate
// fold keeps it closed.
func (m Model) epicFolded(e Epic) bool {
	if v, ok := m.ui.CollapsedEpics[e.Root.DocID]; ok {
		return v
	}
	return e.Dormant
}

// moveCursor steps the selection by delta, clamped to the current visible-row
// list. It reads the flattened rows fresh each time because a collapse/expand
// or a refetch may have resized the list since the last keystroke.
func (m *Model) moveCursor(delta int) {
	rows := m.visibleRows()
	if len(rows) == 0 {
		m.ui.Cursor = 0
		return
	}
	c := m.ui.Cursor + delta
	if c < 0 {
		c = 0
	}
	if c > len(rows)-1 {
		c = len(rows) - 1
	}
	m.ui.Cursor = c
}

// clampCursor pins the cursor inside the current visible-row list after the
// list may have shrunk (epic collapse, board refetch).
func (m *Model) clampCursor() {
	n := len(m.visibleRows())
	if n == 0 {
		m.ui.Cursor = 0
		return
	}
	if m.ui.Cursor > n-1 {
		m.ui.Cursor = n - 1
	}
	if m.ui.Cursor < 0 {
		m.ui.Cursor = 0
	}
}

// visibleRows flattens the Board into the exact navigable order the cursor
// indexes and the renderer must paint (charter: UIState.Cursor is "the index
// into the flattened visible-row list"). The order is the frozen contract
// between this shell and the render slice:
//
//  1. every NOW card (pinned, unexpired claims)
//  2. each epic: its header, then — unless the epic is folded (epicFolded: an
//     explicit CollapsedEpics entry wins, else Dormant) — its policy-ordered
//     children (done-folded children are a render count, not rows, so they are
//     already absent from Epic.Children)
//  3. every orphan under "(no epic)"
//
// Folded rows are deliberately skipped so j/k never lands on a line that is
// not on screen. The render slice must hide children under the SAME epicFolded
// rule or the cursor highlight desyncs.
func (m Model) visibleRows() []row {
	var rows []row
	for _, t := range m.board.Now {
		rows = append(rows, row{kind: rowNow, docID: t.DocID})
	}
	for _, e := range m.board.Epics {
		rows = append(rows, row{kind: rowEpicHeader, docID: e.Root.DocID})
		if m.epicFolded(e) {
			continue
		}
		for _, c := range e.Children {
			rows = append(rows, row{kind: rowChild, docID: c.DocID})
		}
	}
	for _, t := range m.board.Orphans {
		rows = append(rows, row{kind: rowOrphan, docID: t.DocID})
	}
	return rows
}

// Run is the entry point the CLI delegates to. It builds the apiclient from the
// resolved Config, does the initial fetch + board build + first paint, wires
// the SSE live loop, and runs the alt-screen program until the user quits.
//
// The initial fetch is best-effort: a failure does NOT abort — the program
// starts in ConnOffline showing an honest empty/degraded frame, and the live
// loop's backstop keeps trying. A blank screen is never acceptable (charter
// decision #9).
func Run(cfg Config) error {
	client := apiclient.New(apiclient.Config{
		BaseURL:   cfg.BaseURL,
		Token:     cfg.Token,
		Workspace: cfg.Workspace,
		Project:   cfg.Project,
		Dataset:   cfg.Dataset,
	})

	m := newModel(client, cfg.Token, cfg)

	// First paint from a direct fetch. Repo correlation is wired in the wave-2
	// integration slice; wave 1 builds against an empty RepoContext (the board
	// degrades silently outside a git repo either way — charter decision #7).
	if snap, err := m.fetch(client); err == nil {
		m.board = m.build(snap, m.repo, m.now())
		m.ui.LastSync = snap.FetchedAt
		m.ui.Conn = ConnPolling
	} else {
		m.ui.Conn = ConnOffline
	}

	p := tea.NewProgram(m, tea.WithAltScreen())
	wireLive(p, client, cfg.Token)

	_, err := p.Run()
	return err
}
