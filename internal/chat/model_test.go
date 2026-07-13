package chat

import (
	"context"
	"encoding/json"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// model_test.go — the shell proofs, driven against a fake Transport (no
// terminal, no server). The load-bearing one is D14/D15 continuity: the
// full-session GET hydrates the writable set and the draft, and quit/switch
// PATCHes it back — the roundtrip that keeps a conversation resumable.

// fakeTransport records every call and returns canned data. It is the whole IO
// seam, so the shell drives deterministically.
type fakeTransport struct {
	summaries []SessionSummary
	full      Session
	created   Session

	getCalls    []getCall
	patched     map[string]any
	patchedID   string
	sent        []string
	interrupted bool
	listErr     error
	getErr      error
}

type getCall struct {
	id    string
	since int
}

func (f *fakeTransport) CreateSession() (Session, error) { return f.created, nil }
func (f *fakeTransport) ListSessions() ([]SessionSummary, error) {
	return f.summaries, f.listErr
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
func (f *fakeTransport) Events(ctx context.Context, id string, lastSeq int, onFrame func(string, []byte)) error {
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
