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
	// CacheDir is the directory the first-paint snapshot cache lives in — the
	// bp config dir (${XDG_CONFIG_HOME:-~/.config}/barkpark), resolved by the CLI
	// (internal/cli configDir) and passed in so cache.go stays pure and testable
	// against a t.TempDir(). Empty disables the cache entirely (LoadCachedSnapshot
	// / SaveCachedSnapshot both no-op on ""), so a board with no resolvable config
	// dir degrades to a plain cold start rather than erroring.
	CacheDir string
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
	// frameCadence is the heartbeat tick interval (charter decision 16): one
	// frame per second WHILE the board is Alive(). It is a fixed cadence, not a
	// tunable — the tests drive determinism through the injected clock + an
	// explicit Frame, never real wall-clock timing, so there is nothing to shrink.
	frameCadence = 1 * time.Second
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
	rowOrphanHeader                 // the loose "(no epic)" bucket's navigable header
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

	// stack is the navigation stack (charter D11/D29). stack[0] is ALWAYS the
	// board frame (FrameBoard, "tasks"); enter descends (push), esc/backspace
	// ascends (pop, no-op at root). Board interaction (cursor/fold) lives in
	// m.ui; each pushed reading frame carries its own Cursor/Scroll on the Frame.
	stack []Frame
	// details is the TaskDetail reading index (charter D28), and tasks is the
	// merged task set — both refreshed on every applied snapshot. FrameTask reads
	// its detail out of details[Ref] (zero fetch); ChildrenOf/DrivenTasks walk
	// tasks. papers caches the async-fetched FramePaper state by slug (papers DO
	// fetch on push, charter D12/D13e).
	details DetailIndex
	tasks   []Task
	papers  map[string]PaperState

	width  int
	height int
	// wide is the adaptive-compositor mode (charter D12/D27): two-pane at
	// width>=110, full-frame push below, with a ±4 hysteresis deadband [106,110)
	// so a tmux resize never flaps. Updated ONLY on tea.WindowSizeMsg; Compose
	// reads it and the pure frame renderers never see the mode.
	wide bool

	// Repo correlation inputs, gathered ONCE by Run's gatherGit(".") and held so
	// applySnapshot can recompute m.repo against every fresh task set (pure +
	// cheap — keeps the "↳ git" badges and epic-rank boost current as the board
	// breathes). All zero outside a git repo, where the board degrades silently.
	repoName string
	branch   string
	subjects []string

	// first-paint cache identity, resolved once in newModel: cacheDir is the bp
	// config dir (Config.CacheDir, "" disables), cacheKey the scope's stable
	// filename component. applySnapshot writes through these on every applied
	// snapshot; newModel reads through them once to prime the very first frame.
	cacheDir string
	cacheKey string

	// live-loop state
	dirty         bool
	debounceGen   int
	lastLiveEvent time.Time
	// lastAppliedFetch is the FetchedAt of the newest snapshot applySnapshot
	// ACCEPTED this session — the out-of-order guard's baseline. It is distinct
	// from ui.LastSync (the display stamp) on purpose: primeFromCache seeds
	// LastSync from the CACHED FetchedAt for the honest age banner but leaves
	// this zero, so a cache stamped by a clock that has since jumped BACKWARDS
	// (NTP step, VM resume) can never out-rank live fetches and freeze the board
	// on stale rows. The guard orders in-flight fetches within THIS session
	// only; a stamp read from disk never participates.
	lastAppliedFetch time.Time

	// heartbeat state (anim.go / the frameMsg tick). frameOn is whether a tick
	// chain is currently scheduled — the double-schedule guard so applySnapshot
	// and action results can both re-arm without stacking tickers. frameGen tags
	// the live chain (the debounceGen pattern): a straggler tick from a stopped or
	// superseded chain carries an old gen and is dropped instead of advancing a
	// dead animation. prevTasks is the last APPLIED snapshot's task set, held so
	// applySnapshot can diff it (changedDocIDs) and stamp the flash ladder.
	frameOn   bool
	frameGen  int
	prevTasks []Task

	// pendingClose arms the double-press close guard: the first x records the
	// task's doc id here and the strip prompts; a second consecutive x on the
	// SAME row fires the close; ANY other key clears it (handleKey).
	pendingClose string

	// injected seams (defaults wired in newModel; tests override). fetch is the
	// full-hydration seam (charter D28): FetchSnapshotFull returns the board
	// Snapshot AND the TaskDetail DetailIndex in one round-trip.
	fetch   func(*apiclient.Client) (Snapshot, DetailIndex, error)
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
	m := Model{
		client: client,
		token:  token,
		cfg:    cfg,
		ui: UIState{
			CollapsedEpics: map[string]bool{},
			Flashes:        map[string]time.Time{},
			Conn:           ConnPolling,
		},
		// The board is ALWAYS stack level 0 (charter D11/D29) — enter descends onto
		// it, esc no-ops at this root. papers caches async FramePaper fetches by slug.
		stack:         []Frame{{Kind: FrameBoard, Title: "tasks"}},
		papers:        map[string]PaperState{},
		cacheDir:      cfg.CacheDir,
		cacheKey:      cacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project),
		fetch:         FetchSnapshotFull,
		build:         BuildBoard,
		doClaim:       DoClaim,
		doClose:       DoClose,
		now:           time.Now,
		debounceDelay: defaultDebounceDelay,
		backstopEvery: defaultBackstopEvery,
		liveStale:     defaultLiveStale,
	}
	// Paint from a best-effort cached snapshot BEFORE the first fetch lands, so
	// frame one is never blank (charter decision #9). A miss (no cache, empty
	// CacheDir, corrupt file) is a silent no-op — the board stays at its honest
	// zero value and paints the cold "syncing…" state instead.
	m.primeFromCache()
	return m
}

// primeFromCache paints the board from the last saved snapshot for this scope,
// if one exists, so `bp tasks` shows real rows the instant it opens instead of a
// blank screen (charter decision #9). It is deliberately honest about staleness:
//
//   - Conn is LEFT at ConnPolling (newModel's default) — never ConnLive. The
//     cached rows are shown through the same degraded/polling render path as an
//     offline board; the header reads "◐ polling · 3m", never "● live".
//   - LastSync is stamped from the CACHED FetchedAt, so the last-synced age the
//     header shows is the truth about the cached data, not the moment we painted
//     it. (This also lifts the frame out of isSyncing — we DO have data — so the
//     header says "polling · 3m", while a no-cache cold start still says
//     "syncing…".) The async first fetch swaps live truth in moments later.
//   - lastAppliedFetch is NOT seeded: the cached FetchedAt is a stamp from a
//     PREVIOUS session's clock, so it must never participate in the intra-session
//     out-of-order guard — if the wall clock jumped backwards between sessions,
//     a seeded baseline would drop every live snapshot (including each 30s
//     backstop, stamped from the same skewed clock) and freeze the board on
//     stale rows indefinitely. Live truth always beats the file.
//
// FLASH CONTRACT (charter decision #20): priming MUST NOT seed a change-highlight
// baseline. A cache load is not a "snapshot applied" — it does NOT run through
// applySnapshot and records no prev-task set. When the pulse/decay slice lands
// its diff baseline (a prevTasks-style field on Model), the FIRST live snapshot
// after a cache-primed start must still be treated as a first snapshot (empty
// prev-state); otherwise every task would false-flash against the stale cache.
// Do not populate any such field here.
func (m *Model) primeFromCache() {
	snap, ok := LoadCachedSnapshot(m.cacheDir, m.cacheKey)
	if !ok {
		return
	}
	// Repo correlation is recomputed against live tasks on the first real
	// snapshot; the cache paint uses an empty RepoContext (a no-op badge/boost)
	// rather than blocking first paint on git — the badges appear a beat later.
	m.board = m.build(snap, RepoContext{}, m.now())
	m.ui.LastSync = snap.FetchedAt
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
		// Adaptive-compositor hysteresis (charter D12/D27): two-pane at width>=110,
		// full-frame push below 106; the deadband [106,110) holds the previous mode
		// so a tmux drag across the boundary never flaps.
		if msg.Width >= wideEnter {
			m.wide = true
		} else if msg.Width < wideExit {
			m.wide = false
		}
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
	case frameMsg:
		return m.handleFrame(msg)
	case snapshotMsg:
		return m.applySnapshot(msg)
	case paperLoadedMsg:
		return m.handlePaperLoaded(msg)
	case actionResultMsg:
		return m.handleActionResult(msg)
	}
	return m, nil
}

// View composites the whole frame through the adaptive compositor (charter
// D26): Compose picks two-pane vs full-frame push and paints the navigation
// stack from the pure frame renderers.
func (m Model) View() string {
	return Compose(m)
}

// ── Heartbeat: the deterministic animation seam (charter decision 16) ─────────
//
// Aliveness is a BUDGET. A frameMsg tea.Tick advances UIState.Frame once a
// second, but ONLY while Alive(board, ui, now) — an unexpired NOW claim, a still
// -decaying flash, or the syncing first paint. At rest the chain stops dead: the
// program receives zero ticks and paints zero frames, so at-rest goldens stay
// byte-stable by construction and motion states golden deterministically from a
// fixed clock + an explicit Frame. This file owns the DRIVING (the tick loop);
// anim.go owns the pure predicates it consults; the renderer (later slices)
// consumes Frame/Flashes. Nothing here paints.

// frameMsg is one heartbeat tick. It carries the generation it was scheduled
// under so a straggler tick from a chain that has since been stopped or
// re-armed (a stale gen) is dropped instead of advancing a dead animation —
// the same generation-tag guard the debounce loop uses.
type frameMsg struct{ gen int }

// scheduleFrame arms the NEXT heartbeat tick, tagged with the current frame
// generation. It is the only thing that advances UIState.Frame and it is armed
// ONLY from an Alive board (maybeStartHeartbeat / a live handleFrame), so a
// board at rest never schedules a tick.
func (m Model) scheduleFrame(gen int) tea.Cmd {
	return tea.Tick(frameCadence, func(time.Time) tea.Msg { return frameMsg{gen: gen} })
}

// maybeStartHeartbeat arms the tick chain IFF the board is alive and no chain is
// already running. It is the shared re-arm helper the re-arm points call
// (applySnapshot, action results): the frameOn guard makes a second call a
// no-op, so two arms leave exactly one live generation and the tick phase never
// thrashes under a burst of snapshots. Returns nil when there is nothing to
// animate (at rest) or a chain is already live — Init and an at-rest snapshot
// therefore schedule no frame at all.
func (m *Model) maybeStartHeartbeat() tea.Cmd {
	if m.frameOn {
		return nil
	}
	if !Alive(m.board, m.ui, m.now()) {
		return nil
	}
	m.frameOn = true
	m.frameGen++
	return m.scheduleFrame(m.frameGen)
}

// stopHeartbeat halts the tick chain and returns the board to a DETERMINISTIC
// rest: Frame back to 0 (so a re-armed board always starts a fresh animation at
// frame 0, and at-rest goldens are byte-identical) and frameGen bumped so any
// tick still in flight from the just-stopped chain is orphaned (its gen no
// longer matches) rather than reviving a dead animation.
func (m *Model) stopHeartbeat() {
	m.frameOn = false
	m.frameGen++
	m.ui.Frame = 0
}

// handleFrame advances the animation one frame, prunes faded flashes, and
// reschedules ONLY while the board is still Alive — otherwise the ticker stops
// dead (the aliveness budget: zero repaints at rest). A tick whose generation no
// longer matches the live chain is a straggler from a stopped/superseded chain
// and is dropped without effect.
func (m Model) handleFrame(msg frameMsg) (Model, tea.Cmd) {
	if msg.gen != m.frameGen {
		return m, nil
	}
	m.ui.Frame++
	pruneFlashes(m.ui.Flashes, m.now())
	if Alive(m.board, m.ui, m.now()) {
		return m, m.scheduleFrame(m.frameGen)
	}
	m.stopHeartbeat()
	return m, nil
}

// handleKey is the navigation-shell dispatcher (charter D29): two navigation
// domains, one entry point keyed on the stack-top frame kind. The BOARD frame
// (level 0) keeps its native grammar unchanged; a pushed reading frame
// (FrameTask/FramePaper) navigates its []Stop. `esc`/`backspace` always ascend
// (pop, no-op at root) and `q`/ctrl+c always quit, whatever the frame.
//
// Two cross-cutting rules run first: every keypress clears the action strip (it
// is transient — "cleared on the next keypress"), and every key EXCEPT a
// repeated x disarms the close guard (a second consecutive x is the only thing
// that confirms a close; anything else cancels it).
func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()
	if key != "x" {
		m.pendingClose = ""
	}
	m.ui.Strip = ActionStrip{}

	switch key {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "esc", "backspace":
		(&m).popFrame()
		return m, nil
	}

	if m.topFrame().Kind == FrameBoard {
		return m.handleBoardKey(key)
	}
	return m.handleReadingKey(key)
}

// handleBoardKey is the board's native grammar (charter D29): visibleRows +
// UIState.Cursor, h/l epic/cluster fold, g/G/jk, c/x/o act, and — the one shell
// change — enter on a task row PUSHES a FrameTask (enter on a section header
// still folds), replacing the deleted inline-expand toggle (charter D11/D31).
func (m Model) handleBoardKey(key string) (tea.Model, tea.Cmd) {
	switch key {
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
		return m.activateBoard(), nil
	case "h":
		return m.setEpicFoldUnderCursor(true), nil
	case "l":
		return m.setEpicFoldUnderCursor(false), nil
	case "c":
		t, ok := m.taskUnderCursor()
		if !ok {
			m.setStrip("no task under the cursor to claim", RoleWarn)
			return m, nil
		}
		return m.claimTask(t)
	case "x":
		t, ok := m.taskUnderCursor()
		if !ok {
			m.pendingClose = ""
			m.setStrip("nothing to close here — x closes a task with a live claim", RoleWarn)
			return m, nil
		}
		return m.closeTask(t)
	case "o":
		t, ok := m.taskUnderCursor()
		if !ok {
			m.setStrip("no task under the cursor to open", RoleWarn)
			return m, nil
		}
		return m.openTask(t)
	}
	return m, nil
}

// handleReadingKey is the pushed-frame grammar (charter D18/D29): j/k move
// Frame.Cursor between stops (viewport follows), space/u/d free-scroll prose,
// enter descends on the cursor stop, and the act verbs follow the reader (D30) —
// FrameTask targets its own subject task, FramePaper acts on the cursor stop iff
// it is a task. esc/backspace already popped in handleKey.
func (m Model) handleReadingKey(key string) (tea.Model, tea.Cmd) {
	switch key {
	case "j", "down":
		(&m).moveStopCursor(1)
		return m, nil
	case "k", "up":
		(&m).moveStopCursor(-1)
		return m, nil
	case "g", "home":
		(&m).setTopCursor(0)
		return m, nil
	case "G", "end":
		(&m).setTopCursor(m.frameStopCount() - 1)
		return m, nil
	case " ", "space":
		(&m).freeScroll(m.readingViewportHeight() - 1)
		return m, nil
	case "d", "pgdown":
		(&m).freeScroll(m.readingViewportHeight() / 2)
		return m, nil
	case "u", "pgup":
		(&m).freeScroll(-m.readingViewportHeight() / 2)
		return m, nil
	case "enter":
		return m.descend()
	case "c":
		t, ok := m.readingSubjectTask()
		if !ok {
			m.setStrip("nothing to act on here", RoleWarn)
			return m, nil
		}
		return m.claimTask(t)
	case "x":
		t, ok := m.readingSubjectTask()
		if !ok {
			m.setStrip("nothing to act on here", RoleWarn)
			return m, nil
		}
		return m.closeTask(t)
	case "o":
		t, ok := m.readingSubjectTask()
		if !ok {
			m.setStrip("nothing to act on here", RoleWarn)
			return m, nil
		}
		return m.openTask(t)
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

// claimTask is 'c': claim a task. A claim only makes sense on a READY row (the
// engine returns not_ready otherwise), so a non-ready row explains why instead
// of firing a doomed request. The claim itself runs as a command so the reducer
// never blocks on the network. The board resolves the task under the cursor; a
// reading frame resolves its own subject (charter D30) — both funnel here.
func (m Model) claimTask(t Task) (Model, tea.Cmd) {
	if t.Lifecycle != lifeReady {
		m.setStrip(claimBlockedReason(t), RoleWarn)
		return m, nil
	}
	return m, m.claimCmd(t.DocID, ResolveWorker())
}

// closeTask is 'x': the double-press close guard. Only a task holding a LIVE
// claim can be closed, and only after two consecutive x presses on the same row
// — the first arms (recording the doc id + prompting), the second fires with the
// epoch OBSERVED on the row (the CAS token). handleKey has already disarmed
// pendingClose for any non-x key, so reaching here with pendingClose == this row
// means a genuine second consecutive x.
func (m Model) closeTask(t Task) (Model, tea.Cmd) {
	if !hasLiveClaim(t) {
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

// openTask is 'o': open the task in Studio. The deep link is ALWAYS surfaced on
// the strip (SSH-friendly — you can copy it even with no browser), and
// best-effort launched via the injectable openURL seam. A launch failure is not
// an error: the URL is the deliverable, so the strip keeps showing it.
func (m Model) openTask(t Task) (Model, tea.Cmd) {
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
		// A landed claim/close is green by default, but a result carrying a
		// rail-awareness notice overrides the role (warn for a blocker that landed
		// on the task you just claimed, info for a rail move) so the heads-up reads
		// at a glance. RoleNeutral (the zero value) means "no override".
		role := RoleOK
		if msg.res.Role != RoleNeutral {
			role = msg.res.Role
		}
		m.setStrip(msg.res.Message, role)
		// Re-arm the heartbeat here too (guarded): the reconciling refetch will
		// re-arm from applySnapshot when the new board lands, but arming now keeps
		// the pane alive through the round-trip if a flash or claim already makes
		// it Alive — the maybeStartHeartbeat guard makes a redundant arm a no-op.
		// Hoisted to its own statement: maybeStartHeartbeat mutates m through its
		// pointer receiver, and reading m as a return operand in the same return
		// statement would leave copy-vs-call order unspecified (Go spec orders
		// only the calls).
		hb := m.maybeStartHeartbeat()
		return m, tea.Batch(m.refetchCmd(true), hb)
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
// children, cluster members, orphans) by doc id.
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

// activateBoard is enter on the row under the cursor (charter D11/D29):
//
//   - on an epic / cluster / orphan header → fold/unfold the section (flip its
//     EFFECTIVE fold state, so enter opens a folded-by-default section and folds
//     an auto-opened active one — an auto-fold the user cannot override would be
//     a dead end).
//   - on a task row (NOW card, READY-TO-CLAIM head, child, member, orphan) →
//     PUSH a FrameTask (the navigation-shell descent that replaced the retired
//     inline-expand toggle). The detail reads out of the in-hand DetailIndex —
//     no fetch (charter D28).
//
// Collapsing a section can shrink the visible-row list under the cursor, so we
// clamp afterward to keep the selection on a real row.
func (m Model) activateBoard() Model {
	r, ok := m.currentRow()
	if !ok {
		return m
	}
	switch r.kind {
	case rowEpicHeader:
		// enter toggles the focus/header default against full-expand: if the epic
		// already shows ALL its children (modeExpanded), collapse it to just the
		// header; else expand it to the full list. Writing (mode == modeExpanded)
		// keeps enter a true toggle from any state (focus / header / full /
		// collapsed) — charter D51/D54.
		if e, found := m.epicByRoot(r.docID); found {
			m.ui.CollapsedEpics[r.docID] = sectionExpandedMode(epicMode(m.ui, e))
			m.clampCursor()
		}
	case rowClusterHeader:
		if cl, found := m.clusterByFoldKey(r.docID); found {
			m.ui.CollapsedEpics[r.docID] = sectionExpandedMode(clusterMode(m.ui, cl))
			m.clampCursor()
		}
	case rowOrphanHeader:
		m.ui.CollapsedEpics[r.docID] = sectionExpandedMode(orphansMode(m.ui, m.board))
		m.clampCursor()
	case rowNow, rowChild, rowClusterMember, rowOrphan:
		title := r.docID
		if t, found := m.taskByID(r.docID); found && t.Title != "" {
			title = t.Title
		}
		(&m).pushFrame(Frame{Kind: FrameTask, Ref: r.docID, Title: title})
	}
	return m
}

// setEpicFoldUnderCursor is h (fold) / l (unfold): deterministic, idempotent
// fold controls that act ONLY when the cursor is on a SECTION header — exactly
// what the help text promises ("h / l  fold / unfold"). On any task row it is
// a deliberate no-op: h/l are the tree's fold controls, not a second expand
// key. l writes an explicit expand (entry=false → all children); h writes an
// explicit collapse (entry=true → header only). Both override the focus/header
// default (see sectionModeFor, charter D54).
func (m Model) setEpicFoldUnderCursor(folded bool) Model {
	r, ok := m.currentRow()
	// h/l fold ALL three section-header kinds — epics, derived clusters and the
	// loose "(no epic)" bucket. A header row's docID is already the CollapsedEpics
	// key (epic root id, the cluster's "cluster:"+Key, or orphansFoldKey), so the
	// write is identical for all three.
	if !ok || (r.kind != rowEpicHeader && r.kind != rowClusterHeader && r.kind != rowOrphanHeader) {
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

// clusterByFoldKey finds the derived cluster whose namespaced fold key matches —
// the cluster-header analog of epicByRoot, so enter can flip the cluster's
// EFFECTIVE fold state (which now depends on Cluster.Active, wave-7 D32).
func (m Model) clusterByFoldKey(key string) (Cluster, bool) {
	for _, cl := range m.board.Clusters {
		if clusterFoldKey(cl.Key) == key {
			return cl, true
		}
	}
	return Cluster{}, false
}

// sectionMode is how a section renders (charter D51 / wave-11): the ONE rule the
// shell (visibleRows) and the renderer (flattenSpine) both resolve through
// spineRows, so the cursor never desyncs. It replaces wave-8's head-of-5 count.
type sectionMode int

const (
	modeCollapsed sectionMode = iota // explicit h → header only
	modeExpanded                     // explicit l/enter → ALL kept children
	modeFocus                        // active neighborhood → the FocusSet rows
	modeHeader                       // inactive → header + rollup only
)

// sectionModeFor resolves a section's mode: an explicit CollapsedEpics entry ALWAYS
// wins (charter D54 — h collapses even an active section, l expands even a dead
// one); otherwise a non-empty focus set → modeFocus (show the neighborhood), an
// empty one → modeHeader (just the big-picture rollup line). Active/inactive is no
// longer a direct input — it flows through the focus set (an active section has
// blocked children or NOW anchors, so computeFocus returns a non-empty set).
func sectionModeFor(st UIState, key string, focus map[string]bool) sectionMode {
	if v, ok := st.CollapsedEpics[key]; ok {
		if v {
			return modeCollapsed
		}
		return modeExpanded
	}
	if len(focus) > 0 {
		return modeFocus
	}
	return modeHeader
}

// sectionExpandedMode reports whether a mode shows ALL kept children — the toggle
// predicate enter flips against (writing it back means "collapse iff currently
// fully expanded", so enter opens a focused/header/collapsed section and folds a
// fully-expanded one).
func sectionExpandedMode(mode sectionMode) bool { return mode == modeExpanded }

func epicMode(st UIState, e Epic) sectionMode {
	return sectionModeFor(st, e.Root.DocID, e.FocusSet)
}
func clusterMode(st UIState, c Cluster) sectionMode {
	return sectionModeFor(st, clusterFoldKey(c.Key), c.FocusSet)
}
func orphansMode(st UIState, b Board) sectionMode {
	return sectionModeFor(st, orphansFoldKey, b.OrphansFocusSet)
}

// clusterFoldKey namespaces a cluster's fold state inside the shared
// CollapsedEpics map so a cluster key can never collide with an epic root id.
func clusterFoldKey(key string) string { return "cluster:" + key }

// orphansFoldKey is the loose "(no epic)" bucket's fold state key in the shared
// CollapsedEpics map — a fixed sentinel that can never collide with an epic root
// id or a cluster key (wave-7 decision 33).
const orphansFoldKey = "orphans:(no epic)"

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
//  1. the pinned NOW cards (unexpired claims — the READY TO CLAIM head is retired,
//     charter D52 / wave-11)
//  2. each epic: its header, then — per epicMode (charter D51) — its focus
//     neighborhood (modeFocus), all children (modeExpanded), or nothing
//     (modeHeader/modeCollapsed); an explicit CollapsedEpics entry wins (D54)
//  3. each derived cluster: its header, then its members per clusterMode
//  4. the loose "(no epic)" header, then its orphan rows per orphansMode
//
// Both this and the renderer's flattenSpine read the SAME spineRows producer, so
// the focus filter lives inside spineRows and cursor-parity stays structural.
func (m Model) visibleRows() []row {
	var rows []row
	// The pinned NOW cards are the FIRST selectable stops (charter D14). The
	// wave-7 READY TO CLAIM head is retired (charter D52 / wave-11 — ONE list):
	// claim-forward stays via the cursor landing on any ready row in the spine.
	for _, t := range m.board.Now {
		rows = append(rows, row{kind: rowNow, docID: t.DocID})
	}
	// The scrolling spine is the SELECTABLE subset of the ONE ordered producer
	// (spineRows, charter D42) — the SAME list flattenSpine renders. Headers,
	// nested children, cluster members and orphans consume an index in emission
	// order; separators, "+K more" folds and phase sub-bands are Selectable:false
	// and skipped here, so j/k never lands on a line that is not a cursor stop.
	// Because both paths read this one producer, the cursor can no longer desync.
	for _, sr := range spineRows(m.board, m.ui) {
		if sr.Selectable {
			rows = append(rows, row{kind: sr.RK, docID: sr.Ref})
		}
	}
	return rows
}

// ── Navigation stack (charter D11/D18/D29) ───────────────────────────────────

// paperLoadedMsg delivers a FetchPaper result back to the update loop — papers
// (unlike task detail) DO fetch on push (charter D12/D13e), off the loop so a
// keystroke never blocks on the network.
type paperLoadedMsg struct{ ps PaperState }

// handlePaperLoaded stores the fetched/failed paper state by slug. The frame
// re-renders from it on the next paint (honest loading/err/HTML-only states all
// ride PaperState — never a blank frame, never a crash).
func (m Model) handlePaperLoaded(msg paperLoadedMsg) (Model, tea.Cmd) {
	if m.papers == nil {
		m.papers = map[string]PaperState{}
	}
	m.papers[msg.ps.Slug] = msg.ps
	return m, nil
}

// topFrame returns the stack-top frame — the one the key grammar dispatches on
// and the compositor foregrounds. The stack is never empty (newModel seeds the
// board at level 0); a zero value is returned defensively if it ever is.
func (m Model) topFrame() Frame {
	if len(m.stack) == 0 {
		return Frame{Kind: FrameBoard, Title: "tasks"}
	}
	return m.stack[len(m.stack)-1]
}

// pushFrame descends onto a new frame with the D11 cycle guard: pushing a
// (Kind,Ref) already on the stack POPS BACK to that existing frame instead of
// duplicating it (a task→paper→same-task loop lands on the first copy, its saved
// cursor intact). A genuinely new frame is appended fresh; the covered frames
// keep their saved Cursor/Scroll for restore on pop. A paper push also fires its
// async fetch (returned as the cmd); a task push reads the in-hand index.
func (m *Model) pushFrame(f Frame) tea.Cmd {
	for i, ex := range m.stack {
		if ex.Kind == f.Kind && ex.Ref == f.Ref {
			m.stack = m.stack[:i+1]
			return nil
		}
	}
	m.stack = append(m.stack, f)
	if f.Kind == FramePaper {
		return m.ensurePaper(f.Ref)
	}
	return nil
}

// popFrame ascends one level (esc/backspace). A no-op at the root board frame —
// the covered frame's saved Cursor/Scroll is simply revealed again.
func (m *Model) popFrame() {
	if len(m.stack) > 1 {
		m.stack = m.stack[:len(m.stack)-1]
	}
}

// descend is enter inside a pushed frame: push the frame the cursor stop points
// at (a child task's FrameTask, a paper's FramePaper). A frame with no stops, or
// a cursor off the end, is a no-op.
func (m Model) descend() (tea.Model, tea.Cmd) {
	top := m.topFrame()
	_, stops := m.frameContent(top, m.readingWidth(), m.now())
	if top.Cursor < 0 || top.Cursor >= len(stops) {
		return m, nil
	}
	s := stops[top.Cursor]
	cmd := (&m).pushFrame(Frame{Kind: s.Kind, Ref: s.Ref, Title: s.Label})
	return m, cmd
}

// ensurePaper primes a FramePaper's fetch: a cache hit (already rendered-ready)
// is reused; otherwise it marks the state Loading and returns the fetch cmd.
func (m *Model) ensurePaper(slug string) tea.Cmd {
	if m.papers == nil {
		m.papers = map[string]PaperState{}
	}
	if ps, ok := m.papers[slug]; ok && (ps.HTMLOnly || len(ps.BlocksRaw) > 0) {
		return nil
	}
	m.papers[slug] = PaperState{Slug: slug, Loading: true}
	return m.fetchPaperCmd(slug)
}

// fetchPaperCmd runs FetchPaper off the update loop (charter D13e: one direct
// scoped read). A nil client (unconfigured / test) yields an honest Err state,
// never a panic.
func (m Model) fetchPaperCmd(slug string) tea.Cmd {
	client, dataset := m.client, m.paperDataset()
	return func() tea.Msg {
		if client == nil {
			return paperLoadedMsg{ps: PaperState{Slug: slug, Err: "no server configured"}}
		}
		ps, _ := FetchPaper(client, dataset, slug)
		ps.Slug = slug
		return paperLoadedMsg{ps: ps}
	}
}

// paperDataset resolves the dataset a paper is fetched from — the scoped dataset
// when set, else the "production" default the paper route assumes.
func (m Model) paperDataset() string {
	if m.cfg.Dataset != "" {
		return m.cfg.Dataset
	}
	return "production"
}

// frameContent renders a pushed frame's body + stops at the given width (charter
// D18: the reader returns body lines the shell windows, plus the selectable
// stops j/k walks). FrameTask reads its detail out of the in-hand DetailIndex
// (zero fetch, D28), FramePaper out of the async papers cache; a not-yet-loaded
// or unknown ref degrades to one honest dim line, never a blank/crash.
func (m Model) frameContent(f Frame, width int, now time.Time) ([]string, []Stop) {
	switch f.Kind {
	case FrameTask:
		d, ok := m.details[f.Ref]
		if !ok {
			t, found := m.taskByID(f.Ref)
			if !found {
				return []string{dimStyle.Render(truncate("task not loaded — esc to go back", width))}, nil
			}
			d = TaskDetail{Task: t} // thin best-effort from the board row
		}
		return RenderTaskDetail(d, ChildrenOf(m.tasks, f.Ref), f.Cursor, width, now)
	case FramePaper:
		ps, ok := m.papers[f.Ref]
		if !ok {
			ps = PaperState{Slug: f.Ref, Loading: true}
		}
		return RenderPaperFrame(ps, DrivenTasks(m.tasks, m.details, f.Ref), m.tasks, f.Cursor, width, now)
	default:
		return nil, nil
	}
}

// frameStopCount is the number of selectable stops in the top frame (the j/k
// clamp bound), measured at the reading width so it matches what Compose paints.
func (m Model) frameStopCount() int {
	_, stops := m.frameContent(m.topFrame(), m.readingWidth(), m.now())
	return len(stops)
}

// moveStopCursor steps the top frame's stop cursor by delta and puts the frame
// into cursor-follow (Scroll=scrollFollow), clamped to the stop list.
func (m *Model) moveStopCursor(delta int) {
	n := m.frameStopCount()
	if n <= 0 || len(m.stack) == 0 {
		return
	}
	top := &m.stack[len(m.stack)-1]
	c := top.Cursor + delta
	if c < 0 {
		c = 0
	}
	if c > n-1 {
		c = n - 1
	}
	top.Cursor = c
	top.Scroll = scrollFollow
}

// setTopCursor jumps the top frame's stop cursor (g/G) into cursor-follow,
// clamped to the stop list. With no stops it falls back to the absolute top
// (Scroll=0) so g on a stop-less frame still scrolls to the beginning.
func (m *Model) setTopCursor(c int) {
	if len(m.stack) == 0 {
		return
	}
	top := &m.stack[len(m.stack)-1]
	n := m.frameStopCount()
	if n <= 0 {
		top.Cursor, top.Scroll = 0, 0
		return
	}
	if c < 0 {
		c = 0
	}
	if c > n-1 {
		c = n - 1
	}
	top.Cursor, top.Scroll = c, scrollFollow
}

// freeScroll pans the reading viewport by delta lines WITHOUT moving the cursor
// (charter D18: space/u/d read prose; the next j/k snaps back). Entering from
// cursor-follow it seeds the offset from the current follow top so the first
// press moves smoothly from where the eye is.
func (m *Model) freeScroll(delta int) {
	if len(m.stack) == 0 {
		return
	}
	top := &m.stack[len(m.stack)-1]
	body, stops := m.frameContent(*top, m.readingWidth(), m.now())
	avail := m.readingViewportHeight()
	if avail < 1 {
		avail = 1
	}
	maxTop := len(body) - avail
	if maxTop < 0 {
		maxTop = 0
	}
	cur := top.Scroll
	if cur < 0 { // in cursor-follow — seed from the current follow top so the
		// first press moves smoothly from where the eye is, then Scroll becomes
		// an absolute offset (>=0) the subsequent presses pan directly.
		cur = followTop(len(body), stops, top.Cursor, avail)
	}
	nt := cur + delta
	if nt < 0 {
		nt = 0
	}
	if nt > maxTop {
		nt = maxTop
	}
	top.Scroll = nt
}

// readingWidth is the width a pushed frame renders at: full width in narrow
// push mode, the right-pane width in wide two-pane mode (charter D24: the
// renderers cap the reading measure at 72 internally, so extra width is margin).
func (m Model) readingWidth() int {
	w := m.width
	if w < 20 {
		w = 20
	}
	if m.wide {
		w = w - boardPaneWidth - paneGutter2
		if w < minReadingWidth {
			w = minReadingWidth
		}
	}
	return w
}

// readingViewportHeight is the number of body lines a pushed frame gets — it MUST
// match Compose's layout math (narrow: breadcrumb + footer reserved; wide: the
// breadcrumb spans the top) or the free-scroll clamp desyncs from the paint.
func (m Model) readingViewportHeight() int {
	h := m.height
	if h < 8 {
		h = 8
	}
	if m.wide {
		return h - 1
	}
	return h - 2
}

// readingSubjectTask resolves the task the act verbs (c/x/o) target in a pushed
// frame (charter D30): a FrameTask acts on its own subject; a FramePaper acts on
// the cursor stop iff it is a task, else nothing.
func (m Model) readingSubjectTask() (Task, bool) {
	top := m.topFrame()
	switch top.Kind {
	case FrameTask:
		if d, ok := m.details[top.Ref]; ok {
			return d.Task, true
		}
		return m.taskByID(top.Ref)
	case FramePaper:
		_, stops := m.frameContent(top, m.readingWidth(), m.now())
		if top.Cursor >= 0 && top.Cursor < len(stops) && stops[top.Cursor].Kind == FrameTask {
			ref := stops[top.Cursor].Ref
			if d, ok := m.details[ref]; ok {
				return d.Task, true
			}
			return m.taskByID(ref)
		}
	}
	return Task{}, false
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
