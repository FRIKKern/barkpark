package chat

import (
	"errors"
	"fmt"
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

// TestHelpOverlayFitsFrame is the chrome-budget guard (review fix): the rendered
// overlay must never be taller than the frame View hands it — bubbletea drops
// overflow lines from the TOP, so a one-row budget miss clips the modal's border
// and "Keys" header off-screen on every windowed terminal. helpChrome=8 (the
// prior-art constant, spent there against a paneHeight with toolbar/helpbar
// slack chat does not have) fails this at every height below; 10 is the honest
// full-frame budget. Worst case is a mid-scroll window (overflow indicator
// present), so the scan covers every scroll position.
func TestHelpOverlayFitsFrame(t *testing.T) {
	for _, height := range []int{16, 18, 24, 40} {
		for scroll := 0; scroll <= helpMaxScroll(height); scroll++ {
			m := Model{helpOpen: true, helpScroll: scroll, height: height}
			out := m.renderHelpOverlay(100, height)
			if got := strings.Count(out, "\n") + 1; got > height {
				t.Fatalf("height %d scroll %d: overlay renders %d lines — taller than the frame", height, scroll, got)
			}
		}
	}
}

// TestHelpMouseWheelScrollsOverlay (review fix): while the overlay is open the
// wheel scrolls the OVERLAY, clamped to the same bounds as j/k — never the
// transcript hidden behind it (a stealth scroll the user would only discover on
// close). Works over the picker too (the guard sits before the screen gate).
func TestHelpMouseWheelScrollsOverlay(t *testing.T) {
	m := Model{helpOpen: true, screen: screenChat, height: 24, scroll: -1}
	if helpMaxScroll(24) == 0 {
		t.Fatal("test setup: overlay must overflow at height 24")
	}

	next, _ := m.handleMouse(tea.MouseMsg{Button: tea.MouseButtonWheelDown, Action: tea.MouseActionPress})
	nm := next.(Model)
	if nm.helpScroll != 1 {
		t.Errorf("wheel down must scroll the overlay, got helpScroll=%d", nm.helpScroll)
	}
	if nm.scroll != -1 {
		t.Errorf("wheel while help is open must NOT touch the transcript scroll, got %d", nm.scroll)
	}

	up, _ := nm.handleMouse(tea.MouseMsg{Button: tea.MouseButtonWheelUp, Action: tea.MouseActionPress})
	um := up.(Model)
	if um.helpScroll != 0 {
		t.Errorf("wheel up must scroll the overlay back, got %d", um.helpScroll)
	}
	moreUp, _ := um.handleMouse(tea.MouseMsg{Button: tea.MouseButtonWheelUp, Action: tea.MouseActionPress})
	if moreUp.(Model).helpScroll != 0 {
		t.Errorf("wheel up at the top must clamp at 0, got %d", moreUp.(Model).helpScroll)
	}

	// Over the picker the wheel drives the overlay too (no screen gate).
	pm := Model{helpOpen: true, screen: screenPicker, height: 24}
	pnext, _ := pm.handleMouse(tea.MouseMsg{Button: tea.MouseButtonWheelDown, Action: tea.MouseActionPress})
	if pnext.(Model).helpScroll != 1 {
		t.Errorf("wheel over the picker overlay must scroll it, got %d", pnext.(Model).helpScroll)
	}
}

// ── the archive key (charter D28, t3w2-s7) ───────────────────────────────────

// TestPickerArchiveKeyRemovesRowOptimistically: `a` on a session row drops it
// from the roster IMMEDIATELY and fires the archive verb. The optimism is not a
// latency trick — the server emits NO fleet frame for an archive flip, so this
// removal is the only signal the list will ever get.
func TestPickerArchiveKeyRemovesRowOptimistically(t *testing.T) {
	tr := &fakeTransport{}
	m := newTestModel(tr)
	m.sessions = []SessionSummary{{ID: "a"}, {ID: "b"}, {ID: "c"}}
	m.pickCursor = 2 // row index 1 in the attention order

	want := m.orderedSessions()[1].ID
	next, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	nm := next.(Model)

	if len(nm.sessions) != 2 {
		t.Fatalf("the row must leave the roster on the keypress, got %d rows", len(nm.sessions))
	}
	for _, s := range nm.sessions {
		if s.ID == want {
			t.Fatalf("session %q must be gone from the roster", want)
		}
	}
	if cmd == nil {
		t.Fatal("`a` must issue the archive command")
	}
	msg := cmd()
	am, ok := msg.(archivedMsg)
	if !ok {
		t.Fatalf("want archivedMsg, got %T", msg)
	}
	if am.id != want || len(tr.archived) != 1 || tr.archived[0] != want {
		t.Fatalf("archive must target %q, got msg=%+v transport=%v", want, am, tr.archived)
	}
}

// TestPickerArchiveKeyIgnoresNewSessionRow: cursor 0 is "+ new session", not a
// session. `a` there must do NOTHING — archiving whatever happens to sort first
// would be a destructive misfire on the one row that is not a session at all.
func TestPickerArchiveKeyIgnoresNewSessionRow(t *testing.T) {
	tr := &fakeTransport{}
	m := newTestModel(tr)
	m.sessions = []SessionSummary{{ID: "a"}}
	m.pickCursor = 0

	next, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	if got := len(next.(Model).sessions); got != 1 {
		t.Fatalf("`a` on the new-session row must not touch the roster, got %d rows", got)
	}
	if cmd != nil {
		t.Fatal("`a` on the new-session row must issue no command")
	}
}

// TestPickerArchiveKeyClampsCursor: removing the last row must not strand the
// cursor past the shortened roster.
func TestPickerArchiveKeyClampsCursor(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m.sessions = []SessionSummary{{ID: "a"}, {ID: "b"}}
	m.pickCursor = 2 // the last session row

	nm := mustModel(m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}}))
	if nm.pickCursor > len(nm.sessions) {
		t.Fatalf("cursor %d must be clamped to the %d remaining rows", nm.pickCursor, len(nm.sessions))
	}
}

// TestArchiveLeavesHerdStateAlone is the orthogonality pin: archived_at is
// DISMISSAL, agent_state is ATTENTION. A dismissed session that is still
// working is still working — scrubbing or flipping its herd row on the way out
// would be the client inventing a liveness change the server never made.
func TestArchiveLeavesHerdStateAlone(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m.sessions = []SessionSummary{{ID: "a", AgentState: "working"}}
	m.herd = herdSeed(m.herd, m.sessions)
	m.pickCursor = 1
	before := m.herd.Rows["a"]

	nm := mustModel(m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}}))
	if got := nm.herd.Rows["a"]; got.AgentState != before.AgentState {
		t.Errorf("archiving must not touch agent_state: was %q, now %q", before.AgentState, got.AgentState)
	}
}

// TestArchiveFailureSurfacesAndRefetches: the archive POST failing must say so
// AND re-read the roster. The re-read is what puts the row back — re-inserting
// a remembered row would fight the attention sort and paint a stale state.
func TestArchiveFailureSurfacesAndRefetches(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	next, cmd := m.Update(archivedMsg{id: "a", err: errArchiveTest})
	nm := next.(Model)
	if !strings.Contains(nm.pickErr, "archive failed") {
		t.Errorf("a failed archive must surface honestly, got %q", nm.pickErr)
	}
	if cmd == nil {
		t.Fatal("a failed archive must re-read the roster")
	}
	if _, ok := cmd().(sessionsLoadedMsg); !ok {
		t.Error("the recovery command must be the roster re-read")
	}
}

// TestArchiveSuccessIsSilent: the row is already gone, so a successful flip has
// nothing to say and nothing to re-fetch.
func TestArchiveSuccessIsSilent(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	next, cmd := m.Update(archivedMsg{id: "a"})
	if got := next.(Model).pickErr; got != "" {
		t.Errorf("a successful archive must be silent, got %q", got)
	}
	if cmd != nil {
		t.Error("a successful archive must issue no follow-up command")
	}
}

// TestHelpAdvertisesArchiveKey spot-pins the new picker row (help rows are
// spot-pinned by design — the overlay is the canonical key map).
func TestHelpAdvertisesArchiveKey(t *testing.T) {
	joined := strings.Join(helpLines(), "\n")
	if !strings.Contains(joined, "archive the row") {
		t.Errorf("the help overlay must document the archive key:\n%s", joined)
	}
	// Dismissal, not deletion, and not a status change — the intent column is
	// what stops `a` reading as "kill this session".
	if !strings.Contains(joined, "keeps running") {
		t.Error("the archive help row must say the session keeps running")
	}
}

// ── the archived shelf screen (charter D28, mob-bl-tui-shelf-screen) ─────────

// shelfModel is a Model parked ON the shelf with the given archived roster —
// the state every shelf-key proof starts from.
func shelfModel(tr *fakeTransport, ids ...string) Model {
	m := newTestModel(tr)
	m.screen = screenShelf
	for _, id := range ids {
		m.shelf = append(m.shelf, SessionSummary{ID: id, Title: id})
	}
	return m
}

// TestShelfKeyOpensTheShelfAndReadsIt: `s` on the herd home foregrounds the
// shelf screen and fires the ARCHIVED read — the door `a` puts rows through,
// finally readable from inside the pane.
func TestShelfKeyOpensTheShelfAndReadsIt(t *testing.T) {
	tr := &fakeTransport{archivedList: []SessionSummary{{ID: "old", Title: "shelved one"}}}
	m := newTestModel(tr)
	m.sessions = []SessionSummary{{ID: "a"}}

	next, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'s'}})
	nm := next.(Model)
	if nm.screen != screenShelf {
		t.Fatalf("`s` must foreground the shelf, got screen %v", nm.screen)
	}
	if !nm.shelfLoading {
		t.Error("opening the shelf must show the honest loading state")
	}
	if cmd == nil {
		t.Fatal("`s` must issue the archived read")
	}
	msg, ok := cmd().(shelfLoadedMsg)
	if !ok {
		t.Fatalf("want shelfLoadedMsg, got %T", msg)
	}
	if len(msg.sessions) != 1 || msg.sessions[0].ID != "old" {
		t.Fatalf("the shelf read must be the ARCHIVED list, got %+v", msg.sessions)
	}
	// The read lands on the shelf roster ONLY — the herd roster the fleet stream
	// folds into must never be overwritten by a shelf browse.
	loaded := mustModel(nm.Update(msg))
	if len(loaded.shelf) != 1 || len(loaded.sessions) != 1 || loaded.sessions[0].ID != "a" {
		t.Fatalf("the shelf read must not touch the herd roster, got shelf=%v sessions=%v",
			loaded.shelf, loaded.sessions)
	}
}

// TestShelfRestoreKeyUnarchivesTheRow is the RESTORE KEY pin: `enter` AND `u`
// both put the cursor row back, through Transport.Unarchive (the member that
// only belongs on the interface because THIS caller exists). The removal is
// optimistic for the same reason archive's is — no fleet frame is emitted for an
// archived_at flip in either direction.
func TestShelfRestoreKeyUnarchivesTheRow(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyEnter},
		{Type: tea.KeyRunes, Runes: []rune{'u'}},
	} {
		tr := &fakeTransport{}
		m := shelfModel(tr, "one", "two", "three")
		m.shelfCursor = 1

		next, cmd := m.handleKey(key)
		nm := next.(Model)
		if len(nm.shelf) != 2 {
			t.Fatalf("%s: the row must leave the shelf on the keypress, got %d rows", key, len(nm.shelf))
		}
		for _, s := range nm.shelf {
			if s.ID == "two" {
				t.Fatalf("%s: session two must be gone from the shelf", key)
			}
		}
		if cmd == nil {
			t.Fatalf("%s: the restore key must issue the unarchive command", key)
		}
		um, ok := cmd().(unarchivedMsg)
		if !ok {
			t.Fatalf("%s: want unarchivedMsg, got %T", key, um)
		}
		if um.id != "two" || len(tr.unarchived) != 1 || tr.unarchived[0] != "two" {
			t.Fatalf("%s: unarchive must target \"two\", got msg=%+v transport=%v", key, um, tr.unarchived)
		}
	}
}

// TestShelfRestoreOnEmptyShelfIsANoOp: nothing to restore means nothing
// happens — never a negative index, never a restore of whatever sorts first.
func TestShelfRestoreOnEmptyShelfIsANoOp(t *testing.T) {
	tr := &fakeTransport{}
	next, cmd := shelfModel(tr).handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil {
		t.Error("enter on an empty shelf must issue no command")
	}
	if got := next.(Model).shelfCursor; got != 0 {
		t.Errorf("the cursor must stay at 0 on an empty shelf, got %d", got)
	}
	if len(tr.unarchived) != 0 {
		t.Errorf("nothing may be unarchived from an empty shelf, got %v", tr.unarchived)
	}
}

// TestShelfCursorStaysInsideTheShelf: the shelf cursor indexes rows DIRECTLY
// (there is no "+ new session" row here), and every movement key clamps.
func TestShelfCursorStaysInsideTheShelf(t *testing.T) {
	m := shelfModel(&fakeTransport{}, "one", "two")
	for _, key := range []string{"down", "down", "down", "G", "pgdown"} {
		m = mustModel(m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)}))
	}
	m = mustModel(m.handleKey(tea.KeyMsg{Type: tea.KeyDown}))
	if m.shelfCursor > len(m.shelf)-1 {
		t.Fatalf("the cursor must clamp to the last row, got %d of %d", m.shelfCursor, len(m.shelf))
	}
	m = mustModel(m.handleKey(tea.KeyMsg{Type: tea.KeyUp}))
	m = mustModel(m.handleKey(tea.KeyMsg{Type: tea.KeyUp}))
	m = mustModel(m.handleKey(tea.KeyMsg{Type: tea.KeyUp}))
	if m.shelfCursor != 0 {
		t.Fatalf("the cursor must clamp at the top, got %d", m.shelfCursor)
	}
}

// TestShelfEscReturnsToTheHerd: esc (and `s` again) closes the shelf and
// re-reads the roster, so a row restored during the visit is already on the
// herd home when it paints.
func TestShelfEscReturnsToTheHerd(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyEsc},
		{Type: tea.KeyRunes, Runes: []rune{'s'}},
	} {
		next, cmd := shelfModel(&fakeTransport{}, "one").handleKey(key)
		if got := next.(Model).screen; got != screenPicker {
			t.Fatalf("%s must return to the herd, got screen %v", key, got)
		}
		if cmd == nil {
			t.Fatalf("%s must re-read the roster on the way out", key)
		}
		if _, ok := cmd().(sessionsLoadedMsg); !ok {
			t.Errorf("%s: the exit command must be the roster re-read", key)
		}
	}
}

// TestShelfRestoreSuccessRereadsTheRoster: the restored row has to APPEAR on the
// herd home, and no fleet frame is emitted for the flip — so success is NOT
// silent here (unlike archive's), it re-reads the active roster.
func TestShelfRestoreSuccessRereadsTheRoster(t *testing.T) {
	m := shelfModel(&fakeTransport{})
	next, cmd := m.Update(unarchivedMsg{id: "one"})
	if got := next.(Model).shelfErr; got != "" {
		t.Errorf("a successful restore must say nothing, got %q", got)
	}
	if cmd == nil {
		t.Fatal("a successful restore must re-read the ACTIVE roster")
	}
	if _, ok := cmd().(sessionsLoadedMsg); !ok {
		t.Error("the follow-up command must be the roster re-read")
	}
}

// TestShelfRestoreFailureSurfacesAndRereadsTheShelf: a REFUSED restore says so
// and re-reads the SHELF — which is what puts the row back. Re-inserting the
// remembered row at a guessed position would paint a state the server never
// confirmed (the archive path's law, mirrored).
func TestShelfRestoreFailureSurfacesAndRereadsTheShelf(t *testing.T) {
	m := shelfModel(&fakeTransport{})
	next, cmd := m.Update(unarchivedMsg{id: "one", err: errArchiveTest})
	if got := next.(Model).shelfErr; !strings.Contains(got, "unarchive failed") {
		t.Errorf("a refused restore must surface honestly, got %q", got)
	}
	if cmd == nil {
		t.Fatal("a refused restore must re-read the shelf")
	}
	if _, ok := cmd().(shelfLoadedMsg); !ok {
		t.Error("the recovery command must be the SHELF re-read, not the roster's")
	}
}

// TestHelpAdvertisesTheShelf spot-pins the shelf rows in the key reference: the
// overlay is the canonical key map, so a screen it does not document is a screen
// nobody can find.
func TestHelpAdvertisesTheShelf(t *testing.T) {
	joined := strings.Join(helpLines(), "\n")
	for _, want := range []string{"open the archived shelf", "restore the row to the herd", "bp chat unarchive"} {
		if !strings.Contains(joined, want) {
			t.Errorf("the help overlay must document %q:\n%s", want, joined)
		}
	}
}

var errArchiveTest = errors.New("boom")

// mustModel unwraps a handleKey result. Written to take the handler's two
// returns directly so a call site reads mustModel(m.handleKey(...)).
func mustModel(m tea.Model, _ tea.Cmd) Model {
	return m.(Model)
}

// ── jumpToPendingCard (charter D80: its first DIRECT coverage) ───────────────

// jumpCardModel is a transcript with one pending approval card sitting `before`
// one-line messages down and `after` messages below it — the needs-you jump's
// real shape (a card the reader has to be taken to).
func jumpCardModel(t *testing.T, before, after int) Model {
	t.Helper()
	msgs := make([]Message, 0, before+after+1)
	for i := 1; i <= before; i++ {
		msgs = append(msgs, Message{Seq: i, Role: "user", SourceMarkdown: fmt.Sprintf("before-%02d", i)})
	}
	msgs = append(msgs, liveApprovalCard(before+1, "req-42"))
	for i := 1; i <= after; i++ {
		msgs = append(msgs, Message{Seq: before + 1 + i, Role: "user", SourceMarkdown: fmt.Sprintf("after-%02d", i)})
	}
	return wfTestModel(t, State{SessionID: "s1", Messages: msgs, LastSeq: before + after + 1})
}

// TestJumpToPendingCardLandsTheCardInView is jumpToPendingCard's first direct
// test: at every representative geometry the jump leaves follow mode, puts the
// card's FIRST line at the top of the viewport, and shows the card's prompt —
// asserted against the rendered viewport, not just the numeric scroll.
func TestJumpToPendingCardLandsTheCardInView(t *testing.T) {
	for _, h := range []int{10, 12, 16, 24, 40} {
		m := jumpCardModel(t, 10, 30)
		m.height = h
		all, start, _ := m.transcriptAnchored(m.width, "req-42")
		if start <= 0 {
			t.Fatalf("h=%d setup: the accumulator must locate the card block", h)
		}
		if start > m.maxScrollTop() {
			t.Fatalf("h=%d setup: the card must pin ABOVE the bottom (start=%d maxTop=%d)", h, start, m.maxScrollTop())
		}

		got := m.jumpToPendingCard()
		if got.scroll < 0 {
			t.Fatalf("h=%d: the jump must leave follow mode", h)
		}
		if !got.anchor.set {
			t.Fatalf("h=%d: the jump must pin to CONTENT (an anchor), not a bare line number", h)
		}
		view := got.transcriptViewport(d80BodyHeight(got))
		if len(view) == 0 || view[0] != all[start] {
			t.Fatalf("h=%d: the card block must sit at the top of the viewport, got %q want %q", h, view[0], all[start])
		}
		if !strings.Contains(strings.Join(view, "\n"), "run rm -rf?") {
			t.Fatalf("h=%d: the jumped-to viewport must show the card's prompt:\n%s", h, strings.Join(view, "\n"))
		}
	}
}

// TestJumpToPendingCardClampsAndStillShowsTheCard: a card in the bottom tail
// cannot be pinned to the top (there is not a screenful below it), so the jump
// clamps to maxScrollTop — and the card must still be ON SCREEN, which is the
// property that actually matters to the reader.
func TestJumpToPendingCardClampsAndStillShowsTheCard(t *testing.T) {
	m := jumpCardModel(t, 40, 0)
	_, start, _ := m.transcriptAnchored(m.width, "req-42")
	maxTop := m.maxScrollTop()
	if start <= maxTop {
		t.Fatalf("setup: this geometry must exercise the clamp (start=%d maxTop=%d)", start, maxTop)
	}
	got := m.jumpToPendingCard()
	if got.scroll != maxTop {
		t.Fatalf("a bottom-tail card must clamp to maxScrollTop, got %d want %d", got.scroll, maxTop)
	}
	view := got.transcriptViewport(d80BodyHeight(got))
	if !strings.Contains(strings.Join(view, "\n"), "run rm -rf?") {
		t.Fatalf("the clamped jump must still show the card:\n%s", strings.Join(view, "\n"))
	}
}

// TestJumpToPendingCardIsContentRelative: the jump's pin is an ANCHOR, so a
// height change ABOVE the card cannot slide the card out from under it — the
// same D80 property the manual freeze gets, proven on the jump path.
func TestJumpToPendingCardIsContentRelative(t *testing.T) {
	m := jumpCardModel(t, 10, 30)
	got := m.jumpToPendingCard()
	bodyH := d80BodyHeight(got)
	before := append([]string(nil), got.transcriptViewport(bodyH)...)

	got.st.Messages[1].SourceMarkdown = "before-02" + strings.Repeat("\nfiller", 11)
	afterAll := got.transcriptLines(got.width)
	if raw := window(afterAll, bodyH, got.scroll); equalLines(raw, before) {
		t.Fatal("vacuous: the raw index already reproduces the jumped viewport")
	}
	if after := got.transcriptViewport(bodyH); !equalLines(after, before) {
		t.Fatalf("growth above the card moved the jumped viewport.\nwas:\n%s\n\nnow:\n%s",
			strings.Join(before, "\n"), strings.Join(after, "\n"))
	}
}

// TestJumpToPendingCardWithNoCardIsANoOp: with nothing focused the jump must
// leave the model completely alone — scroll, anchor, focus and panel state.
func TestJumpToPendingCardWithNoCardIsANoOp(t *testing.T) {
	m := jumpCardModel(t, 10, 30)
	m.st.Messages = m.st.Messages[:10] // drop the card — nothing answerable left
	m.focus = focusWorkflow
	m.wfExpanded = true
	if _, ok := m.focusedCard(); ok {
		t.Fatal("setup: no card may be focused")
	}
	got := m.jumpToPendingCard()
	if got.scroll != m.scroll || got.anchor.set || got.focus != focusWorkflow || !got.wfExpanded {
		t.Fatalf("a jump with no focused card must be a no-op, got scroll=%d anchor=%+v focus=%v expanded=%v",
			got.scroll, got.anchor, got.focus, got.wfExpanded)
	}
}
