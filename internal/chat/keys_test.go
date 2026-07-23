package chat

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// keys_test.go — the FIRST test file over the chat key grammar (charter D66).
// It pins the `?` help overlay: the open/close seams from both surfaces, the
// verified snap-safe intercept baselines, the overlay's own scroll/window
// behaviour, and the two byte-identity contracts (the closed chatFooter and the
// folded picker hint line, charter D71). The overlay skeleton mirrors
// cmd/barkpark/help.go; these tests mirror cmd/barkpark/help_test.go's five.

// ── open / close seams ───────────────────────────────────────────────────────

// TestHelpOpensAndClosesFromPicker: `?` on the picker opens the overlay through
// the full handleKey dispatch; esc closes it and leaves the picker state (screen,
// cursor) exactly as it was — the overlay mutates nothing but its own two fields.
func TestHelpOpensAndClosesFromPicker(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m.width, m.height = 80, 24
	m.pickCursor = 2
	m.sessions = []SessionSummary{{ID: "a"}, {ID: "b"}, {ID: "c"}}

	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	nm := next.(Model)
	if !nm.helpOpen {
		t.Fatal("? on the picker must open the help overlay")
	}

	after, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	am := after.(Model)
	if am.helpOpen {
		t.Error("esc must close the overlay")
	}
	if am.screen != screenPicker || am.pickCursor != 2 {
		t.Errorf("closing must restore the prior view untouched, got screen=%v cursor=%d", am.screen, am.pickCursor)
	}
}

// TestHelpQuestionCloses: q and ? also close the overlay (esc/q/? all dismiss).
func TestHelpQuestionCloses(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyRunes, Runes: []rune{'q'}},
		{Type: tea.KeyRunes, Runes: []rune{'?'}},
		{Type: tea.KeyEsc},
	} {
		m := Model{helpOpen: true, helpScroll: 3, height: 24}
		next, _ := m.handleKey(key)
		if next.(Model).helpOpen {
			t.Errorf("%v must close the overlay", key)
		}
		if next.(Model).helpScroll != 0 {
			t.Errorf("%v must reset helpScroll, got %d", key, next.(Model).helpScroll)
		}
	}
}

// TestHelpOpensFromChatOnEmptyComposer: in the conversation `?` opens help ONLY
// when the composer is empty. A `?` typed into a draft is text — it appends and
// never opens the overlay.
func TestHelpOpensFromChatOnEmptyComposer(t *testing.T) {
	// empty composer → opens
	m := wfTestModel(t, State{SessionID: "s1"})
	next, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	nm := next.(Model)
	if !nm.helpOpen {
		t.Fatal("? on an empty composer must open help")
	}
	if nm.input != "" {
		t.Errorf("opening help must not touch the composer, got %q", nm.input)
	}

	// non-empty composer → appends, never opens
	m2 := wfTestModel(t, State{SessionID: "s1"})
	m2.input = "how"
	next2, _ := m2.handleChatKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	nm2 := next2.(Model)
	if nm2.helpOpen {
		t.Fatal("? into a non-empty composer must NOT open help")
	}
	if nm2.input != "how?" {
		t.Errorf("? into a draft must append, got %q", nm2.input)
	}
}

// TestHelpFromWorkflowFocusDoesNotSnap is the load-bearing seam baseline (charter
// D66/D70): with the workflow panel focused AND expanded, an empty-composer `?`
// opens help WITHOUT firing the D14 focus snap — wfExpanded and wfAgentDetail
// survive. Placed any later than the very top of handleChatKey, the snap would
// collapse both levels as a side effect before the intercept could fire.
func TestHelpFromWorkflowFocusDoesNotSnap(t *testing.T) {
	m := wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfAgentDetail = true

	next, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	nm := next.(Model)
	if !nm.helpOpen {
		t.Fatal("empty-composer ? must open help even under workflow focus")
	}
	if !nm.wfExpanded || !nm.wfAgentDetail {
		t.Errorf("opening help must NOT fire the D14 snap: wfExpanded=%v wfAgentDetail=%v", nm.wfExpanded, nm.wfAgentDetail)
	}
	if nm.focus != focusWorkflow {
		t.Errorf("opening help must leave panel focus intact, got %v", nm.focus)
	}
}

// TestHelpDispatchRoutesEveryKey: while helpOpen every key routes to handleHelpKey
// ONLY. A printable key never reaches the composer, and j scrolls the overlay —
// proof the dispatch guard sits ahead of the whole grammar.
func TestHelpDispatchRoutesEveryKey(t *testing.T) {
	m := Model{helpOpen: true, screen: screenChat, height: 24}

	// A stray printable key is swallowed, never appended to the composer.
	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	nm := next.(Model)
	if !nm.helpOpen || nm.input != "" {
		t.Errorf("a printable key while help is open must be swallowed, got open=%v input=%q", nm.helpOpen, nm.input)
	}

	// j scrolls the overlay (content overflows at height 24).
	if helpMaxScroll(24) == 0 {
		t.Fatal("test setup: overlay must overflow at height 24")
	}
	scrolled, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if scrolled.(Model).helpScroll != 1 {
		t.Errorf("j must scroll the overlay via handleHelpKey, got %d", scrolled.(Model).helpScroll)
	}
}

// ── content census ───────────────────────────────────────────────────────────

// TestHelpCoversLoadBearingVerbs is the drift guard: one intent string per verb
// family the one-line footer can never fit. Every load-bearing key in the chat
// grammar has a documented row (charter D66 CENSUS).
func TestHelpCoversLoadBearingVerbs(t *testing.T) {
	m := Model{helpOpen: true, width: 110, height: 60}
	out := m.renderHelpOverlay(110, 60)

	for _, want := range []string{
		"move down / up the herd",                      // picker up/k down/j
		"first / last session",                         // g/home G/end
		"page down / up one window",                    // pgup/pgdn
		"attach the row",                               // picker enter
		"refresh the roster",                           // picker r
		"send the composer",                            // chat enter
		"interrupt (mid-turn) · detach to herd (idle)", // contextual esc (D51h)
		"allow / deny the focused pending card",        // ctrl+a / ctrl+r (D27)
		"cycle to the next pending card",               // tab
		"back to the sessions herd",                    // ctrl+b
		"flip Plan ⇄ Autopilot mode",                   // ctrl+p
		"clear the composer",                           // ctrl+u
		"delete the last character",                    // backspace
		"scroll · half page",                           // scroll family
		"scroll the transcript",                        // mouse wheel
		"expand phases · drill into the agent",         // workflow enter (D14)
		"typing always wins",                           // composing-wins rule
		"quit (persists the draft first)",              // ctrl+c
		"bp chat --theme <name>",                       // the single non-key reference (D66)
	} {
		if !strings.Contains(out, want) {
			t.Errorf("help overlay missing %q", want)
		}
	}

	// NO 'theme' KEY row — theme is a launch flag, never a binding (charter D66).
	if strings.Contains(out, "theme mode") || strings.Contains(out, "cycle theme") {
		t.Error("help overlay must not advertise a theme keybinding")
	}
}

// ── scroll windowing ─────────────────────────────────────────────────────────

// TestHelpScrollWindows: a short terminal windows the body with an overflow
// indicator, and scrolled to the end the window stays a FULL trailing page (never
// shrinks to a lone line adrift), with no false "more" claim.
func TestHelpScrollWindows(t *testing.T) {
	m := Model{helpOpen: true}
	short := m.renderHelpOverlay(100, 18)
	if !strings.Contains(short, "more") {
		t.Errorf("a short view must show the overflow indicator:\n%s", short)
	}

	m.helpScroll = len(helpLines()) - 1
	end := m.renderHelpOverlay(100, 18)
	if strings.Contains(end, "more") {
		t.Error("scrolled to the end must not claim more rows")
	}

	// The last page stays full: top clamps to len-maxRows, not a shrinking tail.
	all := helpLines()
	maxRows := max(18-helpChrome, 4)
	pageStart := max(len(all)-maxRows, 0)
	want, shown := 0, 0
	for _, line := range all[pageStart:] {
		if line == "" {
			continue // blank separators are not rows
		}
		want++
		if strings.Contains(end, line) {
			shown++
		}
	}
	if want <= 1 {
		t.Fatalf("test setup: expected a multi-row last page, got %d", want)
	}
	if shown != want {
		t.Errorf("bottom of scroll must render the full last page (%d rows), got %d:\n%s", want, shown, end)
	}
}

// TestHelpGGJumpsTopBottom: g/G jump to the top and to the render-reachable max
// (len-maxRows), so the last page of k presses is never dead against the clamp.
func TestHelpGGJumpsTopBottom(t *testing.T) {
	m := Model{helpOpen: true, helpScroll: 3, height: 20}

	after, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
	am := after.(Model)
	if want := helpMaxScroll(m.height); am.helpScroll != want {
		t.Errorf("G must jump to max scroll (%d), got %d", want, am.helpScroll)
	}

	back, _ := am.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'g'}})
	if back.(Model).helpScroll != 0 {
		t.Errorf("g must jump to the top (0), got %d", back.(Model).helpScroll)
	}
}

// TestHelpScrollNeverOverclamps: down/j and G never push helpScroll past the
// render window's max, and one k from the bottom immediately moves the rendered
// window (no dead presses) — the handler bound and the render clamp agree.
func TestHelpScrollNeverOverclamps(t *testing.T) {
	for _, height := range []int{10, 18, 24, 40} {
		m := Model{helpOpen: true, height: height}
		maxScroll := helpMaxScroll(m.height)

		for i := 0; i < len(helpLines())+5; i++ {
			next, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
			m = next.(Model)
		}
		if m.helpScroll != maxScroll {
			t.Errorf("height %d: j to the end must land on max (%d), got %d", height, maxScroll, m.helpScroll)
		}

		gm, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
		m = gm.(Model)
		if m.helpScroll != maxScroll {
			t.Errorf("height %d: G must land on max (%d), got %d", height, maxScroll, m.helpScroll)
		}

		before := m.renderHelpOverlay(120, m.height)
		km, _ := m.handleHelpKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
		m = km.(Model)
		after := m.renderHelpOverlay(120, m.height)
		if maxScroll > 0 && before == after {
			t.Errorf("height %d: one k from the bottom must change the window", height)
		}
	}
}

// ── byte-identity contracts ──────────────────────────────────────────────────

// TestChatFooterByteIdenticalWhenClosed pins the verified TurnIdle/no-workflow
// footer (charter D66/D70): 78 bytes, newline + composer + the idle hint line.
// The help slice must not perturb the closed footer by a single byte.
func TestChatFooterByteIdenticalWhenClosed(t *testing.T) {
	m := wfTestModel(t, State{SessionID: "s1"}) // TurnIdle zero value, no workflow
	m.scroll = -1                               // follow mode → no "(scrolled)" notice
	m.input = ""

	got := m.chatFooter()
	want := "\n" + youStyle.Render("› ") + cursorStyle.Render(" ") + "\n" +
		dimStyle.Render("enter send · esc herd · ctrl+p mode · ctrl+b sessions · ctrl+c quit")
	if got != want {
		t.Errorf("closed chatFooter drifted:\n got %q\nwant %q", got, want)
	}
	if len(got) != 78 {
		t.Errorf("closed TurnIdle footer must be 78 bytes, got %d", len(got))
	}
}

// TestPickerFooterAdvertisesHelp pins the D71 fold: the picker hint line now
// advertises `?` help plus the previously-missing pgup/pgdn and g/G paging.
func TestPickerFooterAdvertisesHelp(t *testing.T) {
	m := Model{width: 80, height: 24, sessions: []SessionSummary{{ID: "a"}}}
	out := m.renderPicker()
	for _, want := range []string{"? help", "pgup/pgdn", "g/G ends"} {
		if !strings.Contains(out, want) {
			t.Errorf("picker footer must advertise %q:\n%s", want, out)
		}
	}
}
