package chat

import (
	tea "github.com/charmbracelet/bubbletea"
)

// keys.go — the keyboard + mouse grammar. Two domains keyed on the foregrounded
// screen (like the taskboard shell's handleKey): the picker navigates the
// sessions list; the conversation types, sends, interrupts, and scrolls. The
// launch keys are exactly the charter's promise — Enter send, Esc interrupt,
// Ctrl+C quit — plus Ctrl+B back-to-sessions (the switch that PATCHes the draft,
// charter D14) and manual scroll.

// handleKey dispatches a keypress by screen. Ctrl+C is the one universal quit,
// and on the conversation it PATCHes the draft first (charter D14: persist the
// writable continuity set on quit) so no composer text is ever lost.
func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// The `?` overlay owns the keyboard while open (charter D66): every key routes
	// to handleHelpKey ONLY — esc/q/? close, j/k + g/G scroll, everything else is
	// swallowed — mirroring cmd/barkpark/tui_update.go's helpOpen guard. This sits
	// ABOVE the universal Ctrl+C so an open overlay is a modal, closed before quit.
	if m.helpOpen {
		return m.handleHelpKey(msg)
	}
	if msg.Type == tea.KeyCtrlC {
		if m.screen == screenChat {
			// Persist the draft, THEN quit — sequenced so the PATCH lands before
			// the program tears down.
			return m, tea.Sequence(m.patchContinuityCmd(), tea.Quit)
		}
		return m, tea.Quit
	}
	switch m.screen {
	case screenPicker:
		return m.handlePickerKey(msg)
	case screenShelf:
		return m.handleShelfKey(msg)
	}
	return m.handleChatKey(msg)
}

// handlePickerKey navigates the launch list: up/down move, enter opens (row 0 =
// new session, else resume), n forces a new session, r refreshes, q quits.
func (m Model) handlePickerKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "up", "k":
		if m.pickCursor > 0 {
			m.pickCursor--
		}
		return m.syncHerdCursorFromIndex(), nil
	case "down", "j":
		if m.pickCursor < len(m.sessions) { // rows = 1 (new) + len(sessions)
			m.pickCursor++
		}
		return m.syncHerdCursorFromIndex(), nil
	case "g", "home":
		m.pickCursor = 0
		return m.syncHerdCursorFromIndex(), nil
	case "G", "end":
		m.pickCursor = len(m.sessions)
		return m.syncHerdCursorFromIndex(), nil
	case "pgup":
		m.pickCursor -= m.pickerPage() // page by one window (g/home stays the full jump)
		if m.pickCursor < 0 {
			m.pickCursor = 0
		}
		return m.syncHerdCursorFromIndex(), nil
	case "pgdown":
		m.pickCursor += m.pickerPage()
		if m.pickCursor > len(m.sessions) {
			m.pickCursor = len(m.sessions)
		}
		return m.syncHerdCursorFromIndex(), nil
	case "enter":
		return m.openPickerRow()
	case "n":
		return m, m.createSessionCmd()
	case "a":
		return m.archiveCursorRow()
	case "s":
		// Open the ARCHIVED shelf (charter D28) — the door `a` puts rows through,
		// read from the other side. `s` is the shelf's key on BOTH screens (it
		// closes again from there), so the toggle is one letter to learn.
		return m.openShelf()
	case "r":
		m.loading = true
		return m, m.loadSessionsCmd()
	case "?":
		// Open the key-reference overlay (charter D66). The picker has no composer,
		// so `?` is unambiguous here — always the help toggle. Pure insertion: the
		// switch has no default, so no other picker key changes.
		m.helpOpen = true
		return m, nil
	case "q":
		return m, tea.Quit
	}
	return m, nil
}

// archiveCursorRow shelves the session under the cursor (charter D28).
//
// The removal is OPTIMISTIC and immediate: the server emits no fleet frame for
// an archive flip, so nothing else will ever tell this list the row is gone.
// The cursor is clamped afterwards so the highlight cannot end up past the
// shortened roster, and the "+ new session" row (index 0) is not a session —
// pressing `a` there does nothing rather than archiving whatever happens to
// sort first.
//
// The herd row is deliberately LEFT ALONE. archived_at is dismissal; agent_state
// is attention. A dismissed session that is still working is still working, and
// scrubbing its herd state on the way out would be this screen inventing a
// liveness change the server never made.
func (m Model) archiveCursorRow() (tea.Model, tea.Cmd) {
	if m.pickCursor <= 0 {
		return m, nil
	}
	order := m.orderedSessions()
	idx := m.pickCursor - 1
	if idx >= len(order) {
		return m, nil
	}
	id := order[idx].ID

	kept := make([]SessionSummary, 0, len(m.sessions))
	for _, s := range m.sessions {
		if s.ID != id {
			kept = append(kept, s)
		}
	}
	m.sessions = kept
	if m.pickCursor > len(m.sessions) {
		m.pickCursor = len(m.sessions)
	}
	m = m.syncHerdCursorFromIndex()
	return m, m.archiveSessionCmd(id)
}

// ── the archived shelf (charter D28) ─────────────────────────────────────────
//
// The archive door used to be one-way inside the pane: `a` shelved a row and
// nothing here could see the shelf, let alone put a row back (`bp chat ls
// --archived` + `bp chat unarchive <id>` were the only ways out, and both need
// you to leave the pane). The shelf screen closes that asymmetry with the
// smallest possible grammar — a list, a cursor, and ONE verb.

// openShelf foregrounds the shelf and fires its read. The cursor resets to the
// top on every open: the shelf is re-read each time (a session archived since
// the last visit belongs at its sorted place), so a remembered index would
// point at whatever row happens to have moved under it.
func (m Model) openShelf() (tea.Model, tea.Cmd) {
	m.screen = screenShelf
	m.shelfCursor = 0
	m.shelfTop = 0
	m.shelfErr = ""
	m.shelfLoading = true
	return m, m.loadShelfCmd()
}

// handleShelfKey is the shelf grammar: up/down + g/G + paging move, enter and
// `u` BOTH restore the cursor row (enter is the row's verb, `u` is the mnemonic
// — one path, two doors), esc/`s` close back to the herd, `r` re-reads, `?`
// opens the key reference, `q` quits. There is deliberately no `a` (a shelved
// row cannot be shelved again) and no attach: attaching a session you have
// dismissed is the incoherent state — restore it first, then open it.
func (m Model) handleShelfKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "up", "k":
		return m.clampShelfCursor(m.shelfCursor - 1), nil
	case "down", "j":
		return m.clampShelfCursor(m.shelfCursor + 1), nil
	case "g", "home":
		return m.clampShelfCursor(0), nil
	case "G", "end":
		return m.clampShelfCursor(len(m.shelf) - 1), nil
	case "pgup":
		return m.clampShelfCursor(m.shelfCursor - m.shelfPage()), nil
	case "pgdown":
		return m.clampShelfCursor(m.shelfCursor + m.shelfPage()), nil
	case "enter", "u":
		return m.restoreShelfRow()
	case "esc", "s":
		// Back to the herd home. The roster is re-read on the way out so a row
		// restored during this visit is already on it (the unarchive path also
		// re-reads; a second read is cheap and keeps "esc always lands on truth"
		// unconditional).
		m.screen = screenPicker
		m.loading = true
		return m, m.loadSessionsCmd()
	case "r":
		m.shelfLoading = true
		return m, m.loadShelfCmd()
	case "?":
		m.helpOpen = true
		return m, nil
	case "q":
		return m, tea.Quit
	}
	return m, nil
}

// restoreShelfRow unarchives the session under the cursor — the shelf's ONE
// verb and the caller that earns Transport.Unarchive its place back on the
// interface.
//
// The removal is OPTIMISTIC and immediate, for the same reason the archive path
// is: the server emits no fleet frame for an archived_at flip in either
// direction, so nothing else will ever tell this list the row left. The cursor
// clamps into the shortened list afterwards, and an empty shelf is a no-op
// rather than a restore of whatever happens to sort first.
//
// The herd row is deliberately LEFT ALONE (the archiveCursorRow law, mirrored):
// archived_at is dismissal, agent_state is attention. A restored session's
// state is whatever the server says it is — the roster re-read carries it.
func (m Model) restoreShelfRow() (tea.Model, tea.Cmd) {
	if m.shelfCursor < 0 || m.shelfCursor >= len(m.shelf) {
		return m, nil
	}
	id := m.shelf[m.shelfCursor].ID

	kept := make([]SessionSummary, 0, len(m.shelf))
	for _, s := range m.shelf {
		if s.ID != id {
			kept = append(kept, s)
		}
	}
	m.shelf = kept
	m.shelfErr = ""
	m = m.clampShelfCursor(m.shelfCursor)
	return m, m.unarchiveSessionCmd(id)
}

// clampShelfCursor is the ONE place the shelf cursor's bounds live: inside the
// roster, 0 on an empty shelf (never a negative index), and the viewport top
// re-derived in the same breath so paging accumulates the way the picker's
// does.
func (m Model) clampShelfCursor(i int) Model {
	if i > len(m.shelf)-1 {
		i = len(m.shelf) - 1
	}
	if i < 0 {
		i = 0
	}
	m.shelfCursor = i
	m.shelfTop = m.followShelfTop()
	return m
}

// openPickerRow acts on the cursor row: index 0 is the "+ new session" row, any
// other resumes that session (a FULL re-GET, charter D14). The row set is the
// herd's attention-sorted order — the SAME projection the paint uses, so Enter
// always opens exactly the row under the cursor.
func (m Model) openPickerRow() (tea.Model, tea.Cmd) {
	if m.pickCursor <= 0 {
		return m, m.createSessionCmd()
	}
	order := m.orderedSessions()
	idx := m.pickCursor - 1
	if idx >= len(order) {
		return m, nil
	}
	return m, m.resumeSessionCmd(order[idx].ID)
}

// handleChatKey is the conversation grammar. Enter sends the composer (charter
// D12 handles the queued case in the reducer), Esc interrupts (charter D11 makes
// an idle Esc a silent no-op inside Reduce), Ctrl+B switches back to the picker
// (PATCHing the draft), and the scroll keys drive the manual viewport. Every
// other printable key edits the composer.
func (m Model) handleChatKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// `?` opens the key-reference overlay (charter D66) — but ONLY on an EMPTY
	// composer, so a `?` typed into a draft is text. This PURE guard sits at the
	// VERY TOP, ahead of the D14 focus snap AND the KeyRunes catch-all: placed any
	// later, the snap would collapse wfExpanded/wfAgentDetail as a side effect
	// before the intercept could fire (a verified baseline). A non-empty composer
	// falls straight through to the KeyRunes case below, which appends the rune.
	if msg.Type == tea.KeyRunes && len(msg.Runes) == 1 && msg.Runes[0] == '?' && m.input == "" {
		m.helpOpen = true
		return m, nil
	}
	// The workflow strip's focus zone (wave session-card charter D14). A strip
	// that vanished (the run settled on a turn-boundary refetch) drops focus back
	// to the composer before any key is read — no dead zone survives its panel.
	if m.focus == focusWorkflow && !m.workflowStripVisible() {
		m.focus = focusComposer
		m.wfExpanded = false
		m.wfAgentDetail = false
	}
	if m.focus == focusWorkflow {
		if nm, cmd, handled := m.handleWorkflowKey(msg); handled {
			return nm, cmd
		}
		// Any key the panel does not own falls through to the composer grammar —
		// and a TYPING key snaps focus home first, so composing always wins over
		// panel selection (the D14 KeyRunes law). Snapping home collapses BOTH
		// open levels (phase detail and agent detail) so the next Enter sends.
		switch msg.Type {
		case tea.KeyRunes, tea.KeySpace, tea.KeyBackspace:
			m.focus = focusComposer
			m.wfExpanded = false
			m.wfAgentDetail = false
		}
	}
	switch msg.Type {
	case tea.KeyEnter:
		content := m.input
		m.input = ""
		m = m.followScroll() // a send always re-follows so you see your own line
		return m.apply(SendEvent{Content: content})
	case tea.KeyEsc:
		// Contextual Esc, decided at the SHELL, never the reducer (herd charter
		// D51h, amending D11): with NO active turn Esc detaches back to the herd
		// — the exact Ctrl+B leaveSession path (draft PATCH + stream stop +
		// screen flip) with the server session left running. Mid-turn Esc still
		// interrupts, and the reducer's idle no-op stays law for any
		// InterruptEvent that reaches it by another road.
		if m.st.Phase == TurnIdle {
			return m.leaveSession()
		}
		return m.apply(InterruptEvent{})
	case tea.KeyCtrlA:
		// Allow / approve / plan-approve the focused pending card (charter D27).
		return m.answerFocused("allow")
	case tea.KeyCtrlR:
		// Deny / reject / plan-keep the focused pending card. Non-printable keys
		// so the composer stays fully typable (a/d/r are ordinary text).
		return m.answerFocused("deny")
	case tea.KeyTab:
		// Cycle the focus ring to the next pending card. A no-op with 0/1 cards.
		if n := len(m.answerableCards()); n > 0 {
			m.cardCursor = (m.cardCursor + 1) % n
			m.optionCursor = 0 // a different card offers different options
			m = m.followScroll()
		}
		return m, nil
	case tea.KeyCtrlF:
		// Expand/collapse every settled turn's fold (task-8f904a88b9bc3d59).
		// A non-printable key, like ctrl+a/ctrl+r before it, so the composer
		// stays fully typable (the D14 law).
		m.foldsExpanded = !m.foldsExpanded
		return m, nil
	case tea.KeyCtrlB:
		return m.leaveSession()
	case tea.KeyCtrlP:
		// Flip Plan ⇄ Autopilot (the header badge is the truth surface).
		return m.toggleMode()
	case tea.KeyBackspace:
		m.input = trimLastRune(m.input)
		return m, nil
	case tea.KeyCtrlU:
		m.input = ""
		return m, nil
	case tea.KeySpace:
		m.input += " "
		return m, nil
	case tea.KeyUp:
		return m.scrollBy(-1), nil
	case tea.KeyDown:
		// Arrow-down hands focus to the workflow strip — ONLY when the strip is
		// visible AND the transcript is already following the bottom (a scrolled
		// reader keeps the scroll semantics until they reach the bottom again;
		// with no strip, KeyDown is pure scroll as before — charter D14).
		if m.workflowStripVisible() && m.scroll < 0 {
			m.focus = focusWorkflow
			return m, nil
		}
		return m.scrollBy(1), nil
	case tea.KeyPgUp:
		return m.scrollBy(-m.bodyHeight() / 2), nil
	case tea.KeyPgDown:
		return m.scrollBy(m.bodyHeight() / 2), nil
	case tea.KeyHome:
		_, _, blockStarts := m.transcriptAnchored(m.width, "")
		return m.pinScroll(0, blockStarts), nil
	case tea.KeyEnd:
		return m.followScroll(), nil // re-enter follow mode
	case tea.KeyLeft, tea.KeyRight:
		// Walk the focused QUESTION card's option chips
		// (ct-bl-question-updatedinput). Deliberately arrows, not digits: the
		// composer must stay fully typable (the D14 law), and ←/→ were unbound in
		// the composer grammar. With no focused question card — or a question row
		// carrying no decodable ask — this stays the no-op it has always been.
		delta := 1
		if msg.Type == tea.KeyLeft {
			delta = -1
		}
		m, _ = m.moveOptionCursor(delta)
		return m, nil
	case tea.KeyRunes:
		m.input += string(msg.Runes)
		return m, nil
	}
	return m, nil
}

// handleWorkflowKey is the workflow panel's own grammar while it holds focus
// (wave session-card charter D14/D30/D35) — view-only navigation, no stop/pause,
// three focus levels reached Enter-THEN-arrow so each level's arrow keys own one
// axis (the s5 phase byte-lock is preserved: depth-1 Up/Down still moves wfPhase):
//
//	collapsed strip:  enter expands the two-pane phase detail · ↑/esc back to composer
//	phase detail:     ↑/↓ select a phase · enter drills into the selected agent ·
//	                  esc collapses back to the composer
//	agent detail:     ↑/↓ select an agent (clamped) · esc/left pops back to the phase
//
// handled=false lets every unowned key (typing, ctrl+b, tab, …) fall through to
// the composer grammar, so the panel never steals a key it has no verb for.
// It NEVER adds a tea.KeyRunes case — composing always wins (the D14 law).
func (m Model) handleWorkflowKey(msg tea.KeyMsg) (tea.Model, tea.Cmd, bool) {
	switch msg.Type {
	case tea.KeyEnter:
		// Needs-you jump WINS over expand (wsc-needs-you): when a live workflow is
		// blocked on a pending card, Enter on the strip/banner jumps the viewport to
		// that card so it can be answered with the existing card interaction, then
		// hands focus back to the composer. This branch sits AHEAD of the expand
		// branch — a pending gate is the more urgent verb than reading phase detail.
		if m.needsYou() {
			return m.jumpToPendingCard(), nil, true
		}
		if !m.wfExpanded {
			// D42: the collapse→expand edge fires exactly ONE turn-boundary refetch
			// (execEffect is the designated dispatch site; the response lands in the
			// idempotent reduceTailFetched) so the map the operator just opened is as
			// fresh as a turn boundary. Edge-gated by !wfExpanded — the drill and
			// collapse edges never refetch, and no polling/cadence exists (D13 holds).
			// Gen -1: this is a HYDRATION refetch, never a settle boundary — the
			// sentinel can never equal TailGen (>= 0), so its landing never clears
			// a live tail (charter D77). Carrying st.Gen here would wipe the live
			// streamed text on a mid-stream expand; the zero value would clear it
			// in the attach-mid-turn case (no init observed yet, Gen==TailGen==0).
			cmd := m.execEffect(FetchTailEffect{SinceSeq: m.st.LastSeq, Gen: -1})
			j := journeyOf(m.st.Workflow)
			if len(j.Phases) == 0 {
				// nothing to expand — an honest no-op (the refetch may hydrate the
				// rail a summary-only strip is still waiting on)
				return m, cmd, true
			}
			m.wfExpanded = true
			// land on the breathing phase (the one worth reading first), else the top
			if j.Active >= 0 {
				m.wfPhase = j.Active
			} else {
				m.wfPhase = 0
			}
			m.wfAgent = 0
			return m, cmd, true
		}
		if !m.wfAgentDetail {
			// Drill from the phase into the selected agent — landing on the
			// PROJECTION's row 0 (charter D44: the same visibleAgents list the pane
			// paints, so a folded settled agent can never be the landing target), and
			// ONLY when that agent carries a detail signal (D27/D35). A detail-less
			// row (or an agentless phase) is an honest no-op: the level never opens
			// an empty pane.
			j := journeyOf(m.st.Workflow)
			if m.wfPhase >= 0 && m.wfPhase < len(j.Phases) {
				if visible, _, _ := visibleAgents(j.Phases[m.wfPhase]); len(visible) > 0 && agentHasDetail(visible[0]) {
					m.wfAgent = 0
					m.wfAgentDetail = true
				}
			}
		}
		return m, nil, true
	case tea.KeyEsc:
		// Esc pops ONE level (D38): from the agent detail back to the phase detail,
		// then from the phase detail back to the composer. It NEVER interrupts the
		// turn from inside the panel (the composer owns that verb).
		if m.wfAgentDetail {
			m.wfAgentDetail = false
			return m, nil, true
		}
		m.wfExpanded = false
		m.focus = focusComposer
		return m, nil, true
	case tea.KeyLeft:
		// Left is the agent-detail pop twin of Esc (D35); at any shallower level it
		// is not the panel's key — fall through so the composer sees it.
		if m.wfAgentDetail {
			m.wfAgentDetail = false
			return m, nil, true
		}
		return m, nil, false
	case tea.KeyUp:
		if m.wfAgentDetail {
			if m.wfAgent > 0 {
				m.wfAgent--
			}
			return m, nil, true
		}
		if m.wfExpanded {
			if m.wfPhase > 0 {
				m.wfPhase--
				m.wfAgent = 0 // a phase change resets the agent cursor (D38)
			}
			return m, nil, true
		}
		m.focus = focusComposer // arrow-up returns from the strip
		return m, nil, true
	case tea.KeyDown:
		if m.wfAgentDetail {
			j := journeyOf(m.st.Workflow)
			if m.wfPhase >= 0 && m.wfPhase < len(j.Phases) {
				// The cursor ranges over the SAME visibleAgents projection the pane
				// paints (charter D44) — cursor == paint == detail by construction,
				// so a pinned running agent past the old cap is always reachable.
				visible, _, _ := visibleAgents(j.Phases[m.wfPhase])
				if m.wfAgent < len(visible)-1 {
					m.wfAgent++
				}
			}
			return m, nil, true
		}
		if m.wfExpanded {
			if n := len(journeyOf(m.st.Workflow).Phases); m.wfPhase < n-1 {
				m.wfPhase++
				m.wfAgent = 0 // a phase change resets the agent cursor (D38)
			}
		}
		return m, nil, true
	}
	return m, nil, false
}

// answerFocused answers the currently focused pending card with the given
// decision ("allow"/"deny"). A no-op when no card is focused (the keys are safe
// to press any time). It re-follows so the card's flip stays in view, and the
// reducer owns the POST + the pending → resolved refetch. Answering also returns
// focus to the composer and collapses the panel levels (wsc-needs-you: the same
// sane reset the needs-you Enter-jump performs) — closing the asymmetry where the
// jump reset focus but a direct answer left it stranded on the workflow zone.
func (m Model) answerFocused(decision string) (tea.Model, tea.Cmd) {
	card, ok := m.focusedCard()
	if !ok {
		return m, nil
	}
	m = m.followScroll()
	m.focus = focusComposer
	m.wfExpanded = false
	m.wfAgentDetail = false
	// An ALLOW on a question card that offers options is not a blanket allow — it
	// is the picked option, carried on the /answer route
	// (ct-bl-question-updatedinput, closing D28). A deny is unchanged on every
	// role (dismissing the questions is a real, honest verb), and a question row
	// with no decodable ask still falls through to blanket allow, so no card ever
	// loses its answer path.
	if decision == "allow" {
		if choice, ok := m.focusedChoice(); ok {
			return m.apply(QuestionAnswerEvent{
				RequestID: card.RequestID(),
				Answers:   map[string]any{choice.Question: choice.Label},
			})
		}
	}
	return m.apply(AnswerEvent{RequestID: card.RequestID(), Decision: decision})
}

// jumpToPendingCard pins the transcript viewport to the focused pending card's
// block (wsc-needs-you): it reads the block's start line from the ONE shared
// transcript accumulator (transcriptBuild — no forked walk), sets a Home-style
// pinned-top scroll clamped to [0, maxScrollTop], then hands focus back to the
// composer and collapses the panel so the next Enter sends the composer. A no-op
// when no card is focused (the caller only reaches here in the needs-you state).
func (m Model) jumpToPendingCard() Model {
	card, ok := m.focusedCard()
	if !ok {
		return m
	}
	_, start, blockStarts := m.transcriptAnchored(m.width, card.RequestID())
	if start < 0 {
		start = 0
	}
	if maxTop := m.maxScrollTop(); start > maxTop {
		start = maxTop
	}
	m = m.pinScroll(start, blockStarts)
	m.focus = focusComposer
	m.wfExpanded = false
	m.wfAgentDetail = false
	return m
}

// scrollBy moves the manual viewport by delta lines. Scrolling up leaves follow
// mode and pins a top line; reaching the bottom re-enters follow (scroll = -1)
// so a streaming reply resumes auto-scroll.
func (m Model) scrollBy(delta int) Model {
	_, _, blockStarts := m.transcriptAnchored(m.width, "")
	maxTop := m.maxScrollTop()
	// The move starts from where the reader is ACTUALLY looking this frame — the
	// anchor-relocated top, not the possibly-stale raw index (charter D80).
	cur := m.viewportTop(blockStarts, maxTop)
	if cur < 0 {
		cur = maxTop // follow mode is logically pinned to the bottom
	}
	next := cur + delta
	if next < 0 {
		next = 0
	}
	if next >= maxTop {
		return m.followScroll() // back at the bottom → follow
	}
	return m.pinScroll(next, blockStarts)
}

// pinScroll freezes the viewport at a physical top line AND records the content
// anchor for it, against the layout that line was measured in. Every pin goes
// through here: a bare `m.scroll = n` would freeze a line NUMBER, which is the
// defect (charter D80).
func (m Model) pinScroll(top int, blockStarts []int) Model {
	if top < 0 {
		top = 0
	}
	m.scroll = top
	m.anchor = anchorAt(blockStarts, top)
	return m
}

// followScroll returns to follow mode and drops the anchor: follow is a pure
// last-N slice per frame and must stay byte-identical to the pre-anchor
// behaviour, so nothing may relocate it.
func (m Model) followScroll() Model {
	m.scroll = -1
	m.anchor = scrollAnchor{}
	return m
}

// handleMouse maps the wheel to scroll (the conversation's only mouse verb this
// wave — clicks are a later slice). A terminal without mouse reporting simply
// never reaches here.
func (m Model) handleMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	// The `?` overlay owns the wheel exactly as it owns the keyboard (charter
	// D66): while open, the wheel scrolls the OVERLAY — never the transcript
	// hidden behind it (a stealth scroll the user would only discover on close).
	// Checked before the screen gate so it also works over the picker.
	if m.helpOpen {
		switch msg.Button {
		case tea.MouseButtonWheelUp:
			if m.helpScroll > 0 {
				m.helpScroll--
			}
		case tea.MouseButtonWheelDown:
			if m.helpScroll < helpMaxScroll(m.height) {
				m.helpScroll++
			}
		}
		return m, nil
	}
	if m.screen != screenChat {
		return m, nil
	}
	switch msg.Button {
	case tea.MouseButtonWheelUp:
		return m.scrollBy(-1), nil
	case tea.MouseButtonWheelDown:
		return m.scrollBy(1), nil
	}
	return m, nil
}

// trimLastRune drops the final UTF-8 rune from s (backspace on the composer).
func trimLastRune(s string) string {
	if s == "" {
		return s
	}
	for i := len(s) - 1; i >= 0; i-- {
		if isRuneStart(s[i]) {
			return s[:i]
		}
	}
	return ""
}
