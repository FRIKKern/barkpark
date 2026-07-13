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
	if msg.Type == tea.KeyCtrlC {
		if m.screen == screenChat {
			// Persist the draft, THEN quit — sequenced so the PATCH lands before
			// the program tears down.
			return m, tea.Sequence(m.patchContinuityCmd(), tea.Quit)
		}
		return m, tea.Quit
	}
	if m.screen == screenPicker {
		return m.handlePickerKey(msg)
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
		return m, nil
	case "down", "j":
		if m.pickCursor < len(m.sessions) { // rows = 1 (new) + len(sessions)
			m.pickCursor++
		}
		return m, nil
	case "g", "home":
		m.pickCursor = 0
		return m, nil
	case "G", "end":
		m.pickCursor = len(m.sessions)
		return m, nil
	case "enter":
		return m.openPickerRow()
	case "n":
		return m, m.createSessionCmd()
	case "r":
		m.loading = true
		return m, m.loadSessionsCmd()
	case "q":
		return m, tea.Quit
	}
	return m, nil
}

// openPickerRow acts on the cursor row: index 0 is the "+ new session" row, any
// other resumes that session (a FULL re-GET, charter D14).
func (m Model) openPickerRow() (tea.Model, tea.Cmd) {
	if m.pickCursor <= 0 {
		return m, m.createSessionCmd()
	}
	idx := m.pickCursor - 1
	if idx >= len(m.sessions) {
		return m, nil
	}
	return m, m.resumeSessionCmd(m.sessions[idx].ID)
}

// handleChatKey is the conversation grammar. Enter sends the composer (charter
// D12 handles the queued case in the reducer), Esc interrupts (charter D11 makes
// an idle Esc a silent no-op inside Reduce), Ctrl+B switches back to the picker
// (PATCHing the draft), and the scroll keys drive the manual viewport. Every
// other printable key edits the composer.
func (m Model) handleChatKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {
	case tea.KeyEnter:
		content := m.input
		m.input = ""
		m.scroll = -1 // a send always re-follows so you see your own line
		return m.apply(SendEvent{Content: content})
	case tea.KeyEsc:
		// Interrupt the active turn. Reduce makes an idle Esc a no-op, so the key
		// is safe to press any time.
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
			m.scroll = -1
		}
		return m, nil
	case tea.KeyCtrlB:
		return m.leaveSession()
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
		return m.scrollBy(1), nil
	case tea.KeyPgUp:
		return m.scrollBy(-m.bodyHeight() / 2), nil
	case tea.KeyPgDown:
		return m.scrollBy(m.bodyHeight() / 2), nil
	case tea.KeyHome:
		m.scroll = 0
		return m, nil
	case tea.KeyEnd:
		m.scroll = -1 // re-enter follow mode
		return m, nil
	case tea.KeyRunes:
		m.input += string(msg.Runes)
		return m, nil
	}
	return m, nil
}

// answerFocused answers the currently focused pending card with the given
// decision ("allow"/"deny"). A no-op when no card is focused (the keys are safe
// to press any time). It re-follows so the card's flip stays in view, and the
// reducer owns the POST + the pending → resolved refetch.
func (m Model) answerFocused(decision string) (tea.Model, tea.Cmd) {
	card, ok := m.focusedCard()
	if !ok {
		return m, nil
	}
	m.scroll = -1
	return m.apply(AnswerEvent{RequestID: card.RequestID(), Decision: decision})
}

// scrollBy moves the manual viewport by delta lines. Scrolling up leaves follow
// mode and pins a top line; reaching the bottom re-enters follow (scroll = -1)
// so a streaming reply resumes auto-scroll.
func (m Model) scrollBy(delta int) Model {
	maxTop := m.maxScrollTop()
	cur := m.scroll
	if cur < 0 {
		cur = maxTop // follow mode is logically pinned to the bottom
	}
	next := cur + delta
	if next < 0 {
		next = 0
	}
	if next >= maxTop {
		m.scroll = -1 // back at the bottom → follow
		return m
	}
	m.scroll = next
	return m
}

// handleMouse maps the wheel to scroll (the conversation's only mouse verb this
// wave — clicks are a later slice). A terminal without mouse reporting simply
// never reaches here.
func (m Model) handleMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
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
