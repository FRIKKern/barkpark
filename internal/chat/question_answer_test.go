package chat

import (
	"errors"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// ── ct-bl-question-updatedinput ──────────────────────────────────────────────
//
// The D28 deferral said an AskUserQuestion card answers as a blanket allow,
// because D22 forbids a caller-supplied updatedInput. The named failure mode
// that fixed: a question row rendered its chips and then reduced every one of
// them to "yes". These tests pin the closing shape — the TUI names the option the
// operator picked, and it can name NOTHING the server did not persist.

// questionCard is a pending AskUserQuestion row carrying the server-held ask the
// TUI reads its chips from (metadata.input, verbatim from persist_approval_ask).
func questionCard() Message {
	return Message{
		Seq:            7,
		Role:           "question",
		SourceMarkdown: "AskUserQuestion",
		Metadata: map[string]any{
			"request_id":      "q-1",
			"tool_name":       "AskUserQuestion",
			"approval_status": "pending",
			"input": map[string]any{
				"questions": []any{
					map[string]any{
						"question": "Which color?",
						"header":   "Color",
						"options": []any{
							map[string]any{"label": "Blue", "description": "the cold one"},
							map[string]any{"label": "Red"},
						},
					},
					map[string]any{
						"question":    "Which toppings?",
						"multiSelect": true,
						"options":     []any{"Cheese", "Basil"},
					},
				},
			},
		},
	}
}

func modelWithQuestion(f *fakeTransport) Model {
	m := newTestModel(f)
	m.st.SessionID = "sess-1"
	m.st.Messages = []Message{questionCard()}
	return m
}

// TestCardChoicesFlattensTheServerHeldAsk proves the TUI reads its option list
// from the row the server persisted — never from anything it invented — and that
// a card with no decodable ask yields NO choices (so it keeps the plain
// allow/deny path instead of breaking).
func TestCardChoicesFlattensTheServerHeldAsk(t *testing.T) {
	got := cardChoices(questionCard())
	want := []questionChoice{
		{Question: "Which color?", Label: "Blue"},
		{Question: "Which color?", Label: "Red"},
		{Question: "Which toppings?", Label: "Cheese"},
		{Question: "Which toppings?", Label: "Basil"},
	}
	if len(got) != len(want) {
		t.Fatalf("choices = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("choice %d = %v, want %v", i, got[i], want[i])
		}
	}

	// Every non-question card offers nothing — and the fixture carries the SAME
	// ask metadata a question row does, so what excludes it is the ROLE, not an
	// absent input. (The first cut of this assertion used a metadata-less card and
	// was vacuous: deleting the role filter left it green.)
	for _, role := range []string{"approval", "plan"} {
		card := questionCard()
		card.Role = role
		if c := cardChoices(card); len(c) != 0 {
			t.Fatalf("%s card must offer no question choices even carrying an ask, got %v", role, c)
		}
	}
	bare := questionCard()
	bare.Metadata = map[string]any{"request_id": "q-1", "approval_status": "pending"}
	if c := cardChoices(bare); len(c) != 0 {
		t.Fatalf("a question row with no stored ask must offer no choices, got %v", c)
	}
}

// TestCtrlAOnAQuestionCardSubmitsThePickedOption is the heart of the slice: the
// allow keystroke on a question card POSTs the SPECIFIC label, keyed by the
// question string, through the /answer transport verb — not a blanket approval.
func TestCtrlAOnAQuestionCardSubmitsThePickedOption(t *testing.T) {
	f := &fakeTransport{}
	m := modelWithQuestion(f)

	nm, cmd := m.answerFocused("allow")
	got := nm.(Model)
	if len(got.st.AnswerInFlight) != 1 || got.st.AnswerInFlight["q-1"] != "allow" {
		t.Fatalf("the card must badge as answering, got %v", got.st.AnswerInFlight)
	}
	msg := runCmd(cmd)
	done, ok := msg.(answerDoneMsg)
	if !ok || done.requestID != "q-1" || done.err != nil {
		t.Fatalf("expected a clean answerDoneMsg for q-1, got %#v", msg)
	}

	if len(f.approvals) != 0 {
		t.Fatalf("a question answer must NOT ride the allow/deny approval route, got %v", f.approvals)
	}
	if len(f.answers) != 1 {
		t.Fatalf("expected exactly one /answer POST, got %v", f.answers)
	}
	call := f.answers[0]
	if call.id != "sess-1" || call.requestID != "q-1" {
		t.Fatalf("answer POST addressed %q/%q, want sess-1/q-1", call.id, call.requestID)
	}
	if len(call.answers) != 1 || call.answers["Which color?"] != "Blue" {
		t.Fatalf("answers = %v, want the first option keyed by its question string", call.answers)
	}
}

// TestOptionCursorWalksAndWraps proves ←/→ move the pick across the FLATTENED
// choices (so a multi-question ask is fully reachable) and wrap at both ends,
// and that the submitted answer follows the cursor.
func TestOptionCursorWalksAndWraps(t *testing.T) {
	f := &fakeTransport{}
	m := modelWithQuestion(f)

	// → three times: Blue → Red → Cheese → Basil.
	for i := 0; i < 3; i++ {
		nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyRight})
		m = nm.(Model)
	}
	choice, ok := m.focusedChoice()
	if !ok || choice.Question != "Which toppings?" || choice.Label != "Basil" {
		t.Fatalf("after 3 rights the pick is %v, want Which toppings?/Basil", choice)
	}

	// One more wraps back to the first choice.
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyRight})
	m = nm.(Model)
	if choice, _ := m.focusedChoice(); choice.Label != "Blue" {
		t.Fatalf("the cursor must wrap to the first option, got %v", choice)
	}

	// ← from the first wraps to the last.
	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyLeft})
	m = nm.(Model)
	if choice, _ := m.focusedChoice(); choice.Label != "Basil" {
		t.Fatalf("left from the first option must wrap to the last, got %v", choice)
	}

	// And the POST carries THAT pick, under its own question string.
	nm, cmd := m.answerFocused("allow")
	_ = nm
	runCmd(cmd)
	if len(f.answers) != 1 || f.answers[0].answers["Which toppings?"] != "Basil" {
		t.Fatalf("the POST must carry the picked option, got %v", f.answers)
	}
}

// TestArrowsAreInertWithoutAQuestionCard proves the new keys did not steal
// anything: with no answerable question card, ←/→ are the no-ops they always
// were, and the composer stays untouched.
func TestArrowsAreInertWithoutAQuestionCard(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m.st.SessionID = "sess-1"
	m.st.Messages = []Message{pendingCard("approval")}
	m.input = "hello"

	for _, k := range []tea.KeyType{tea.KeyLeft, tea.KeyRight} {
		nm, cmd := m.handleChatKey(tea.KeyMsg{Type: k})
		got := nm.(Model)
		if cmd != nil {
			t.Fatalf("arrow on a non-question card must issue no command")
		}
		if got.input != "hello" || got.optionCursor != 0 {
			t.Fatalf("arrow must not touch the composer or the cursor, got %q/%d", got.input, got.optionCursor)
		}
	}
}

// TestApprovalAndDenyKeepTheAllowDenyRoute proves the /answer widening did NOT
// leak onto the allow/deny hot path: an approval card allow, and a question card
// DENY, both still POST the plain decision (D22's boundary is untouched, and
// dismissing questions stays an honest verb).
func TestApprovalAndDenyKeepTheAllowDenyRoute(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m.st.SessionID = "sess-1"
	// An approval card carrying a question-shaped ask: the role, not a missing
	// input, is what keeps it on the allow/deny route.
	approval := questionCard()
	approval.Role = "approval"
	m.st.Messages = []Message{approval}

	_, cmd := m.answerFocused("allow")
	runCmd(cmd)

	mq := modelWithQuestion(f)
	_, cmd = mq.answerFocused("deny")
	runCmd(cmd)

	if len(f.answers) != 0 {
		t.Fatalf("neither an approval allow nor a question deny may hit /answer, got %v", f.answers)
	}
	if len(f.approvals) != 2 || f.approvals[0].decision != "allow" || f.approvals[1].decision != "deny" {
		t.Fatalf("expected an approval allow then a question deny on /approval, got %v", f.approvals)
	}
}

// TestQuestionCardWithNoAskFallsBackToBlanketAllow proves the degrade path: a
// legacy or mid-persist question row (no decodable ask) keeps the answer path it
// has today rather than losing it.
func TestQuestionCardWithNoAskFallsBackToBlanketAllow(t *testing.T) {
	f := &fakeTransport{}
	m := newTestModel(f)
	m.st.SessionID = "sess-1"
	bare := questionCard()
	bare.Metadata = map[string]any{"request_id": "q-1", "approval_status": "pending"}
	m.st.Messages = []Message{bare}

	_, cmd := m.answerFocused("allow")
	runCmd(cmd)

	if len(f.answers) != 0 {
		t.Fatalf("a question row with no ask has nothing to pick — it must not POST /answer, got %v", f.answers)
	}
	if len(f.approvals) != 1 || f.approvals[0].decision != "allow" {
		t.Fatalf("it must fall back to the blanket allow, got %v", f.approvals)
	}
}

// TestQuestionAnswerReduceIsInertOnAnEmptyAnswer pins the reducer's own fence:
// nothing to say means no POST, so a stray keystroke can never resolve a card
// with an empty answers map.
func TestQuestionAnswerReduceIsInertOnAnEmptyAnswer(t *testing.T) {
	cases := []QuestionAnswerEvent{
		{RequestID: "", Answers: map[string]any{"q": "a"}},
		{RequestID: "q-1", Answers: nil},
		{RequestID: "q-1", Answers: map[string]any{}},
	}
	for _, ev := range cases {
		st, effects := Reduce(State{}, ev, t0)
		if len(effects) != 0 {
			t.Fatalf("%v must emit no effect, got %v", ev, effects)
		}
		if len(st.AnswerInFlight) != 0 {
			t.Fatalf("%v must not badge a card in flight, got %v", ev, st.AnswerInFlight)
		}
	}
}

// TestAnswerFailureSurfacesAndLeavesTheCardPending proves the /answer error leg
// rides the SAME settle grammar as an approval failure: the badge clears, the
// notice is honest, and the card stays answerable so the operator can retry.
func TestAnswerFailureSurfacesAndLeavesTheCardPending(t *testing.T) {
	st := State{AnswerInFlight: map[string]string{"q-1": "allow"}}
	st, effects := Reduce(st, AnsweredEvent{RequestID: "q-1", Err: errors.New("boom")}, t0)
	if len(effects) != 0 {
		t.Fatalf("a failed answer must not refetch, got %v", effects)
	}
	if _, still := st.AnswerInFlight["q-1"]; still {
		t.Fatalf("the in-flight badge must clear on failure")
	}
	if !strings.Contains(st.Notice, "answer failed") {
		t.Fatalf("the failure must surface honestly, got %q", st.Notice)
	}
}

// TestFocusedQuestionCardNamesThePickedOption proves the footer and the POST
// agree: the affordance names the exact label ctrl+a would send, so the operator
// is never told one thing and charged another.
func TestFocusedQuestionCardNamesThePickedOption(t *testing.T) {
	f := &fakeTransport{}
	m := modelWithQuestion(f)
	m.width = 100

	out := strings.Join(m.transcriptLines(100), "\n")
	if !strings.Contains(out, `ctrl+a answer "Blue"`) {
		t.Fatalf("the focused question card must name the picked option, got:\n%s", out)
	}
	if !strings.Contains(out, "←/→ pick") {
		t.Fatalf("the footer must advertise the option keys, got:\n%s", out)
	}

	// Move the pick; the footer follows.
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyRight})
	out = strings.Join(nm.(Model).transcriptLines(100), "\n")
	if !strings.Contains(out, `ctrl+a answer "Red"`) {
		t.Fatalf("the footer must follow the cursor, got:\n%s", out)
	}

	// An approval card keeps the plain verb — the new footer is question-only.
	f2 := &fakeTransport{}
	ma := newTestModel(f2)
	approval := questionCard()
	approval.Role = "approval"
	ma.st.Messages = []Message{approval}
	ma.width = 100
	aout := strings.Join(ma.transcriptLines(100), "\n")
	if strings.Contains(aout, "←/→ pick") {
		t.Fatalf("an approval card must not advertise option keys, got:\n%s", aout)
	}
}
