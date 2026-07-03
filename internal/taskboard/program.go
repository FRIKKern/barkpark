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
	"fmt"
	"net/url"
	"strings"
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
	// defaultLiveStale is how long a single SSE frame keeps the stream trusted
	// as "live". The server emits a `: keepalive` after every 30s of quiet
	// (api listen_controller), so a healthy stream ALWAYS produces at least one
	// pulse per 35s window and holds ConnLive even over an idle dataset; a gap
	// longer than that means the stream is really gone and the dot honestly
	// degrades to ConnPolling at the next snapshot.
	defaultLiveStale = 35 * time.Second
)

// rowKind identifies what a flattened visible row is, which is all the cursor
// and the enter/h/l actions need to know.
type rowKind int

const (
	rowNow           rowKind = iota // a NOW-band card (an unexpired claim)
	rowEpicHeader                   // an epic section header
	rowChild                        // a visible child task inside an expanded epic
	rowClusterHeader                // a derived-cluster section header
	rowClusterMember                // a task inside an unfolded cluster section
	rowOrphan                       // a task with no epic, under "(no epic)"
)

// row is one navigable line. docID is the task's doc id for task rows; for an
// epic header it is the epic ROOT's doc id, and for a cluster header it is the
// cluster's fold key ("cluster:"+Key) — both are exactly what CollapsedEpics is
// keyed by, so a header row folds by writing CollapsedEpics[row.docID] directly.
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

	// Repo correlation inputs, gathered ONCE by Run's gatherGit(".") and held so
	// applySnapshot can recompute m.repo against every fresh task set (pure +
	// cheap — keeps the "↳ git" badges and epic-rank boost current as the board
	// breathes). All zero outside a git repo, where the board degrades silently.
	repoName string
	branch   string
	subjects []string

	// live-loop state
	dirty         bool
	debounceGen   int
	lastLiveEvent time.Time

	// pendingClose arms the double-press close guard: the first x records the
	// task's doc id here and the strip prompts; a second consecutive x on the
	// SAME row fires the close; ANY other key clears it (handleKey).
	pendingClose string

	// injected seams (defaults wired in newModel; tests override)
	fetch   func(*apiclient.Client) (Snapshot, error)
	build   func(Snapshot, RepoContext, time.Time) Board
	doClaim func(*apiclient.Client, string, string) ActionResult
	doClose func(*apiclient.Client, string, string, int) ActionResult
	now     func() time.Time

	debounceDelay time.Duration
	backstopEvery time.Duration
	liveStale     time.Duration
}

// newModel constructs a Model with live seams wired to the real package funcs
// and interaction maps initialized. Conn starts at ConnPolling: after the
// initial direct fetch we HAVE data, but the SSE stream has not yet proven
// itself live — the first stream frame (normally the server's welcome event,
// moments after connect) pulses it to ConnLive, and a failed refetch flips it
// to ConnOffline. That is the honest starting truth.
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
		doClaim:       DoClaim,
		doClose:       DoClose,
		now:           time.Now,
		debounceDelay: defaultDebounceDelay,
		backstopEvery: defaultBackstopEvery,
		liveStale:     defaultLiveStale,
	}
}

// Init starts the periodic backstop ticker AND fires the initial fetch as a
// command (amendment E). Run must never block on the first fetch — a dead
// server would freeze the prompt for seconds — so frame one paints immediately
// in the honest "syncing…" state and the fetched board swaps in when it lands.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.scheduleBackstop(), m.refetchCmd(false))
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
	case pulseMsg:
		return m.handlePulse()
	case debounceMsg:
		return m.handleDebounce(msg)
	case backstopMsg:
		return m.handleBackstop()
	case snapshotMsg:
		return m.applySnapshot(msg)
	case actionResultMsg:
		return m.handleActionResult(msg)
	}
	return m, nil
}

// View renders the whole portrait frame from the current Board + UIState.
func (m Model) View() string {
	return Render(m.board, m.ui, m.width, m.height, m.now())
}

// handleKey is the tiny interaction surface: navigate, expand/collapse, act
// (claim/close/studio), quit. No editing, no modes — the layout is the opinion
// (charter decision #8).
//
// Two cross-cutting rules run before the switch: every keypress clears the
// action strip (it is transient — "cleared on the next keypress"), and every
// key EXCEPT a repeated x disarms the close guard (a second consecutive x is
// the only thing that confirms a close; anything else cancels it).
func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()
	if key != "x" {
		m.pendingClose = ""
	}
	m.ui.Strip = ActionStrip{}

	switch key {
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
	case "c":
		return m.claimUnderCursor()
	case "x":
		return m.closeUnderCursor()
	case "o":
		return m.openUnderCursor()
	}
	return m, nil
}

// ── Act verbs: claim / close / open-in-Studio ────────────────────────────────
//
// The verbs are tiny and SAFE (charter decision 8): claim only a ready row,
// close only a live claim (behind a double-press guard), open a read-only deep
// link. Every outcome speaks through the action strip — an ok confirmation, an
// honest refusal rendered verbatim from the server, or the reason a row is not
// actionable. On success the row optimistically re-fetches so the pane
// reconciles against server truth on the very next frame; nothing is applied
// locally by hand (no ghost rows). The doClaim/doClose seams are injected so
// the reducers are unit-testable without a server.

// claimUnderCursor is 'c': claim the task under the cursor. A claim only makes
// sense on a READY row (the engine returns not_ready otherwise), so a non-ready
// row explains why instead of firing a doomed request. The claim itself runs as
// a command so the reducer never blocks on the network.
func (m Model) claimUnderCursor() (Model, tea.Cmd) {
	t, ok := m.taskUnderCursor()
	if !ok {
		m.setStrip("no task under the cursor to claim", RoleWarn)
		return m, nil
	}
	if t.Lifecycle != lifeReady {
		m.setStrip(claimBlockedReason(t), RoleWarn)
		return m, nil
	}
	return m, m.claimCmd(t.DocID, ResolveWorker())
}

// closeUnderCursor is 'x': the double-press close guard. Only a task holding a
// LIVE claim can be closed, and only after two consecutive x presses on the
// same row — the first arms (recording the doc id + prompting), the second
// fires with the epoch OBSERVED on the row (the CAS token). handleKey has
// already disarmed pendingClose for any non-x key, so reaching here with
// pendingClose == this row means a genuine second consecutive x.
func (m Model) closeUnderCursor() (Model, tea.Cmd) {
	t, ok := m.taskUnderCursor()
	if !ok || !hasLiveClaim(t) {
		m.pendingClose = ""
		m.setStrip("nothing to close here — x closes a task with a live claim", RoleWarn)
		return m, nil
	}
	if m.pendingClose == t.DocID {
		m.pendingClose = ""
		return m, m.closeCmd(t.DocID, ResolveWorker(), t.Claim.Epoch)
	}
	m.pendingClose = t.DocID
	m.setStrip(fmt.Sprintf("press x again to close '%s'", t.Title), RoleWarn)
	return m, nil
}

// openUnderCursor is 'o': open the task in Studio. The deep link is ALWAYS
// surfaced on the strip (SSH-friendly — you can copy it even with no browser),
// and best-effort launched via the injectable openURL seam. A launch failure is
// not an error: the URL is the deliverable, so the strip keeps showing it.
func (m Model) openUnderCursor() (Model, tea.Cmd) {
	t, ok := m.taskUnderCursor()
	if !ok {
		m.setStrip("no task under the cursor to open", RoleWarn)
		return m, nil
	}
	url := StudioTaskURL(m.cfg.BaseURL, t.DocID)
	if url == "" {
		m.setStrip("can't build a Studio link (no server or doc id)", RoleWarn)
		return m, nil
	}
	if err := openURL(url); err != nil {
		m.setStrip("open "+url, RoleWarn)
		return m, nil
	}
	m.setStrip("opening "+url, RoleOK)
	return m, nil
}

// handleActionResult renders a completed claim/close outcome on the strip: an
// ok confirmation in green, or the server's honest refusal in danger. On
// success it triggers an immediate refetch so the optimistic flip reconciles
// against server truth (the row moves into/out of the NOW band on the next
// frame); that refetch carries keepStrip so the confirmation stays readable
// through its own reconcile instead of flashing for one network round-trip.
// Either way the message persists until the next keypress (or a later,
// unrelated snapshot).
func (m Model) handleActionResult(msg actionResultMsg) (Model, tea.Cmd) {
	// The result strip replaces whatever was showing — including an arm-prompt
	// the user managed to set while this request was in flight. The prompt is
	// the close guard's only visible face, so disarm with it (armed iff shown).
	m.pendingClose = ""
	if msg.res.OK {
		m.setStrip(msg.res.Message, RoleOK)
		return m, m.refetchCmd(true)
	}
	m.setStrip(msg.res.Message, RoleDanger)
	return m, nil
}

// claimCmd / closeCmd run the (injected) action off the update loop and deliver
// the outcome as an actionResultMsg. The seam + client are captured by value so
// the command is self-contained.
func (m Model) claimCmd(docID, worker string) tea.Cmd {
	do, client := m.doClaim, m.client
	return func() tea.Msg { return actionResultMsg{res: do(client, docID, worker)} }
}

func (m Model) closeCmd(docID, worker string, epoch int) tea.Cmd {
	do, client := m.doClose, m.client
	return func() tea.Msg { return actionResultMsg{res: do(client, docID, worker, epoch)} }
}

// setStrip records the one-line action status the renderer paints above the
// footer. Empty message + RoleNeutral clears it.
func (m *Model) setStrip(message string, role Role) {
	m.ui.Strip = ActionStrip{Message: message, Role: role}
}

// taskUnderCursor resolves the row under the cursor to its full Task (the row
// carries only a doc id). Epic headers resolve to their root task, so acting on
// a header is legal but a non-ready/unclaimed root is explained, not fired.
func (m Model) taskUnderCursor() (Task, bool) {
	r, ok := m.currentRow()
	if !ok {
		return Task{}, false
	}
	return m.taskByID(r.docID)
}

// taskByID finds a task anywhere on the board (NOW band, epic roots, epic
// children, orphans) by doc id.
func (m Model) taskByID(id string) (Task, bool) {
	for _, t := range m.board.Now {
		if t.DocID == id {
			return t, true
		}
	}
	for _, e := range m.board.Epics {
		if e.Root.DocID == id {
			return e.Root, true
		}
		for _, c := range e.Children {
			if c.DocID == id {
				return c, true
			}
		}
	}
	// Cluster members are actionable exactly like epic children — c/x/o must
	// find them, so taskByID searches the derived clusters too.
	for _, cl := range m.board.Clusters {
		for _, mem := range cl.Tasks {
			if mem.DocID == id {
				return mem, true
			}
		}
	}
	for _, t := range m.board.Orphans {
		if t.DocID == id {
			return t, true
		}
	}
	return Task{}, false
}

// hasLiveClaim reports whether a task currently holds a claim (a present claim
// with a non-empty worker — a swept lease clears the worker). Only such a task
// can be closed.
func hasLiveClaim(t Task) bool {
	return t.Claim != nil && t.Claim.Worker != ""
}

// claimBlockedReason explains, in plain words, why a non-ready row cannot be
// claimed — so 'c' on the wrong row teaches instead of failing silently.
func claimBlockedReason(t Task) string {
	switch t.Lifecycle {
	case lifeInProgress:
		return "already in progress — press x to close it instead"
	case lifeBlocked:
		return "blocked by unmet dependencies — not ready to claim"
	case lifeDone, lifeClosed, lifeCancelled:
		return "already finished — nothing to claim"
	default: // open / unknown: not in the engine's ready queue yet
		return "not ready yet — only ready tasks can be claimed"
	}
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
	case rowClusterHeader:
		// A cluster has no Dormant auto-fold, so its effective state IS the map
		// value (default false); toggling the raw entry under its fold key is the
		// whole rule (foldedCluster reads the same entry).
		m.ui.CollapsedEpics[r.docID] = !m.ui.CollapsedEpics[r.docID]
		m.clampCursor()
	case rowNow, rowChild, rowClusterMember, rowOrphan:
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
	// h/l fold BOTH kinds of section header — epics and derived clusters. A
	// header row's docID is already the CollapsedEpics key (epic root id, or the
	// cluster's "cluster:"+Key fold key), so the write is identical for both.
	if !ok || (r.kind != rowEpicHeader && r.kind != rowClusterHeader) {
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

// epicFolded delegates to foldedEpic — the shell and the renderer MUST share
// the one fold rule or the cursor desyncs from the painted rows.
func (m Model) epicFolded(e Epic) bool {
	return foldedEpic(m.ui, e)
}

// foldedEpic is the ONE rule for whether an epic's children are hidden: the
// user's explicit choice (a CollapsedEpics entry, whatever its value) always
// wins; absent an entry, the board's automatic policy applies (Dormant folds).
// Presence-as-override is what lets enter/l wake a dormant epic, and what
// stops a phantom collapsed=true from sticking to an epic the user tried to
// OPEN while it was dormant — when the epic later wakes, only a deliberate
// fold keeps it closed. Package-level (not a Model method) because the
// renderer's flattenSpine applies the SAME rule to the same UIState.
func foldedEpic(st UIState, e Epic) bool {
	if v, ok := st.CollapsedEpics[e.Root.DocID]; ok {
		return v
	}
	return e.Dormant
}

// clusterFoldKey namespaces a cluster's fold state inside the shared
// CollapsedEpics map so a cluster key can never collide with an epic root id.
func clusterFoldKey(key string) string { return "cluster:" + key }

// foldedCluster is the ONE rule for whether a derived cluster's members are
// hidden. Unlike an epic there is NO automatic (Dormant) fold — a cluster is
// inferred from tags, not authored, so it collapses only on the user's explicit
// choice, recorded under its namespaced fold key. Package-level (not a Model
// method) because the renderer's flattenSpine applies the SAME rule to the same
// UIState; any divergence desyncs the cursor from the painted rows.
func foldedCluster(st UIState, c Cluster) bool {
	return st.CollapsedEpics[clusterFoldKey(c.Key)]
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
//  3. each derived cluster: its header, then — unless folded (foldedCluster:
//     an explicit "cluster:"+Key entry, no Dormant auto-fold) — its members
//  4. every orphan under "(no epic)"
//
// Folded rows are deliberately skipped so j/k never lands on a line that is
// not on screen. The render slice must hide children under the SAME epicFolded
// / foldedCluster rules or the cursor highlight desyncs.
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
	for _, cl := range m.board.Clusters {
		rows = append(rows, row{kind: rowClusterHeader, docID: clusterFoldKey(cl.Key)})
		if foldedCluster(m.ui, cl) {
			continue
		}
		for _, mem := range cl.Tasks {
			rows = append(rows, row{kind: rowClusterMember, docID: mem.DocID})
		}
	}
	for _, t := range m.board.Orphans {
		rows = append(rows, row{kind: rowOrphan, docID: t.DocID})
	}
	return rows
}

// Run is the entry point the CLI delegates to. It builds the apiclient from the
// resolved Config, gathers this repo's identity + git context ONCE, injects the
// header chrome, wires the SSE live loop, and runs the alt-screen program until
// the user quits.
//
// The initial fetch is NOT done here (amendment E): Init fires it as a command
// so a dead server can never freeze the prompt. Frame one paints immediately in
// the honest "syncing…" state; the fetched board swaps in when it lands, and a
// failed fetch degrades to ConnOffline. A blank screen is never acceptable
// (charter decision #9).
func Run(cfg Config) error {
	client := apiclient.New(apiclient.Config{
		BaseURL:   cfg.BaseURL,
		Token:     cfg.Token,
		Workspace: cfg.Workspace,
		Project:   cfg.Project,
		Dataset:   cfg.Dataset,
	})

	m := newModel(client, cfg.Token, cfg)

	// Repo correlation is 100% local and advisory-only (charter decision 7).
	// gatherGit runs ONCE for the repo name, current branch, and recent commit
	// subjects; applySnapshot recomputes m.repo against every fresh task set so
	// the "↳ git" badges stay current. GatherRepoContext alone would hand back an
	// empty Mentioned map by design — the subjects are what CorrelateRepo needs.
	// Outside a git repo every value is zero and the board degrades silently.
	repoName, branch, subjects, _ := gatherGit(".")
	m.repoName, m.branch, m.subjects = repoName, branch, subjects

	// Header chrome: repo (⎇ branch) ⇄ server, injected once before the program
	// starts. The tea render loop is single-goroutine, so setting this package
	// var here (before tea.NewProgram) is race-clean.
	Chrome = ChromeInfo{
		RepoName: dashOrValue(repoName),
		Branch:   branch,
		Server:   serverHost(cfg.BaseURL),
	}

	p := tea.NewProgram(m, tea.WithAltScreen())
	wireLive(p, client, cfg.Token)

	_, err := p.Run()
	return err
}

// serverHost reduces a base URL to the host[:port] the header shows ("guerrilla
// .barkpark.cloud", "localhost:4000"). It tolerates a scheme-less base and
// falls back to a dash when there is nothing to show.
func serverHost(baseURL string) string {
	s := strings.TrimSpace(baseURL)
	if s == "" {
		return "—"
	}
	if u, err := url.Parse(s); err == nil && u.Host != "" {
		return u.Host
	}
	// Scheme-less (or unparseable): drop any leading "//" and trailing path.
	s = strings.TrimPrefix(s, "//")
	if i := strings.IndexByte(s, '/'); i >= 0 {
		s = s[:i]
	}
	return dashOrValue(s)
}

// dashOrValue returns s, or the header's em-dash placeholder when s is empty —
// the pane shows a dash rather than a blank where it has nothing honest to say.
func dashOrValue(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
