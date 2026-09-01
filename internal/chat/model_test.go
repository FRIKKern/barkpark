package chat

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// model_test.go — the shell proofs, driven against a fake Transport (no
// terminal, no server). The load-bearing one is D14/D15 continuity: the
// full-session GET hydrates the writable set and the draft, and quit/switch
// PATCHes it back — the roundtrip that keeps a conversation resumable.

// fakeTransport records every call and returns canned data. It is the whole IO
// seam, so the shell drives deterministically.
type uploadCall struct{ id, path string }

type fakeTransport struct {
	summaries []SessionSummary
	full      Session
	created   Session

	getCalls    []getCall
	patched     map[string]any
	patchedID   string
	sent        []string
	interrupted bool
	approvals   []approvalCall
	answers     []answerCall
	answerErr   error
	approveErr  error
	uploads     []uploadCall
	uploadRef   Attachment
	uploadErr   error
	listErr     error
	getErr      error

	archived     []string
	unarchived   []string
	archiveErr   error
	archivedList []SessionSummary
}

type approvalCall struct {
	id, requestID, decision string
}

type answerCall struct {
	id, requestID string
	answers       map[string]any
}

type getCall struct {
	id    string
	since int
}

func (f *fakeTransport) CreateSession() (Session, error) { return f.created, nil }
func (f *fakeTransport) ListSessions() ([]SessionSummary, error) {
	return f.summaries, f.listErr
}
func (f *fakeTransport) ListArchivedSessions() ([]SessionSummary, error) {
	return f.archivedList, f.listErr
}
func (f *fakeTransport) Archive(id string) error {
	f.archived = append(f.archived, id)
	return f.archiveErr
}
func (f *fakeTransport) Unarchive(id string) error {
	f.unarchived = append(f.unarchived, id)
	return f.archiveErr
}
func (f *fakeTransport) GetSession(id string, since int) (Session, error) {
	f.getCalls = append(f.getCalls, getCall{id: id, since: since})
	return f.full, f.getErr
}
func (f *fakeTransport) PatchSession(id string, fields map[string]any) error {
	f.patchedID = id
	f.patched = fields
	return nil
}
func (f *fakeTransport) SendMessage(id, content string) error {
	f.sent = append(f.sent, content)
	return nil
}
func (f *fakeTransport) Interrupt(id string) error { f.interrupted = true; return nil }

// UploadAttachment records the (session, path) pair the shell asked for. The
// fake never touches the filesystem: the seam under test is "what the shell
// asks the transport to do", and the real read+POST is covered against a live
// httptest server in internal/apiclient.
func (f *fakeTransport) UploadAttachment(sessionID, path string) (Attachment, error) {
	f.uploads = append(f.uploads, uploadCall{id: sessionID, path: path})
	return f.uploadRef, f.uploadErr
}

func (f *fakeTransport) Approve(id, requestID, decision string) error {
	f.approvals = append(f.approvals, approvalCall{id: id, requestID: requestID, decision: decision})
	return f.approveErr
}
func (f *fakeTransport) AnswerQuestion(id, requestID string, answers map[string]any) error {
	f.answers = append(f.answers, answerCall{id: id, requestID: requestID, answers: answers})
	return f.answerErr
}
func (f *fakeTransport) Events(ctx context.Context, id string, lastSeq int, onFrame func(string, []byte)) error {
	<-ctx.Done()
	return nil
}
func (f *fakeTransport) FleetEvents(ctx context.Context, lastEventID string, onFrame func(string, []byte)) error {
	<-ctx.Done()
	return nil
}

func newTestModel(f *fakeTransport) Model {
	return newModel(f, &streamer{tr: f}, Config{BaseURL: "http://localhost:4000", Token: "tok"})
}

// runCmd executes a single (non-batch) tea.Cmd and returns its message. nil-safe.
func runCmd(cmd tea.Cmd) tea.Msg {
	if cmd == nil {
		return nil
	}
	return cmd()
}

// TestPickerRendersWorkflowCard proves the epic-cycle session card reaches the
// rendered picker (wsc-s4): a session running a workflow surfaces its phase ticks
// and settled/total counter in the launch list, so 'what is running and how far'
// is visible at a glance — while down-arrow still stops exactly once per session
// (the multi-line row is ONE navigable entry, not one-stop-per-sub-line).
func TestPickerRendersWorkflowCard(t *testing.T) {
	wf := SessionWorkflow{
		Label:       "epic-cycle — session card",
		Ticks:       []string{"done", "done", "done", "done", "active", "future", "future"},
		Phase:       "building",
		AgentsDone:  13,
		AgentsTotal: 17,
		Tokens:      1543000,
	}
	f := &fakeTransport{summaries: []SessionSummary{
		{ID: "plain", Title: "just chatting", MessageCount: 2},
		{ID: "cycle", Title: "wave run", MessageCount: 9, Workflow: &wf,
			Epic: &EpicGoal{Title: "Epic Cycle chat", SlicesDone: 2, SlicesTotal: 5}},
	}}
	m := newTestModel(f)
	m.width, m.height = 80, 24
	nm, _ := m.Update(sessionsLoadedMsg{sessions: f.summaries})
	m = nm.(Model)

	view := m.View()
	for _, want := range []string{"13/17", "building", "Epic Cycle chat", "slices"} {
		if !strings.Contains(view, want) {
			t.Errorf("picker must surface %q for a workflow session, got:\n%s", want, view)
		}
	}

	// Down-arrow walks new(0) → plain(1) → cycle(2) and then clamps: one stop per
	// session, unaffected by the workflow row's extra height.
	for i := 0; i < 6; i++ {
		nm, _ = m.handlePickerKey(tea.KeyMsg{Type: tea.KeyDown})
		m = nm.(Model)
	}
	if m.pickCursor != len(m.sessions) {
		t.Fatalf("cursor must clamp at one stop per session (%d), got %d", len(m.sessions), m.pickCursor)
	}
}

// TestResumeReGetsFullAndRestoresDraft proves D14: the summary list omits the
// draft, so resume RE-GETs the full session and restores the draft into the
// composer plus the writable continuity set.
func TestResumeReGetsFullAndRestoresDraft(t *testing.T) {
	f := &fakeTransport{
		summaries: []SessionSummary{{ID: "s1", Title: "First", MessageCount: 2}},
		full: Session{
			ID: "s1", Title: "First", Draft: "half-written thought",
			Mode: "build", ModelChoice: "opus", EffortChoice: "high",
			Messages: []Message{{Seq: 1, Role: "user", SourceMarkdown: "hi"}, {Seq: 2, Role: "assistant", SourceMarkdown: "hello"}},
		},
	}
	m := newTestModel(f)

	// Load the picker list.
	nm, _ := m.Update(sessionsLoadedMsg{sessions: f.summaries})
	m = nm.(Model)
	if len(m.sessions) != 1 {
		t.Fatalf("picker should hold 1 session, got %d", len(m.sessions))
	}

	// Move onto the session row (index 1; index 0 is "+ new session") and open it.
	m.pickCursor = 1
	_, cmd := m.openPickerRow()
	msg := runCmd(cmd)
	opened, ok := msg.(sessionOpenedMsg)
	if !ok {
		t.Fatalf("resume must produce sessionOpenedMsg, got %T", msg)
	}
	// The resume must have re-GET the FULL session (since=0), not trusted the summary.
	if len(f.getCalls) != 1 || f.getCalls[0].id != "s1" || f.getCalls[0].since != 0 {
		t.Fatalf("resume must re-GET the full session (since=0), got calls %+v", f.getCalls)
	}

	nm, _ = m.Update(opened)
	m = nm.(Model)
	if m.screen != screenChat {
		t.Fatal("opening a session must foreground the conversation")
	}
	if m.input != "half-written thought" {
		t.Fatalf("draft must restore into the composer, got %q", m.input)
	}
	if m.mode != "build" || m.modelChoice != "opus" || m.effortChoice != "high" {
		t.Fatalf("writable continuity set must hydrate, got mode=%q model=%q effort=%q", m.mode, m.modelChoice, m.effortChoice)
	}
	if m.st.LastSeq != 2 {
		t.Fatalf("seq cursor must hydrate to the max row, got %d", m.st.LastSeq)
	}
}

// TestLeaveSessionPatchesContinuity proves the other half of D14: switching back
// to the picker PATCHes the writable set (with the possibly-edited draft) so
// nothing typed is lost.
func TestLeaveSessionPatchesContinuity(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m = m.openSession(Session{ID: "s1", Mode: "plan", ModelChoice: "sonnet", EffortChoice: "low"})
	m.input = "edited draft to persist"

	// leaveSession batches the PATCH + a reload; run the pre-leave patch cmd
	// directly to assert the persisted fields, and capture the returned model to
	// assert the screen switch.
	runCmd(m.patchContinuityCmd())
	nm, cmd := m.leaveSession()
	m = nm

	if m.screen != screenPicker {
		t.Fatal("leaving a session must return to the picker")
	}
	if f.patchedID != "s1" {
		t.Fatalf("patch must target the session, got %q", f.patchedID)
	}
	if f.patched["draft"] != "edited draft to persist" {
		t.Fatalf("patch must carry the edited draft, got %v", f.patched["draft"])
	}
	if f.patched["mode"] != "plan" || f.patched["model_choice"] != "sonnet" || f.patched["effort_choice"] != "low" {
		t.Fatalf("patch must carry the writable continuity set, got %v", f.patched)
	}
	_ = cmd
}

// TestSendEffectPosts proves the reducer→transport bridge: a SendEffect turns
// into a SendMessage call.
func TestSendEffectPosts(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m.st.SessionID = "s1"
	runCmd(m.execEffect(SendEffect{Content: "a question"}))
	if len(f.sent) != 1 || f.sent[0] != "a question" {
		t.Fatalf("SendEffect must POST the message, got %v", f.sent)
	}
}

// TestInterruptEffectPosts proves an InterruptEffect calls Interrupt.
func TestInterruptEffectPosts(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m.st.SessionID = "s1"
	runCmd(m.execEffect(InterruptEffect{}))
	if !f.interrupted {
		t.Fatal("InterruptEffect must POST the interrupt")
	}
}

// TestFetchTailEffectGetsSince proves a FetchTailEffect GETs with the since
// cursor and returns a tailFetchedMsg.
func TestFetchTailEffectGetsSince(t *testing.T) {
	f := &fakeTransport{full: Session{ID: "s1", Title: "T"}}
	m := newTestModel(f)
	m.st.SessionID = "s1"
	msg := runCmd(m.execEffect(FetchTailEffect{SinceSeq: 5}))
	if _, ok := msg.(tailFetchedMsg); !ok {
		t.Fatalf("FetchTailEffect must produce tailFetchedMsg, got %T", msg)
	}
	if len(f.getCalls) != 1 || f.getCalls[0].since != 5 {
		t.Fatalf("FetchTailEffect must GET with the since cursor, got %+v", f.getCalls)
	}
}

// TestFetchTailEffectThreadsGen proves the settle-race token (charter D77) rides
// the shell: execEffect stamps the FetchTailEffect's issuing generation onto the
// tailFetchedMsg it returns, so the reducer can prove the landing GET still owns
// the live tail.
func TestFetchTailEffectThreadsGen(t *testing.T) {
	f := &fakeTransport{full: Session{ID: "s1"}}
	m := newTestModel(f)
	m.st.SessionID = "s1"
	msg := runCmd(m.execEffect(FetchTailEffect{SinceSeq: 3, Gen: 7}))
	tf, ok := msg.(tailFetchedMsg)
	if !ok {
		t.Fatalf("FetchTailEffect must produce tailFetchedMsg, got %T", msg)
	}
	if tf.gen != 7 {
		t.Fatalf("execEffect must thread the issuing generation, got gen=%d want 7", tf.gen)
	}
}

// TestTailFetchedMsgGenGuardsTailClear proves the full shell path (charter D77):
// Update maps tailFetchedMsg.gen → TailFetchedEvent.Gen, so a stale-generation
// GET landing over a live tail leaves it intact while a matching one clears it.
func TestTailFetchedMsgGenGuardsTailClear(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m.screen = screenChat
	m.st = State{SessionID: "s1", Tail: "live", TailGen: 5}

	// A stale GET (older generation) must NOT clear the live tail.
	nm, _ := m.Update(tailFetchedMsg{session: Session{ID: "s1"}, gen: 4})
	if got := nm.(Model).st.Tail; got != "live" {
		t.Fatalf("a stale-gen tailFetchedMsg must not clear the tail, got %q", got)
	}

	// A matching GET clears it.
	nm, _ = nm.(Model).Update(tailFetchedMsg{session: Session{ID: "s1"}, gen: 5})
	if got := nm.(Model).st.Tail; got != "" {
		t.Fatalf("a matching-gen tailFetchedMsg must clear the tail, got %q", got)
	}
}

// TestPickerNewSessionRow proves the "+ new session" row (index 0) creates a
// session rather than resuming one.
func TestPickerNewSessionRow(t *testing.T) {
	f := &fakeTransport{created: Session{ID: "new1"}}
	m := newTestModel(f)
	m.sessions = []SessionSummary{{ID: "s1"}}
	m.pickCursor = 0
	_, cmd := m.openPickerRow()
	msg := runCmd(cmd)
	opened, ok := msg.(sessionOpenedMsg)
	if !ok || opened.session.ID != "new1" {
		t.Fatalf("the new-session row must create a session, got %#v", msg)
	}
	if len(f.getCalls) != 0 {
		t.Fatal("creating a session must NOT re-GET an existing one")
	}
}

// TestPickerCursorBounds proves the picker cursor never leaves [0, len].
func TestPickerCursorBounds(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m.sessions = []SessionSummary{{ID: "a"}, {ID: "b"}}
	m.pickCursor = 0
	// up at the top stays.
	nm, _ := m.handlePickerKey(tea.KeyMsg{Type: tea.KeyUp})
	if nm.(Model).pickCursor != 0 {
		t.Fatal("up at top must stay at 0")
	}
	// down past the end clamps at len (the last session row).
	m.pickCursor = 2
	nm, _ = m.handlePickerKey(tea.KeyMsg{Type: tea.KeyDown})
	if nm.(Model).pickCursor != 2 {
		t.Fatalf("down past the end must clamp at len=%d, got %d", len(m.sessions), nm.(Model).pickCursor)
	}
}

// TestSessionsLoadErrorShowsHonestState proves a load failure surfaces on the
// picker instead of crashing or blanking.
func TestSessionsLoadErrorShowsHonestState(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	nm, _ := m.Update(sessionsLoadedMsg{err: errString("network down")})
	got := nm.(Model)
	if got.pickErr != "network down" {
		t.Fatalf("a load error must set pickErr, got %q", got.pickErr)
	}
	if got.loading {
		t.Fatal("loading must clear after a failed load")
	}
}

// TestCardKeyAnswersFocusedCard proves the end-to-end key path: Ctrl+A on a
// conversation with a pending card resolves the focused card's request_id into
// an approval POST through the transport (allow), and Ctrl+R denies.
func TestCardKeyAnswersFocusedCard(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m.screen = screenChat
	m.st = State{
		SessionID: "s1",
		Messages: []Message{{
			Seq: 4, Role: "approval", SourceMarkdown: "run rm?",
			Metadata: map[string]any{"request_id": "req-42", "approval_status": "pending"},
		}},
		LastSeq: 4,
	}

	// Ctrl+A allows the focused card.
	nm, cmd := m.handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlA})
	m = nm.(Model)
	if m.st.AnswerInFlight["req-42"] != "allow" {
		t.Fatalf("Ctrl+A must mark the focused card allowing, got %v", m.st.AnswerInFlight)
	}
	// The batch contains the AnswerEffect's POST command; run it and assert the call.
	runCmd(cmd)
	if len(f.approvals) != 1 || f.approvals[0].requestID != "req-42" || f.approvals[0].decision != "allow" {
		t.Fatalf("Ctrl+A must POST the approval {req-42, allow}, got %+v", f.approvals)
	}

	// Ctrl+R on a fresh model denies.
	f2 := &fakeTransport{}
	m2 := newTestModel(f2)
	m2.screen = screenChat
	m2.st = m.st
	m2.st.AnswerInFlight = nil
	nm2, cmd2 := m2.handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlR})
	_ = nm2
	runCmd(cmd2)
	if len(f2.approvals) != 1 || f2.approvals[0].decision != "deny" {
		t.Fatalf("Ctrl+R must POST the deny decision, got %+v", f2.approvals)
	}
}

// TestAnswerDoneErrorSurfaces proves a transport-level approval failure lands an
// honest notice through the shell (not a crash, not a stuck badge).
func TestAnswerDoneErrorSurfaces(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m.screen = screenChat
	m.st = State{SessionID: "s1", AnswerInFlight: map[string]string{"req-1": "allow"}}
	nm, _ := m.Update(answerDoneMsg{requestID: "req-1", err: errString("boom")})
	if got := nm.(Model).st.Notice; got == "" {
		t.Fatal("an approval error must surface a notice")
	}
}

// TestResumeHydratesRail proves Law-2: opening a session decodes its
// rail_snapshot into the rail so a surface switch lands on the same rail.
func TestResumeHydratesRail(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m = m.openSession(Session{
		ID:           "s1",
		RailSnapshot: json.RawMessage(`{"t1":{"status":"running","row":{"description":"builder"}}}`),
	})
	if len(m.st.Rail) != 1 || m.st.Rail[0].Label != "builder" {
		t.Fatalf("resume must hydrate the rail from the snapshot, got %+v", m.st.Rail)
	}
}

// TestStreamFrameDrivesReducer proves a live SSE frame flows through the reducer
// (a delta accumulates the tail).
func TestStreamFrameDrivesReducer(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	m.screen = screenChat
	m.st.SessionID = "s1"
	delta, _ := json.Marshal(map[string]any{
		"type":  "stream_event",
		"event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": "hi"}},
	})
	nm, _ := m.Update(streamFrameMsg{name: "chat", data: delta})
	if nm.(Model).st.Tail != "hi" {
		t.Fatalf("a live delta frame must accumulate the tail, got %q", nm.(Model).st.Tail)
	}
}

// ── the below-composer workflow panel's focus model (charter D14) ────────────

// liveWorkflowState builds a State carrying the REAL mid-run epic-cycle
// workflow fixture — the strip is visible (entry live).
func liveWorkflowState(t *testing.T) State {
	t.Helper()
	raw, err := os.ReadFile("testdata/rail_workflow_live.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	wf := decodeWorkflow(raw)
	if wf == nil {
		t.Fatal("fixture must decode a workflow")
	}
	return State{SessionID: "s1", Workflow: wf}
}

// wfTestModel is a conversation-screen model at a fixed clock.
func wfTestModel(t *testing.T, st State) Model {
	m := newTestModel(&fakeTransport{})
	m.screen = screenChat
	m.width, m.height = 80, 24
	m.scroll = -1
	m.st = st
	m.now = func() time.Time { return time.UnixMilli(1782767557221).Add(90 * time.Second) }
	return m
}

// TestArrowDownFocusesStripOnlyWhenVisible: with a live workflow and the
// transcript following the bottom, KeyDown hands focus to the strip; with no
// workflow, KeyDown keeps its scroll meaning and focus never moves (D14).
func TestArrowDownFocusesStripOnlyWhenVisible(t *testing.T) {
	// no workflow → KeyDown is pure scroll, focus stays on the composer
	m := wfTestModel(t, State{SessionID: "s1"})
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
	if got := nm.(Model); got.focus != focusComposer {
		t.Fatal("KeyDown without a strip must never move focus")
	}

	// live workflow + follow mode → KeyDown focuses the strip
	m = wfTestModel(t, liveWorkflowState(t))
	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
	got := nm.(Model)
	if got.focus != focusWorkflow {
		t.Fatal("KeyDown with a visible strip must focus it")
	}

	// arrow-up returns to the composer
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyUp})
	if nm.(Model).focus != focusComposer {
		t.Fatal("KeyUp on the collapsed strip must return focus to the composer")
	}

	// a scrolled reader keeps scroll semantics — KeyDown scrolls instead of
	// stealing focus until the transcript re-follows the bottom
	m = wfTestModel(t, liveWorkflowState(t))
	m.scroll = 0
	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
	if nm.(Model).focus != focusComposer {
		t.Fatal("KeyDown while scrolled must keep its scroll meaning")
	}
}

// TestWorkflowEnterExpandsEscCollapses: Enter on the focused strip opens the
// two-pane detail landed on the ACTIVE phase; up/down move the phase selection
// (clamped); Esc collapses and returns focus to the composer — it never
// interrupts from inside the panel.
func TestWorkflowEnterExpandsEscCollapses(t *testing.T) {
	m := wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow

	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if !got.wfExpanded {
		t.Fatal("Enter on the focused strip must expand the detail")
	}
	if got.wfPhase != 5 {
		t.Fatalf("expansion must land on the active phase (position 5), got %d", got.wfPhase)
	}

	// down moves the selection and clamps at the last phase
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
	got = nm.(Model)
	if got.wfPhase != 6 {
		t.Fatalf("KeyDown must select the next phase, got %d", got.wfPhase)
	}
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
	got = nm.(Model)
	if got.wfPhase != 6 {
		t.Fatalf("KeyDown must clamp at the last phase, got %d", got.wfPhase)
	}
	// up moves back
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyUp})
	got = nm.(Model)
	if got.wfPhase != 5 {
		t.Fatalf("KeyUp must select the previous phase, got %d", got.wfPhase)
	}

	// Esc collapses back to the composer and does NOT interrupt
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEsc})
	got = nm.(Model)
	if got.wfExpanded || got.focus != focusComposer {
		t.Fatalf("Esc must collapse and return to the composer, expanded=%v focus=%v",
			got.wfExpanded, got.focus)
	}
	if got.st.Phase == TurnInterrupting {
		t.Fatal("Esc inside the panel must never interrupt the turn")
	}
}

// TestWorkflowExpandRefetchNeverClearsLiveTail pins the D42 hydration
// refetch's charter-D77 semantics: expanding the workflow panel fires a
// turn-boundary-shaped GET that is NOT a settle boundary, so its landing must
// never clear a live streamed tail. The adversarial case is attach-mid-turn —
// this client saw no init frame, so Gen and TailGen are both still 0 and a
// zero-valued effect Gen would (wrongly) match; the emit site carries the -1
// sentinel instead. Reverting keys.go to `Gen: 0` (or dropping the field)
// makes this test fail.
func TestWorkflowExpandRefetchNeverClearsLiveTail(t *testing.T) {
	st := liveWorkflowState(t)
	st.Tail = "attached mid-turn, streaming"
	st.Phase = TurnStreaming // deltas arriving; no init observed → Gen==TailGen==0
	m := wfTestModel(t, st)
	m.focus = focusWorkflow

	nm, cmd := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if !got.wfExpanded {
		t.Fatal("Enter on the focused strip must expand the detail")
	}
	if cmd == nil {
		t.Fatal("the expand edge must fire the D42 refetch")
	}
	nm2, _ := got.Update(runCmd(cmd))
	if tail := nm2.(Model).st.Tail; tail != "attached mid-turn, streaming" {
		t.Fatalf("the hydration refetch must never clear a live tail, got %q", tail)
	}
}

// TestWorkflowKeyRunesAlwaysCompose is the D14 regression: typing while the
// panel holds focus lands in the composer and NEVER moves the panel selection
// (focus snaps home so the next Enter sends instead of expanding).
func TestWorkflowKeyRunesAlwaysCompose(t *testing.T) {
	m := wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfPhase = 3

	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("x")})
	got := nm.(Model)
	if got.input != "x" {
		t.Fatalf("KeyRunes must always compose, input=%q", got.input)
	}
	if got.wfPhase != 3 {
		t.Fatalf("typing must never move the panel selection, got %d", got.wfPhase)
	}
	if got.focus != focusComposer {
		t.Fatal("typing must snap focus back to the composer")
	}

	// The same law holds at the THIRD level (wsc-ad D30/D35): typing inside the
	// open agent-detail pane composes, snaps focus home, collapses BOTH levels,
	// and never moves the agent cursor — so the next Enter sends, not drills.
	m = wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfPhase = 5
	m.wfAgentDetail = true
	m.wfAgent = 2

	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("z")})
	got = nm.(Model)
	if got.input != "z" {
		t.Fatalf("KeyRunes at the detail depth must compose, input=%q", got.input)
	}
	if got.wfAgent != 2 {
		t.Fatalf("typing must never move the agent cursor, got %d", got.wfAgent)
	}
	if got.wfAgentDetail || got.focus != focusComposer {
		t.Fatalf("typing at the detail depth must snap home + collapse, detail=%v focus=%v",
			got.wfAgentDetail, got.focus)
	}
}

// TestWorkflowEnterDrillsAgentDetail is the D30/D35 Enter-then-arrow grammar for
// the third level: at depth-1 Enter drills into the selected phase's agent 0
// (that phase's agents all carry a signal in the live fixture); ↑/↓ then cycle
// the AGENT cursor clamped; esc pops one level back to the phase; a second esc
// returns to the composer. The depth-1 phase byte-lock is untouched — the phase
// selection only moves at depth-1, and a phase change resets the agent cursor.
func TestWorkflowEnterDrillsAgentDetail(t *testing.T) {
	m := wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow

	// Enter opens the phase detail on the active phase (position 5).
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if !got.wfExpanded || got.wfPhase != 5 || got.wfAgentDetail {
		t.Fatalf("first Enter must open the phase detail only, expanded=%v phase=%d detail=%v",
			got.wfExpanded, got.wfPhase, got.wfAgentDetail)
	}

	// Second Enter drills into agent 0 of the active phase (it has a signal).
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got = nm.(Model)
	if !got.wfAgentDetail || got.wfAgent != 0 {
		t.Fatalf("second Enter must drill into agent 0, detail=%v agent=%d",
			got.wfAgentDetail, got.wfAgent)
	}

	// ↓ cycles the AGENT cursor (the active phase at position 5 has 5 agents; the
	// cursor clamps at index 4, itself below the 8-agent paint cap).
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
	got = nm.(Model)
	if got.wfAgent != 1 {
		t.Fatalf("KeyDown must select the next agent, got %d", got.wfAgent)
	}
	if got.wfPhase != 5 {
		t.Fatalf("the phase must NOT move at the agent level, got %d", got.wfPhase)
	}
	// clamp at the last agent (5 agents → max index 4)
	for i := 0; i < 8; i++ {
		nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
		got = nm.(Model)
	}
	if got.wfAgent != 4 {
		t.Fatalf("KeyDown must clamp at the last agent (index 4), got %d", got.wfAgent)
	}
	// ↑ moves back
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyUp})
	got = nm.(Model)
	if got.wfAgent != 3 {
		t.Fatalf("KeyUp must select the previous agent, got %d", got.wfAgent)
	}

	// esc pops ONE level: back to the phase detail (still expanded).
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEsc})
	got = nm.(Model)
	if got.wfAgentDetail || !got.wfExpanded || got.focus != focusWorkflow {
		t.Fatalf("esc must pop to the phase detail, detail=%v expanded=%v focus=%v",
			got.wfAgentDetail, got.wfExpanded, got.focus)
	}

	// a phase change resets the agent cursor.
	got.wfAgentDetail = true
	got.wfAgent = 2
	got.wfAgentDetail = false // back at the phase level to move the phase
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyUp})
	got = nm.(Model)
	if got.wfPhase != 4 || got.wfAgent != 0 {
		t.Fatalf("a phase change must reset the agent cursor, phase=%d agent=%d",
			got.wfPhase, got.wfAgent)
	}

	// second esc returns to the composer.
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEsc})
	got = nm.(Model)
	if got.wfExpanded || got.focus != focusComposer {
		t.Fatalf("second esc must return to the composer, expanded=%v focus=%v",
			got.wfExpanded, got.focus)
	}
	if got.st.Phase == TurnInterrupting {
		t.Fatal("esc inside the panel must never interrupt the turn")
	}
}

// TestWorkflowLeftPopsAgentDetail: left pops the agent level like esc, but at
// shallower levels left is NOT the panel's key — it falls through to the composer
// (handled=false) so it never steals a key it has no verb for.
func TestWorkflowLeftPopsAgentDetail(t *testing.T) {
	m := wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfPhase = 5
	m.wfAgentDetail = true
	m.wfAgent = 1

	_, _, handled := m.handleWorkflowKey(tea.KeyMsg{Type: tea.KeyLeft})
	if !handled {
		t.Fatal("left inside the agent detail must be owned by the panel")
	}
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyLeft})
	got := nm.(Model)
	if got.wfAgentDetail || !got.wfExpanded {
		t.Fatalf("left must pop the agent detail to the phase level, detail=%v expanded=%v",
			got.wfAgentDetail, got.wfExpanded)
	}

	// at the phase level, left is unowned — it must NOT be claimed by the panel.
	if _, _, h := got.handleWorkflowKey(tea.KeyMsg{Type: tea.KeyLeft}); h {
		t.Fatal("left at the phase level must fall through, not be owned")
	}
}

// TestWorkflowEnterNoOpWithoutSignal: Enter at depth-1 on a phase whose agent 0
// carries NO detail signal is an honest no-op — the level never opens an empty
// pane (D27 structural gate).
func TestWorkflowEnterNoOpWithoutSignal(t *testing.T) {
	m := wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow
	m.wfExpanded = true
	// strip the signal fields off the active phase's agents so agentHasDetail is false
	for i := range m.st.Workflow.Nodes {
		n := &m.st.Workflow.Nodes[i]
		if n.Type == "workflow_agent" {
			n.PromptPreview, n.LastToolName, n.LastToolSummary, n.ResultPreview = nil, nil, nil, nil
			n.Attempt = 0
		}
	}
	j := journeyOf(m.st.Workflow)
	m.wfPhase = j.Active
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if got.wfAgentDetail {
		t.Fatal("Enter on a signal-less phase must be an honest no-op (no affordance)")
	}
}

// TestWorkflowFocusDropsWhenStripVanishes: a run that settles on a
// turn-boundary refetch takes its strip away — a key pressed afterwards finds
// the composer focused, never a dead zone.
func TestWorkflowFocusDropsWhenStripVanishes(t *testing.T) {
	m := wfTestModel(t, liveWorkflowState(t))
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.st.Workflow.Status = "completed" // the refetch settled the entry

	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyUp})
	got := nm.(Model)
	if got.focus != focusComposer || got.wfExpanded {
		t.Fatalf("a vanished strip must drop focus to the composer, focus=%v expanded=%v",
			got.focus, got.wfExpanded)
	}
}

// TestTailRefetchRehydratesWorkflow proves the D13 freshness seam: the
// turn-boundary GET's rail_snapshot re-decodes the workflow exactly where the
// rail re-decodes — no new SSE frame, no polling.
func TestTailRefetchRehydratesWorkflow(t *testing.T) {
	raw, err := os.ReadFile("testdata/rail_workflow_live.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	st, _ := Reduce(State{SessionID: "s1"}, TailFetchedEvent{
		Session: Session{ID: "s1", RailSnapshot: raw},
	}, time.Now())
	if st.Workflow == nil || st.Workflow.TaskID != "epccmplt" {
		t.Fatalf("the turn-boundary refetch must hydrate the workflow, got %+v", st.Workflow)
	}
}

// TestWorkflowExpandRefetchOnce is the D42 proof: the collapse→expand Enter
// edge fires exactly ONE FetchTailEffect (since=LastSeq) through execEffect —
// the drill and collapse edges fire none, and no polling/cadence exists (D13
// holds). A re-expand is a NEW edge and re-arms.
func TestWorkflowExpandRefetchOnce(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m.screen = screenChat
	m.width, m.height = 80, 24
	m.scroll = -1
	m.st = liveWorkflowState(t)
	m.st.LastSeq = 41
	m.now = func() time.Time { return time.UnixMilli(1782767557221).Add(90 * time.Second) }
	m.focus = focusWorkflow

	// the expand edge → exactly one tail fetch at the current cursor
	nm, cmd := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if !got.wfExpanded {
		t.Fatal("Enter must expand")
	}
	runCmd(cmd)
	if len(f.getCalls) != 1 || f.getCalls[0].since != 41 {
		t.Fatalf("the expand edge must refetch ONCE with since=LastSeq, got %+v", f.getCalls)
	}

	// the drill edge → none
	nm, cmd = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got = nm.(Model)
	runCmd(cmd)
	if !got.wfAgentDetail {
		t.Fatal("second Enter must drill")
	}
	if len(f.getCalls) != 1 {
		t.Fatalf("the drill edge must never refetch, got %+v", f.getCalls)
	}

	// the collapse edges → none
	nm, cmd = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEsc})
	got = nm.(Model)
	runCmd(cmd)
	nm, cmd = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEsc})
	got = nm.(Model)
	runCmd(cmd)
	if got.wfExpanded {
		t.Fatal("Esc twice must collapse")
	}
	if len(f.getCalls) != 1 {
		t.Fatalf("collapse edges must never refetch, got %+v", f.getCalls)
	}

	// a re-expand is a NEW edge — it re-arms
	got.focus = focusWorkflow
	nm, cmd = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	runCmd(cmd)
	if len(f.getCalls) != 2 {
		t.Fatalf("a re-expand edge must refetch again, got %+v", f.getCalls)
	}
	_ = nm
}

// TestWorkflowCursorReachesPinnedRunning is the D44 cursor-clamp proof on the
// synthetic 18-agent phase: the Up/Down range is the visibleAgents projection,
// so the pinned running agent at wire 17 (visible position 7) is reachable —
// before D44 the clamp stopped inside the first 8 WIRE agents and wire 9/17
// were unreachable. The detail pane at the landed cursor names the same agent.
func TestWorkflowCursorReachesPinnedRunning(t *testing.T) {
	m := wfTestModel(t, State{SessionID: "s1", Workflow: synthetic18Workflow()})
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfPhase = 0
	m.wfAgentDetail = true
	m.wfAgent = 0

	got := m
	for i := 0; i < 20; i++ {
		nm, _ := got.handleChatKey(tea.KeyMsg{Type: tea.KeyDown})
		got = nm.(Model)
	}
	if got.wfAgent != 7 {
		t.Fatalf("the cursor must clamp at the projection's last row (7), got %d", got.wfAgent)
	}
	pane := strings.Join(renderWorkflowAgentDetail(80, journeyOf(got.st.Workflow), got.now(), 0, got.wfAgent, true), "\n")
	if !strings.Contains(pane, "agent-17") {
		t.Fatalf("the landed cursor must name the pinned running agent at wire 17, got:\n%s", pane)
	}
}

// ── the needs-you cockpit (wsc-needs-you) ────────────────────────────────────

// liveApprovalCard is a live, answerable approval card row (request_id + pending).
func liveApprovalCard(seq int, rid string) Message {
	return Message{
		Seq: seq, Role: "approval", SourceMarkdown: "run rm -rf?",
		Metadata: map[string]any{"request_id": rid, "approval_status": "pending"},
	}
}

// needsYouState is a live workflow whose session is ALSO blocked on a pending
// answerable card — the needs-you cockpit state.
func needsYouState(t *testing.T) State {
	t.Helper()
	st := liveWorkflowState(t)
	st.Messages = []Message{liveApprovalCard(4, "req-42")}
	st.LastSeq = 4
	return st
}

// TestNeedsYouStateBothWays is the state-machine proof BOTH directions
// (criterion 0): a live workflow + a pending card flips the collapsed strip AND
// the expanded panel to the needs-you banner; answering the card (its
// approval_status leaving "pending") clears the state and the strip returns to
// its ordinary counter cluster. Truth from state the TUI already tracks — zero
// new wire.
func TestNeedsYouStateBothWays(t *testing.T) {
	m := wfTestModel(t, needsYouState(t))
	if !m.needsYou() {
		t.Fatal("a live workflow blocked on a pending card must be needs-you")
	}
	strip := strings.Join(m.workflowPanelLines(), "\n")
	if !strings.Contains(strip, "needs you") || !strings.Contains(strip, "⏸") {
		t.Fatalf("the collapsed strip must flip to the needs-you banner, got:\n%s", strip)
	}
	if strings.Contains(strip, "agents done") {
		t.Fatalf("the needs-you strip must REPLACE the counter cluster (single state), got:\n%s", strip)
	}

	// the expanded panel carries the SAME banner above the phase panes.
	me := wfTestModel(t, needsYouState(t))
	me.focus = focusWorkflow
	me.wfExpanded = true
	expanded := me.workflowPanelLines()
	joined := strings.Join(expanded, "\n")
	if !strings.Contains(joined, needsYouBanner) {
		t.Fatalf("the expanded panel must render the needs-you banner, got:\n%s", joined)
	}

	// clears on answer: the card leaving "pending" empties the answer ring, so
	// needs-you drops and the strip returns to the ordinary counters.
	ma := wfTestModel(t, needsYouState(t))
	ma.st.Messages[0].Metadata["approval_status"] = "allow"
	if ma.needsYou() {
		t.Fatal("an answered card must clear the needs-you state")
	}
	cleared := strings.Join(ma.workflowPanelLines(), "\n")
	if strings.Contains(cleared, "needs you") {
		t.Fatalf("a cleared strip must drop the needs-you banner, got:\n%s", cleared)
	}
	if !strings.Contains(cleared, "agents done") {
		t.Fatalf("a cleared strip must return to the agents-done counter, got:\n%s", cleared)
	}
}

// TestNeedsYouEnterJumps is criterion 1: Enter from the focused workflow strip in
// the needs-you state jumps the viewport (Home-style pinned scroll, clamped) to
// the focused pending card via the ONE shared transcript accumulator, then
// returns focus to the composer and collapses the panel — so the composer's Enter
// sends next. It also proves answerFocused now resets focus (the closed
// asymmetry) and that a plain composer Enter still sends.
func TestNeedsYouEnterJumps(t *testing.T) {
	// Card sits MID-transcript (10 rows before, 30 after) so the jump is a genuine
	// pinned-top ABOVE the bottom — not merely clamped to follow.
	st := liveWorkflowState(t)
	msgs := make([]Message, 0, 41)
	for i := 1; i <= 10; i++ {
		msgs = append(msgs, Message{Seq: i, Role: "user", SourceMarkdown: "scrollable line"})
	}
	msgs = append(msgs, liveApprovalCard(11, "req-42"))
	for i := 12; i <= 41; i++ {
		msgs = append(msgs, Message{Seq: i, Role: "user", SourceMarkdown: "scrollable line"})
	}
	st.Messages = msgs
	st.LastSeq = 41
	m := wfTestModel(t, st)
	m.focus = focusWorkflow

	// the shared accumulator locates the card's block start (no forked walk).
	_, start := m.transcriptBuild(m.width, "req-42")
	if start <= 0 {
		t.Fatal("the accumulator must locate the mid-transcript card's block start")
	}
	maxTop := m.maxScrollTop()
	want := start
	if want > maxTop {
		want = maxTop
	}
	if want >= maxTop {
		t.Fatalf("test setup: the card must pin ABOVE the bottom (start=%d maxTop=%d)", start, maxTop)
	}

	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if got.scroll != want {
		t.Fatalf("needs-you Enter must pin scroll Home-style to the card (clamped), got %d want %d", got.scroll, want)
	}
	if got.scroll < 0 {
		t.Fatal("needs-you Enter must leave follow mode (a pinned top, not -1)")
	}
	if got.focus != focusComposer {
		t.Fatalf("needs-you Enter must return focus to the composer, got %v", got.focus)
	}
	if got.wfExpanded || got.wfAgentDetail {
		t.Fatal("needs-you Enter must not open the panel detail")
	}

	// composer Enter still SENDS (clears the draft) once focus is back home.
	got.input = "hello"
	ns, _ := got.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	if ns.(Model).input != "" {
		t.Fatal("composer Enter after the jump must send (clearing the draft), not expand")
	}

	// answerFocused resets focus too — the closed asymmetry.
	ma := wfTestModel(t, needsYouState(t))
	ma.focus = focusWorkflow
	nm2, _ := ma.answerFocused("allow")
	if nm2.(Model).focus != focusComposer {
		t.Fatal("answering a card must return focus to the composer (asymmetry closed)")
	}
}

// TestNeedsYouEnterAheadOfExpand proves the needs-you branch sits AHEAD of the
// expand branch: with a pending gate present, Enter jumps rather than expanding
// the two-pane detail (the pending gate is the more urgent verb).
func TestNeedsYouEnterAheadOfExpand(t *testing.T) {
	m := wfTestModel(t, needsYouState(t))
	m.focus = focusWorkflow
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	if nm.(Model).wfExpanded {
		t.Fatal("needs-you Enter must jump, never expand the detail")
	}
	// without the gate, the same key expands as before (the ordinary grammar).
	m2 := wfTestModel(t, liveWorkflowState(t))
	m2.focus = focusWorkflow
	nm2, _ := m2.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	if !nm2.(Model).wfExpanded {
		t.Fatal("without a pending gate, Enter must still expand the detail")
	}
}

// TestIdleEscDetachesLikeCtrlB is the D51h contextual-Esc proof at the SHELL:
// with NO active turn, Esc takes the EXACT Ctrl+B leaveSession path — same
// screen flip, same cleared conversation, same continuity PATCH — with the
// server session left running (no Interrupt POST is ever made). Mid-turn Esc
// still interrupts (D11 unchanged).
func TestIdleEscDetachesLikeCtrlB(t *testing.T) {
	open := func(f *fakeTransport) Model {
		m := newTestModel(f)
		m = m.openSession(Session{ID: "s1", Title: "T", Mode: "plan"})
		m.input = "held draft"
		return m
	}

	fEsc := &fakeTransport{}
	nm, escCmd := open(fEsc).handleChatKey(tea.KeyMsg{Type: tea.KeyEsc})
	esc := nm.(Model)

	fB := &fakeTransport{}
	nm, bCmd := open(fB).handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlB})
	ctrlB := nm.(Model)

	// identical transition: back on the picker, conversation state cleared.
	if esc.screen != screenPicker || ctrlB.screen != screenPicker {
		t.Fatalf("idle Esc and Ctrl+B must both land on the herd, esc=%v ctrl+b=%v", esc.screen, ctrlB.screen)
	}
	if esc.st.SessionID != ctrlB.st.SessionID || esc.input != ctrlB.input ||
		esc.loading != ctrlB.loading || esc.focus != ctrlB.focus {
		t.Fatalf("idle Esc must match Ctrl+B's transition verbatim:\n esc    %+v input=%q\n ctrl+b %+v input=%q",
			esc.st, esc.input, ctrlB.st, ctrlB.input)
	}

	// both fire the SAME side effects: a continuity PATCH (the held draft) and
	// NO interrupt — the server session keeps running.
	runAllCmds(t, escCmd)
	runAllCmds(t, bCmd)
	if fEsc.patched["draft"] != "held draft" || fB.patched["draft"] != "held draft" {
		t.Fatalf("both paths must PATCH the draft, esc=%v ctrl+b=%v", fEsc.patched, fB.patched)
	}
	if fEsc.interrupted || fB.interrupted {
		t.Fatal("detach must never interrupt — the session stays running")
	}

	// mid-turn Esc still interrupts (D11): no detach, phase flips.
	fMid := &fakeTransport{}
	m := open(fMid)
	m.st.Phase = TurnStreaming
	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyEsc})
	mid := nm.(Model)
	if mid.screen != screenChat {
		t.Fatal("mid-turn Esc must NOT detach")
	}
	if mid.st.Phase != TurnInterrupting {
		t.Fatalf("mid-turn Esc must interrupt, got phase %v", mid.st.Phase)
	}
}

// runAllCmds executes a (possibly batched/sequenced) tea.Cmd tree so every
// side-effecting command actually fires against the fake transport.
func runAllCmds(t *testing.T, cmd tea.Cmd) {
	t.Helper()
	if cmd == nil {
		return
	}
	msg := cmd()
	switch batch := msg.(type) {
	case tea.BatchMsg:
		for _, c := range batch {
			runAllCmds(t, c)
		}
	case tea.MouseMsg, tea.KeyMsg:
	}
}

// TestHerdShellCursorFollowsResort proves the D52h cursor law THROUGH the
// shell: the picker cursor names a session id, so when a fleet flip resorts
// the herd, the display index moves WITH the session instead of staying on a
// row number.
func TestHerdShellCursorFollowsResort(t *testing.T) {
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	m := newTestModel(&fakeTransport{})
	m.now = func() time.Time { return now }

	nm, _ := m.Update(sessionsLoadedMsg{sessions: []SessionSummary{
		{ID: "a", Title: "A", AgentState: "working", AgentStateAt: now.Add(-time.Minute).Format(time.RFC3339)},
		{ID: "b", Title: "B", AgentState: "idle", AgentStateAt: now.Add(-2 * time.Minute).Format(time.RFC3339)},
	}})
	m = nm.(Model)

	// put the cursor on b (last row while idle)
	m.pickCursor = 2
	m = m.syncHerdCursorFromIndex()
	if m.herd.Cursor != "b" {
		t.Fatalf("cursor must record the session id, got %q", m.herd.Cursor)
	}

	// b flips blocked → resorts to the top; the cursor FOLLOWS b to index 1.
	nm, _ = m.Update(fleetFrameMsg{event: "state",
		data: []byte(`{"session_id":"b","agent_state":"blocked","ts":"` + now.Format(time.RFC3339) + `","title":null}`)})
	m = nm.(Model)
	if m.herd.Cursor != "b" {
		t.Fatalf("the cursor must still name b, got %q", m.herd.Cursor)
	}
	if m.pickCursor != 1 {
		t.Fatalf("the display index must follow b to the top (1), got %d", m.pickCursor)
	}
	// and Enter opens exactly the session under the cursor.
	f := &fakeTransport{}
	m.tr = f
	_, cmd := m.openPickerRow()
	runAllCmds(t, cmd)
	if len(f.getCalls) != 1 || f.getCalls[0].id != "b" {
		t.Fatalf("Enter must open the followed session, got %+v", f.getCalls)
	}
}

// TestFleetErrDegradesToNotice proves the D54h give-up law: a terminal fleet
// stream failure lands one honest notice — never an error screen, never a
// wiped roster.
func TestFleetErrDegradesToNotice(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	nm, _ := m.Update(sessionsLoadedMsg{sessions: []SessionSummary{{ID: "a", Title: "A"}}})
	m = nm.(Model)
	nm, _ = m.Update(fleetErrMsg{err: errString("boom")})
	m = nm.(Model)
	if m.fleetNotice == "" || !strings.Contains(m.fleetNotice, "boom") {
		t.Fatalf("the give-up must surface as a notice, got %q", m.fleetNotice)
	}
	if len(m.sessions) != 1 || m.pickErr != "" {
		t.Fatal("the give-up must not wipe the roster or fake a load error")
	}
	if !strings.Contains(m.renderPicker(), "herd stream lost") {
		t.Fatal("the notice must actually paint on the herd home")
	}
}

// TestFleetFrameReducesWhileAttached is the D54h never-paused law: a fleet
// frame arriving while a conversation is foregrounded STILL reduces the herd
// (m.screen gates rendering only), so a detach shows current truth with zero
// flash or refetch.
func TestFleetFrameReducesWhileAttached(t *testing.T) {
	m := newTestModel(&fakeTransport{})
	nm, _ := m.Update(sessionsLoadedMsg{sessions: []SessionSummary{{ID: "a", Title: "A", AgentState: "working"}}})
	m = nm.(Model)
	m = m.openSession(Session{ID: "other", Title: "attached"})
	if m.screen != screenChat {
		t.Fatal("precondition: attached")
	}
	nm, _ = m.Update(fleetFrameMsg{event: "state",
		data: []byte(`{"session_id":"a","agent_state":"blocked","ts":"2026-07-18T12:00:00Z","title":null}`)})
	m = nm.(Model)
	if m.herd.Rows["a"].AgentState != "blocked" {
		t.Fatalf("the herd must keep reducing while attached, got %+v", m.herd.Rows["a"])
	}
}

// TestToggleModeFlipsPlanAutopilot proves the ctrl+p grammar: plan ⇄ auto,
// odd raw modes land on plan first (the safe direction), both the display
// truth and the D14 continuity field move together, and no session means no
// patch.
func TestToggleModeFlipsPlanAutopilot(t *testing.T) {
	m := Model{st: State{SessionID: "s1", Mode: "plan"}}
	m2, cmd := m.toggleMode()
	if m2.st.Mode != "auto" || m2.mode != "auto" {
		t.Fatalf("plan must flip to auto (display+continuity), got st=%q m=%q", m2.st.Mode, m2.mode)
	}
	if cmd == nil {
		t.Fatal("toggle must emit the persist/steer PATCH command")
	}
	if !strings.Contains(m2.st.Notice, "Autopilot") {
		t.Fatalf("notice must announce Autopilot, got %q", m2.st.Notice)
	}

	m3, _ := m2.toggleMode()
	if m3.st.Mode != "plan" {
		t.Fatalf("auto must flip back to plan, got %q", m3.st.Mode)
	}

	// An odd raw mode (resumed acceptEdits, armed bypass, …) lands on plan.
	odd := Model{st: State{SessionID: "s1", Mode: "bypassPermissions"}}
	odd2, _ := odd.toggleMode()
	if odd2.st.Mode != "plan" {
		t.Fatalf("odd mode must land on plan first, got %q", odd2.st.Mode)
	}

	// No open session — inert.
	if _, cmd := (Model{}).toggleMode(); cmd != nil {
		t.Fatal("no session must mean no patch command")
	}
}
