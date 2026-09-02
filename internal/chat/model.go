package chat

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// model.go — the Bubble Tea SHELL. It is deliberately thin: all conversation
// truth lives in the pure reducer (reduce.go), and this file only translates
// tea.Msg → Event, runs Reduce, and executes the returned Effects as commands.
// The shell owns exactly the UI concerns the reducer must NOT know about: which
// screen is showing, the composer text, the scroll viewport, and the sessions
// picker. Every seam that touches the network (Transport) or the clock (now) is
// injected, so the whole shell drives deterministically under test against a
// fake Transport and a fixed clock — no terminal, no server (charter's test
// seam discipline, mirrored from taskboard).

// tickCadence is the heartbeat: a 100ms tick drives the interrupt wedge timer
// and repaints the streaming tail (charter: 100ms tick). Unlike the taskboard's
// aliveness budget, chat ticks steadily while open — a live stream is inherently
// animated, and the wedge timer needs a reliable clock.
const tickCadence = 100 * time.Millisecond

// screen is which surface is foregrounded.
type screen int

const (
	screenPicker screen = iota // launch: list / resume / new (charter: sessions picker)
	screenChat                 // an open conversation
	screenShelf                // the ARCHIVED shelf (dismissed sessions + the way back)
)

// focusZone is which conversation zone owns the arrow keys (wave session-card
// charter D14). There was deliberately no zone concept before this — the
// composer was the only owner — so the zero value IS the composer and every
// pre-existing key path is unchanged unless the workflow strip is both visible
// and explicitly focused.
type focusZone int

const (
	focusComposer focusZone = iota // default: keys type/scroll as always
	focusWorkflow                  // the below-composer workflow strip/panel
)

// Model is the shell. State is the reduced conversation truth; everything else
// is UI the reducer is intentionally blind to.
type Model struct {
	tr     Transport
	stream *streamer
	cfg    Config

	// ctxid is the full context identity the launch screen paints (context.go):
	// which LOCAL host and repo root this process runs in, and which server,
	// workspace, project and dataset the wire client is actually pointed at.
	// Resolved ONCE in newModel — the connection is asked what it dials, and the
	// local probes run one exec between them — so the paint stays pure and the
	// answer cannot drift mid-session. The zero value renders NO band at all
	// (a bare Model literal in a unit test has resolved nothing); every path
	// that reaches a terminal goes through newModel.
	ctxid ContextIdentity

	width, height int
	screen        screen

	// picker — the herd multiplexer home (herd charter D50h/D52h). sessions is
	// the cold list-sourced roster (titles, counters, cost, workflow cards);
	// herd is the pure fleet-state overlay the ONE life-of-process stream
	// feeds. pickCursor stays the DISPLAY index over [new]+orderedSessions();
	// herd.Cursor is the session-ID truth it re-derives from after every
	// resort, so the cursor follows its session, never its row number.
	sessions    []SessionSummary
	pickCursor  int
	pickTop     int // first visible picker ROW (viewport top) — cursor-follow windowing; distinct from the transcript scroll
	pickErr     string
	loading     bool
	herd        HerdState
	fleetNotice string // the fleet stream's terminal give-up (D54h: a notice, never a crash)

	// shelf — the ARCHIVED screen (charter D28). Its own roster, cursor and
	// viewport top, deliberately NOT the picker's: the two lists hold different
	// sessions, and sharing one cursor would move the herd highlight every time
	// the shelf was browsed. There is no "+ new" row here (nothing is created on
	// a shelf), so shelfCursor indexes the archived rows DIRECTLY — index 0 is a
	// session, unlike pickCursor.
	shelf        []SessionSummary
	shelfCursor  int
	shelfTop     int
	shelfErr     string
	shelfLoading bool

	// conversation
	st         State  // the pure reducer's state
	input      string // the composer draft (charter D14 continuity — PATCHed on quit/switch)
	scroll     int    // -1 = follow mode (bottom); >=0 = pinned top line
	cardCursor int    // focus ring index into the pending answerable cards (Tab cycles)
	// optionCursor is the picked option on the focused QUESTION card, as an index
	// into that card's FLATTENED (question, option) pairs — ←/→ move it. One int
	// of state, keyed by nothing: it is re-clamped against the focused card's own
	// options every read, so a card flip, a resolve, or a refetch can never leave
	// it pointing at an option that no longer exists (ct-bl-question-updatedinput).
	optionCursor int

	// foldsExpanded opens every settled turn's fold (task-8f904a88b9bc3d59).
	// ONE bit, not a per-fold set: the terminal has no pointer to click a
	// header with, and a per-fold cursor would need a focus concept the
	// transcript deliberately does not have. ctrl+f flips it; the zero value is
	// COLLAPSED, matching Studio's default — a settled turn is history, and its
	// header already says how long it took.
	foldsExpanded bool

	// runningFoldExpanded opens the RUNNING turn's "+N previous" control
	// (task-b66928b2958c8cfa) — the rows that ran BEFORE the active one. One
	// bit, like foldsExpanded and for the same reason (no pointer, no focus
	// concept), and separate from it because the two folds answer different
	// questions: one is history, this one is the turn you are watching right
	// now. ctrl+o flips it; the zero value is COLLAPSED, which is the whole
	// point — the live row must not scroll away.
	runningFoldExpanded bool

	// anchor is what scroll >= 0 actually MEANS (charter D80): the content the
	// pinned top row was showing, as (block ordinal, intra-block line offset),
	// recorded by pinScroll at the moment of the pin and relocated against the
	// current layout on every frame (render.go viewportTop). scroll stays the
	// raw index it always was — the anchor CORRECTS it when content above the
	// pin changes height, so the reader keeps reading the same lines instead of
	// having the viewport silently swapped. Follow mode (scroll < 0) never
	// consults it and is byte-identical to the pre-anchor behaviour.
	anchor scrollAnchor

	// The below-composer workflow panel's focus model (wave session-card charter
	// D14): focus names which zone owns the arrow keys — the composer by default;
	// the workflow strip after arrow-down (only while the strip is visible).
	// wfExpanded is the Enter-opened two-pane detail; wfPhase is the selected
	// phase POSITION in the journey's Phases slice. KeyRunes always compose —
	// typing never moves panel selection (it snaps focus back to the composer).
	//
	// wfAgentDetail is the THIRD focus level (wave session-card charter D30):
	// Enter on a phase drills into the SELECTED agent's detail pane; wfAgent is
	// that agent's index within the phase (clamped to workflowDetailMaxAgents).
	// It is a bool + an index, NOT a depth int — the byte-locked s5 phase tests
	// key off wfExpanded/wfPhase verbatim, so the agent level rides additively.
	focus         focusZone
	wfExpanded    bool
	wfPhase       int
	wfAgentDetail bool
	wfAgent       int

	// D14 writable continuity set, hydrated from the full GET and PATCHed back.
	mode         string
	modelChoice  string
	effortChoice string

	// The `?` key-reference overlay (charter D66). helpOpen replaces the frame
	// with renderHelpOverlay and routes every key to handleHelpKey; helpScroll is
	// the windowed body's top row. Both reset on close, so the exact prior
	// screen/focus/scroll/panel state is restored untouched.
	helpOpen   bool
	helpScroll int

	// now is the injected clock (tests fix it; Run wires time.Now).
	now func() time.Time
}

// newModel builds a shell wired to a Transport and streamer. Screen starts on
// the picker — launch always lists sessions first (charter).
func newModel(tr Transport, stream *streamer, cfg Config) Model {
	return Model{
		tr:     tr,
		stream: stream,
		cfg:    cfg,
		// The identity is resolved from the LIVE transport (what it dials), not
		// from cfg alone — that asymmetry is what lets the surface report a
		// disagreement instead of echoing the config back at the operator.
		ctxid:   ResolveContextIdentity(cfg, connectionOf(tr), localProbe),
		screen:  screenPicker,
		scroll:  -1,
		loading: true,
		now:     time.Now,
	}
}

// ── tea.Model ────────────────────────────────────────────────────────────────

// Init fires the sessions load and starts the tick chain. It never blocks: a
// dead server just lands an error state on the picker, never a frozen prompt.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.loadSessionsCmd(), m.tickCmd())
}

// Update is the one message entry point.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(msg)
	case tea.MouseMsg:
		return m.handleMouse(msg)
	case tickMsg:
		if m.screen == screenChat {
			var cmd tea.Cmd
			m, cmd = m.apply(TickEvent{})
			return m, tea.Batch(cmd, m.tickCmd())
		}
		return m, m.tickCmd()
	case sessionsLoadedMsg:
		m.loading = false
		if msg.err != nil {
			m.pickErr = msg.err.Error()
			return m, nil
		}
		m.pickErr = ""
		m.sessions = msg.sessions
		// Cold-mount the herd from the widened list (D50h) — live flips that
		// already arrived stay authoritative (herdSeed never regresses them).
		m.herd = herdSeed(m.herd, msg.sessions)
		if m.pickCursor > len(m.sessions) {
			m.pickCursor = len(m.sessions)
		}
		m = m.syncCursorFromHerd()
		return m, nil
	case fleetFrameMsg:
		// The fleet stream is NEVER paused on attach (D54h): the herd reduces
		// every frame regardless of screen, so a detach shows current truth with
		// zero flash/refetch. m.screen gates rendering only.
		if h, ok := applyFleetFrame(m.herd, msg.event, msg.data); ok {
			m.herd = h
			m = m.syncCursorFromHerd()
		}
		return m, nil
	case fleetErrMsg:
		// Terminal stream give-up (the transport already exhausted its own
		// reconnect/backoff) degrades to a notice — never a crash, never an
		// error screen; the cold list keeps the herd usable.
		m.fleetNotice = "herd stream lost — " + msg.err.Error()
		return m, nil
	case sessionOpenedMsg:
		if msg.err != nil {
			m.pickErr = msg.err.Error()
			m.screen = screenPicker
			return m, nil
		}
		m = m.openSession(msg.session)
		// Subscribe the live stream to this session from the hydrated cursor
		// (charter D5: resume by turn boundary). The stream restarts cleanly if
		// one was already running for another session.
		m.stream.start(m.st.SessionID, m.st.LastSeq)
		return m, nil
	case streamFrameMsg:
		return m.apply(FrameEvent{Name: msg.name, Data: msg.data})
	case streamErrMsg:
		// A stream failure degrades locally to a footer notice — never an error
		// screen (the transport already retries; this is the terminal give-up).
		if m.screen == screenChat {
			m.st.Notice = "live stream lost — " + msg.err.Error()
		}
		return m, nil
	case tailFetchedMsg:
		return m.apply(TailFetchedEvent{Session: msg.session, Err: msg.err, Gen: msg.gen})
	case sendDoneMsg:
		if msg.err != nil {
			m.st.Notice = "send failed — " + msg.err.Error()
		}
		return m, nil
	case interruptDoneMsg:
		// The control ack is semantically EMPTY (charter D11) — truth is the
		// result frame. A transport-level error still surfaces honestly.
		if msg.err != nil {
			m.st.Notice = "interrupt request failed — " + msg.err.Error()
		}
		return m, nil
	case answerDoneMsg:
		// The POST landed; the reducer turns success into a full refetch (so the
		// server-resolved card flips) or an honest error notice.
		return m.apply(AnsweredEvent{RequestID: msg.requestID, Err: msg.err})
	case shelfLoadedMsg:
		m.shelfLoading = false
		if msg.err != nil {
			// Prefixed AT THE SOURCE, like the unarchive failure below: the shelf
			// paints m.shelfErr verbatim (under stale rows it is the only context
			// the line has), so every writer here owns its own wording.
			m.shelfErr = "could not read the shelf — " + msg.err.Error()
			return m, nil
		}
		m.shelfErr = ""
		m.shelf = msg.sessions
		return m.clampShelfCursor(m.shelfCursor), nil
	case unarchivedMsg:
		// The mirror image of archivedMsg. Success is NOT silent here: the row
		// left the shelf optimistically, but it has to APPEAR on the herd home,
		// and only a roster re-read can put it there honestly (no fleet frame is
		// emitted for an archive/unarchive flip). A failure surfaces honestly and
		// re-reads the SHELF, which is what puts the row back — re-inserting a
		// remembered row at a guessed position would paint a state the server
		// never confirmed.
		if msg.err != nil {
			m.shelfErr = "unarchive failed — " + msg.err.Error()
			return m, m.loadShelfCmd()
		}
		return m, m.loadSessionsCmd()
	case archivedMsg:
		// Success is silent: the row is already gone. A failure surfaces
		// honestly AND re-reads the roster, which is what puts the row back —
		// re-inserting a remembered row at a guessed position would fight the
		// attention sort and paint a stale state.
		if msg.err != nil {
			m.pickErr = "archive failed — " + msg.err.Error()
			return m, m.loadSessionsCmd()
		}
		return m, nil
	case patchedMsg:
		return m, nil
	}
	return m, nil
}

// View paints the foregrounded screen. The `?` overlay (charter D66) REPLACES
// the whole frame while open — the same body-replace cmd/barkpark's tui_view
// uses — so it reads over either screen and closing restores the exact prior
// paint (helpOpen never mutated the underlying view state).
func (m Model) View() string {
	if m.helpOpen {
		return m.renderHelpOverlay(m.width, m.height)
	}
	switch m.screen {
	case screenPicker:
		return m.renderPicker()
	case screenShelf:
		return m.renderShelf()
	}
	return m.renderChat()
}

// ── the reducer bridge ───────────────────────────────────────────────────────

// apply runs the pure reducer for one Event and turns every returned Effect into
// a command. This is the ONLY place chat state advances — the shell never
// mutates State by hand, so the acceptance-criteria invariants proven against
// Reduce hold at runtime verbatim.
func (m Model) apply(ev Event) (Model, tea.Cmd) {
	st, effects := Reduce(m.st, ev, m.now())
	m.st = st
	// Any new content while following keeps us pinned to the bottom; a manual
	// scroll (scroll>=0) is respected until the user presses End.
	var cmds []tea.Cmd
	for _, e := range effects {
		if c := m.execEffect(e); c != nil {
			cmds = append(cmds, c)
		}
	}
	return m, tea.Batch(cmds...)
}

// execEffect maps a reducer Effect to the Transport call that satisfies it,
// delivered back as a tea.Msg. IO lives here, never in Reduce.
func (m Model) execEffect(e Effect) tea.Cmd {
	id := m.st.SessionID
	tr := m.tr
	switch e := e.(type) {
	case FetchTailEffect:
		since := e.SinceSeq
		gen := e.Gen // the issuing generation (charter D77 settle-race token)
		return func() tea.Msg {
			s, err := tr.GetSession(id, since)
			return tailFetchedMsg{session: s, err: err, gen: gen}
		}
	case SendEffect:
		content := e.Content
		return func() tea.Msg { return sendDoneMsg{err: tr.SendMessage(id, content)} }
	case InterruptEffect:
		return func() tea.Msg { return interruptDoneMsg{err: tr.Interrupt(id)} }
	case AnswerEffect:
		rid, dec := e.RequestID, e.Decision
		return func() tea.Msg {
			return answerDoneMsg{requestID: rid, err: tr.Approve(id, rid, dec)}
		}
	case AnswerQuestionEffect:
		// The SAME answerDoneMsg the allow/deny path lands on — one settle grammar
		// for both answer shapes (ct-bl-question-updatedinput).
		rid, answers := e.RequestID, e.Answers
		return func() tea.Msg {
			return answerDoneMsg{requestID: rid, err: tr.AnswerQuestion(id, rid, answers)}
		}
	}
	return nil
}

// ── session lifecycle ────────────────────────────────────────────────────────

// openSession hydrates the shell from a FULL session GET (charter D14/D15): the
// message tail, the seq cursor, the title, the writable continuity set, and the
// draft restored into the composer. Screen flips to the conversation and the
// viewport re-follows.
func (m Model) openSession(s Session) Model {
	last := 0
	for _, mm := range s.Messages {
		if mm.Seq > last {
			last = mm.Seq
		}
	}
	m.st = State{
		SessionID: s.ID,
		Title:     s.Title,
		Messages:  s.Messages,
		LastSeq:   last,
		// The mode badge starts from the store row (Plan ⇄ Autopilot header);
		// init frames and turn-boundary refetches keep it honest from there.
		Mode: s.Mode,
		// The observed answering model, when the row carries one — the header
		// falls back to the intent alias until a turn reveals the fact.
		Model: s.Model,
		// Law-2: hydrate the agents rail from the resumed session's snapshot so a
		// surface switch lands on the same mission control Studio last showed.
		Rail: decodeRail(s.RailSnapshot),
		// The workflow panel decodes from the SAME snapshot (charter D13) — a
		// resumed mid-run epic cycle lands with its strip already below the composer.
		Workflow: decodeWorkflow(s.RailSnapshot),
	}
	m.input = s.Draft
	m.mode, m.modelChoice, m.effortChoice = s.Mode, s.ModelChoice, s.EffortChoice
	m.screen = screenChat
	m.scroll = -1
	m.anchor = scrollAnchor{}
	m.cardCursor = 0
	m.optionCursor = 0
	m.focus = focusComposer
	m.wfExpanded = false
	m.wfPhase = 0
	m.wfAgentDetail = false
	m.wfAgent = 0
	m.pickErr = ""
	return m
}

// answerableCards is the ordered focus ring: the pending, answerable card rows in
// seq order. The card keys (Tab/Ctrl+A/Ctrl+R) act on this slice, so what the
// paint highlights and what a keystroke answers can never disagree.
func (m Model) answerableCards() []Message {
	var out []Message
	for _, msg := range m.st.Messages {
		if answerable(msg) {
			out = append(out, msg)
		}
	}
	return out
}

// needsYou is the needs-you cockpit state (wsc-needs-you): a LIVE workflow whose
// session is ALSO blocked on a pending answerable card. It is pure truth the TUI
// already tracks — the workflow strip's own liveness (workflowStripVisible) ∩ a
// non-empty answer ring (answerableCards) — so it flips to the warn banner and
// clears the moment the card is answered (the ring empties on the refetch), with
// zero new wire. The strip, the expanded banner, and the Enter-jump all key off
// this one predicate so they can never disagree.
func (m Model) needsYou() bool {
	return m.workflowStripVisible() && len(m.answerableCards()) > 0
}

// workflowLabel is the open session's workflow label from whichever source is
// live — the compact SSE summary first (freshest), else the rail fold. "" when
// neither carries one. The needs-you strip keeps the label so the operator still
// sees WHICH run is waiting on them.
func (m Model) workflowLabel() string {
	if lw := m.st.LiveWorkflow; lw != nil {
		return lw.Label
	}
	if m.st.Workflow != nil {
		return m.st.Workflow.Label
	}
	return ""
}

// focusedCard resolves the currently focused pending card. The cursor clamps
// into range (a resolved card shrinks the ring), so it is always the oldest
// pending card when the cursor drifts past the end.
func (m Model) focusedCard() (Message, bool) {
	cards := m.answerableCards()
	if len(cards) == 0 {
		return Message{}, false
	}
	i := m.cardCursor
	if i < 0 || i >= len(cards) {
		i = 0
	}
	return cards[i], true
}

// questionChoice is ONE selectable (question, option) pair on a question card —
// the unit ←/→ walk and Ctrl+A submits.
type questionChoice struct {
	Question string
	Label    string
}

// cardChoices flattens a question card's server-held ask into the ordered choice
// list. Empty for an approval/plan card, for a row carrying no decodable ask, and
// for a legacy row with no `input` — which is exactly why the answer footer falls
// back to plain allow/deny there: an absent ask must degrade, never break the
// card's existing answer path.
func cardChoices(msg Message) []questionChoice {
	if msg.Role != "question" {
		return nil
	}
	var out []questionChoice
	for _, q := range msg.Questions() {
		for _, label := range q.Options {
			out = append(out, questionChoice{Question: q.Question, Label: label})
		}
	}
	return out
}

// focusedChoice resolves the option the operator has picked on the focused card.
// The cursor is clamped HERE rather than on every key, so what the footer paints
// and what Ctrl+A submits are read from one place and cannot disagree.
func (m Model) focusedChoice() (questionChoice, bool) {
	card, ok := m.focusedCard()
	if !ok {
		return questionChoice{}, false
	}
	choices := cardChoices(card)
	if len(choices) == 0 {
		return questionChoice{}, false
	}
	i := m.optionCursor
	if i < 0 || i >= len(choices) {
		i = 0
	}
	return choices[i], true
}

// moveOptionCursor walks the focused question card's choices by delta, wrapping.
// A no-op (and NOT a key the caller should treat as handled) when the focused
// card offers no options.
func (m Model) moveOptionCursor(delta int) (Model, bool) {
	card, ok := m.focusedCard()
	if !ok {
		return m, false
	}
	n := len(cardChoices(card))
	if n == 0 {
		return m, false
	}
	i := m.optionCursor
	if i < 0 || i >= n {
		i = 0
	}
	m.optionCursor = ((i+delta)%n + n) % n
	m = m.followScroll() // picking a chip re-follows (#14901's anchor grammar)
	return m, true
}

// leaveSession PATCHes the writable continuity set (draft/mode/model/effort)
// back to the server (charter D14) and returns to the picker, stopping the live
// stream. It returns the command that persists the draft so a quit/switch never
// loses in-flight composer text.
func (m Model) leaveSession() (Model, tea.Cmd) {
	patch := m.patchContinuityCmd()
	m.stream.stop()
	m.screen = screenPicker
	m.loading = true
	m.input = ""
	m.st = State{}
	m.focus = focusComposer
	m.wfExpanded = false
	m.wfPhase = 0
	m.wfAgentDetail = false
	m.wfAgent = 0
	return m, tea.Batch(patch, m.loadSessionsCmd())
}

// patchContinuityCmd persists the writable continuity set. Nil when there is no
// open session (nothing to persist). It is fire-and-forget — a failed PATCH is
// not worth blocking a quit over (the next resume re-GETs truth anyway).
func (m Model) patchContinuityCmd() tea.Cmd {
	if m.st.SessionID == "" {
		return nil
	}
	tr := m.tr
	id := m.st.SessionID
	fields := map[string]any{"draft": m.input}
	if m.mode != "" {
		fields["mode"] = m.mode
	}
	if m.modelChoice != "" {
		fields["model_choice"] = m.modelChoice
	}
	if m.effortChoice != "" {
		fields["effort_choice"] = m.effortChoice
	}
	return func() tea.Msg { _ = tr.PatchSession(id, fields); return patchedMsg{} }
}

// ── the herd home (charter D50h/D52h) ────────────────────────────────────────

// clock is the injected clock, nil-safe for bare Model literals in tests.
func (m Model) clock() time.Time {
	if m.now == nil {
		return time.Now()
	}
	return m.now()
}

// orderedSessions is the herd home's display order: the cold roster sorted by
// attention (blocked > stalled > working > idle — herdOrder). The picker rows,
// the cursor math, and openPickerRow ALL read this one projection, so what is
// painted, what is highlighted, and what Enter opens can never disagree.
func (m Model) orderedSessions() []SessionSummary {
	if len(m.sessions) == 0 {
		return nil
	}
	byID := make(map[string]SessionSummary, len(m.sessions))
	roster := make([]string, 0, len(m.sessions))
	for _, s := range m.sessions {
		byID[s.ID] = s
		roster = append(roster, s.ID)
	}
	out := make([]SessionSummary, 0, len(roster))
	for _, id := range herdOrder(m.herd, roster, m.clock()) {
		out = append(out, byID[id])
	}
	return out
}

// syncCursorFromHerd re-derives the display index from the session-ID cursor
// after anything that can resort the herd (a fleet frame, a list reload) — the
// D52h law: the cursor follows the SESSION, not the row number. A cursor whose
// session left the roster falls back to the clamped display index (and adopts
// whatever session now sits there).
func (m Model) syncCursorFromHerd() Model {
	order := m.orderedSessions()
	if m.herd.Cursor != "" {
		for i, s := range order {
			if s.ID == m.herd.Cursor {
				m.pickCursor = i + 1
				m.pickTop = m.followPickTop()
				return m
			}
		}
	}
	if m.pickCursor > len(order) {
		m.pickCursor = len(order)
	}
	return m.syncHerdCursorFromIndex()
}

// syncHerdCursorFromIndex records which session the display index sits on —
// called after every cursor keystroke so the NEXT resort knows which session
// to follow. Index 0 is the "+ new session" row (cursor id "").
func (m Model) syncHerdCursorFromIndex() Model {
	order := m.orderedSessions()
	if m.pickCursor <= 0 || m.pickCursor > len(order) {
		m.herd.Cursor = ""
		m.pickTop = m.followPickTop()
		return m
	}
	m.herd.Cursor = order[m.pickCursor-1].ID
	m.pickTop = m.followPickTop()
	return m
}

// toggleMode flips the session between Plan and Autopilot (ctrl+p). An odd raw
// mode (a resumed acceptEdits/manual/… row, or armed bypass) lands on plan
// first — the safe direction; the next press engages Autopilot. Optimistic:
// the badge flips now, the PATCH persists AND steers a live runtime
// server-side, and the turn-boundary refetch re-asserts truth.
func (m Model) toggleMode() (Model, tea.Cmd) {
	if m.st.SessionID == "" {
		return m, nil
	}
	current := m.st.Mode
	if current == "" {
		current = m.mode
	}
	target := "plan"
	notice := "Mode → ◇ Plan"
	if current == "plan" {
		target = "auto"
		notice = "Mode → ▶ Autopilot"
	}
	m.st.Mode = target
	// Keep the D14 continuity field in step so the leave-PATCH never reverts
	// the toggle.
	m.mode = target
	m.st.Notice = notice
	tr := m.tr
	id := m.st.SessionID
	return m, func() tea.Msg {
		_ = tr.PatchSession(id, map[string]any{"mode": target})
		return patchedMsg{}
	}
}

// ── commands + messages ──────────────────────────────────────────────────────

// tickMsg is one 100ms heartbeat.
type tickMsg struct{}

// tickCmd schedules the next heartbeat.
func (m Model) tickCmd() tea.Cmd {
	return tea.Tick(tickCadence, func(time.Time) tea.Msg { return tickMsg{} })
}

// sessionsLoadedMsg carries the picker list (or its load error).
type sessionsLoadedMsg struct {
	sessions []SessionSummary
	err      error
}

// sessionOpenedMsg carries a full session (from create or resume GET).
type sessionOpenedMsg struct {
	session Session
	err     error
}

// tailFetchedMsg carries the turn-boundary GET (?since=) result. gen is the
// generation of the FetchTailEffect that issued it (charter D77) — threaded
// verbatim into TailFetchedEvent.Gen so the settle guard can prove the fetch
// still owns the live tail.
type tailFetchedMsg struct {
	session Session
	err     error
	gen     int
}

// streamFrameMsg is one SSE frame pushed from the stream goroutine.
type streamFrameMsg struct {
	name string
	data []byte
}

// streamErrMsg is the stream goroutine's terminal give-up.
type streamErrMsg struct{ err error }

// fleetFrameMsg is one herd fleet frame (snapshot/state/heartbeat) pushed from
// the life-of-process fleet goroutine (charter D54h).
type fleetFrameMsg struct {
	event string
	data  []byte
}

// fleetErrMsg is the fleet stream's terminal give-up (degrades to a notice).
type fleetErrMsg struct{ err error }

// archivedMsg is the archive POST's completion. Success is silent — the row
// left the picker the instant the key was pressed; only a failure has anything
// to say.
type archivedMsg struct {
	id  string
	err error
}

// shelfLoadedMsg carries the ARCHIVED roster (or its load error) — a separate
// message from sessionsLoadedMsg because the two lists are separate truths: a
// shelf read must never overwrite the herd roster the fleet stream is folding
// into.
type shelfLoadedMsg struct {
	sessions []SessionSummary
	err      error
}

// unarchivedMsg is the unarchive POST's completion — the twin of archivedMsg.
type unarchivedMsg struct {
	id  string
	err error
}

// sendDoneMsg / interruptDoneMsg / patchedMsg are verb-call completions (their
// only job is to surface a transport error honestly; the truth is elsewhere).
type (
	sendDoneMsg      struct{ err error }
	interruptDoneMsg struct{ err error }
	answerDoneMsg    struct {
		requestID string
		err       error
	}
	patchedMsg struct{}
)

// loadSessionsCmd fetches the sidebar list off the update loop.
func (m Model) loadSessionsCmd() tea.Cmd {
	tr := m.tr
	return func() tea.Msg {
		ss, err := tr.ListSessions()
		return sessionsLoadedMsg{sessions: ss, err: err}
	}
}

// loadShelfCmd fetches the ARCHIVED roster off the update loop — the shelf
// screen's only read, and the caller that earns Transport.ListArchivedSessions
// its place back on the interface.
func (m Model) loadShelfCmd() tea.Cmd {
	tr := m.tr
	return func() tea.Msg {
		ss, err := tr.ListArchivedSessions()
		return shelfLoadedMsg{sessions: ss, err: err}
	}
}

// unarchiveSessionCmd puts one shelved session back on the active herd. The row
// is already gone from m.shelf by the time this runs (the optimistic removal
// happens in the key handler), exactly as archiveSessionCmd's row is: no fleet
// frame is emitted for the flip in EITHER direction, so optimism is the only
// signal that will ever arrive, and the failure branch's shelf re-read is what
// reconciles a refused flip back into view.
func (m Model) unarchiveSessionCmd(id string) tea.Cmd {
	tr := m.tr
	return func() tea.Msg {
		return unarchivedMsg{id: id, err: tr.Unarchive(id)}
	}
}

// createSessionCmd creates a new session and opens it.
func (m Model) createSessionCmd() tea.Cmd {
	tr := m.tr
	return func() tea.Msg {
		s, err := tr.CreateSession()
		return sessionOpenedMsg{session: s, err: err}
	}
}

// resumeSessionCmd re-GETs the FULL session (charter D14: the summary omits
// draft/model/effort, so resume MUST re-GET) and opens it.
func (m Model) resumeSessionCmd(id string) tea.Cmd {
	tr := m.tr
	return func() tea.Msg {
		s, err := tr.GetSession(id, 0)
		return sessionOpenedMsg{session: s, err: err}
	}
}

// archiveSessionCmd shelves one session off the update loop. The row is already
// gone from m.sessions by the time this runs (the optimistic removal happens in
// the key handler): there is no fleet frame for an archive flip, so optimism is
// the only removal signal that will ever arrive, and the refresh this batches
// with is what reconciles a failed flip back into view.
func (m Model) archiveSessionCmd(id string) tea.Cmd {
	tr := m.tr
	return func() tea.Msg {
		return archivedMsg{id: id, err: tr.Archive(id)}
	}
}
