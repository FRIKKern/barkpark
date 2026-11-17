package chat

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// The server answers an approval for an ask that is no longer pending with a
// 409 `conflict` carrying `details.approval_status` (#26895). The TUI must not
// call that "answer failed": it refetches, says what happened to the ask in
// plain words, and the refetched row resolves the stale card
// (task-6d6dc151c1dab808).
func settledAnswerErr(t *testing.T, status string) error {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"error":{"code":"conflict","message":"approval req-1 is `+status+
			`; the answer was not sent","details":{"approval_status":"`+status+
			`"},"hint":"This ask is no longer pending. Reload the session to see its current state."}}`)
	}))
	t.Cleanup(srv.Close)

	err := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}).
		RespondChatApproval("s1", "req-1", "allow")
	if err == nil {
		t.Fatal("a 409 must come back as an error")
	}
	return err
}

func TestAnswerOnACanceledAskRefetchesAndSaysSo(t *testing.T) {
	st := State{
		SessionID:      "s1",
		Messages:       []Message{pendingCardRow(3, "approval", "req-1")},
		LastSeq:        3,
		AnswerInFlight: map[string]string{"req-1": "allow"},
	}

	st, effs := drive(st, t0, AnsweredEvent{RequestID: "req-1", Err: settledAnswerErr(t, "canceled")})

	f, ok := hasFetchTail(effs)
	if !ok || f.SinceSeq != 0 {
		t.Fatalf("an answer to a settled ask must refetch the session (SinceSeq 0), got %+v", effs)
	}
	if strings.Contains(st.Notice, "answer failed") {
		t.Fatalf("a settled ask is not a failed answer, got notice %q", st.Notice)
	}
	if !strings.Contains(st.Notice, "canceled") || !strings.Contains(st.Notice, "not sent") {
		t.Fatalf("the notice must say the ask was canceled and nothing was sent, got %q", st.Notice)
	}
	if _, still := st.AnswerInFlight["req-1"]; still {
		t.Fatal("the in-flight badge must clear on a settled ask")
	}

	// The refetch carries the row as the server holds it: the card resolves.
	canceled := pendingCardRow(3, "approval", "req-1")
	canceled.Metadata["approval_status"] = "canceled"
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1", Messages: []Message{canceled}}, Gen: f.Gen})
	if cardPending(st.Messages, "req-1") {
		t.Fatal("the stale card must not stay pending after the refetch")
	}
	if !strings.Contains(st.Notice, "canceled") {
		t.Fatalf("the notice must still say what happened after the refetch lands, got %q", st.Notice)
	}
}

func TestAnswerOnAnAlreadyAnsweredAskSaysItWasAnswered(t *testing.T) {
	st := State{SessionID: "s1", AnswerInFlight: map[string]string{"req-1": "deny"}}
	st, effs := drive(st, t0, AnsweredEvent{RequestID: "req-1", Err: settledAnswerErr(t, "allowed")})
	if _, ok := hasFetchTail(effs); !ok {
		t.Fatalf("an answer to a settled ask must refetch, got %+v", effs)
	}
	if !strings.Contains(st.Notice, "already answered") || !strings.Contains(st.Notice, "allowed") {
		t.Fatalf("the notice must say the ask was already answered (allowed), got %q", st.Notice)
	}
}

// POST /answer answers 404 for a question that is no longer pending (answered
// or canceled), the same not-found oracle as a missing session (rev26731 on
// #26895). The TUI refetches and says so without claiming which it was.
func TestAnswerToAQuestionNoLongerPendingRefetchesAndSaysSo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"error":{"code":"not_found","message":"chat session not found"}}`)
	}))
	defer srv.Close()
	err := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}).
		AnswerChatQuestion("s1", "q-1", map[string]any{"Which?": "A"})
	if err == nil {
		t.Fatal("a 404 must come back as an error")
	}

	st := State{SessionID: "s1", AnswerInFlight: map[string]string{"q-1": "allow"}}
	st, effs := drive(st, t0, AnsweredEvent{RequestID: "q-1", Err: err})
	f, ok := hasFetchTail(effs)
	if !ok || f.SinceSeq != 0 {
		t.Fatalf("an answer to a question no longer pending must refetch (SinceSeq 0), got %+v", effs)
	}
	if strings.Contains(st.Notice, "answer failed") || !strings.Contains(st.Notice, "no longer waiting") ||
		!strings.Contains(st.Notice, "not sent") {
		t.Fatalf("the notice must say the question is no longer waiting and nothing was sent, got %q", st.Notice)
	}
	if _, still := st.AnswerInFlight["q-1"]; still {
		t.Fatal("the in-flight badge must clear")
	}
}

// A 409 that does not name the ask's status is not this case: it stays an
// honest failure, with no refetch.
func TestAConflictWithoutAnApprovalStatusIsStillAFailedAnswer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"error":{"code":"conflict","message":"something else"}}`)
	}))
	defer srv.Close()
	err := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}).RespondChatApproval("s1", "req-1", "allow")

	st := State{SessionID: "s1", AnswerInFlight: map[string]string{"req-1": "allow"}}
	st, effs := drive(st, t0, AnsweredEvent{RequestID: "req-1", Err: err})
	if len(effs) != 0 || !strings.Contains(st.Notice, "answer failed") {
		t.Fatalf("an unrelated 409 must stay a failed answer, got notice %q effects %+v", st.Notice, effs)
	}
}
