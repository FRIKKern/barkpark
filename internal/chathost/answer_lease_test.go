package chathost

import (
	"bytes"
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// task-754fd6f9a890e75e: an approval answer reaches only the run that asked
// it. Run B holds the session; an answer to run A's ask must not reach B.

type bufferCloser struct{ bytes.Buffer }

func (*bufferCloser) Close() error { return nil }

// activeCodexRun registers a codex run for session s1 under leaseID, with one
// ask of its own pending under id "0". Codex numbers asks per process, so a
// newer run's first ask has the same id as the older run's.
func activeCodexRun(t *testing.T, leaseID string) (*LocalHandler, *activeLocalSession, *bufferCloser) {
	t.Helper()
	stdin := &bufferCloser{}
	session := newActiveLocalSession("codex", nil, stdin)
	session.leaseID = leaseID
	session.approvals["0"] = approvalRequest{id: float64(0), method: "item/commandExecution/requestApproval"}
	h := NewLocalHandler(nil)
	if err := h.register("s1", session); err != nil {
		t.Fatal(err)
	}
	return h, session, stdin
}

func answer(t *testing.T, h *LocalHandler, payload map[string]any) []map[string]any {
	t.Helper()
	var emitted []map[string]any
	err := h.Handle(context.Background(), RemoteCommand{
		LeaseID: "lease-answer",
		Command: map[string]any{
			"operation": "answer_approval", "provider": "codex", "session_id": "s1",
			"approval_id": "0", "payload": payload,
		},
	}, func(event map[string]any) error {
		emitted = append(emitted, event)
		return nil
	})
	if err != nil {
		// A failed answer closes its lease with an error, and that close ends
		// the active run's turn on the server.
		t.Fatalf("an answer must never fail the active run's turn: %v", err)
	}
	return emitted
}

func TestAnAnswerToAnotherRunsAskIsNotDeliveredToTheActiveRun(t *testing.T) {
	h, session, stdin := activeCodexRun(t, "lease-B")

	emitted := answer(t, h, map[string]any{"decision": "allow", "asked_lease_id": "lease-A"})

	if stdin.Len() != 0 {
		t.Fatalf("run B was answered with run A's decision: %s", stdin.String())
	}
	if _, pending := session.approvals["0"]; !pending {
		t.Fatal("run B's own ask 0 was taken by an answer to run A's ask 0")
	}
	if len(emitted) != 1 || emitted[0]["kind"] != "control_completed" {
		t.Fatalf("want one control_completed, got %#v", emitted)
	}
	if refused, _ := emitted[0]["refused"].(string); !strings.Contains(refused, "lease-A") {
		t.Fatalf("the acknowledgement must say why nothing was sent: %#v", emitted[0])
	}
}

func TestAnAnswerToTheActiveRunsAskIsDelivered(t *testing.T) {
	h, session, stdin := activeCodexRun(t, "lease-B")

	emitted := answer(t, h, map[string]any{"decision": "allow", "asked_lease_id": "lease-B"})

	if !strings.Contains(stdin.String(), `"decision":"accept"`) {
		t.Fatalf("run B's own answer was not sent: %q", stdin.String())
	}
	if _, pending := session.approvals["0"]; pending {
		t.Fatal("run B's ask is still pending after its answer")
	}
	if len(emitted) != 1 || emitted[0]["refused"] != nil {
		t.Fatalf("want a plain control_completed, got %#v", emitted)
	}
}

// A server older than this change names no lease: the answer goes to the
// active run, as before.
func TestAnAnswerThatNamesNoLeaseIsDeliveredAsBefore(t *testing.T) {
	h, _, stdin := activeCodexRun(t, "lease-B")

	answer(t, h, map[string]any{"decision": "allow"})

	if !strings.Contains(stdin.String(), `"decision":"accept"`) {
		t.Fatalf("an answer from an older server was not sent: %q", stdin.String())
	}
}

// A real run records the lease it serves: an answer named for that lease
// reaches the run (the helper has no such ask, so Claude's "unknown approval"
// is the proof it got there), and one named for any other lease does not.
func TestARunningClaudeTurnTakesOnlyAnswersNamedForItsLease(t *testing.T) {
	installClaudeTurnHelper(t, "interrupt")
	handler := NewLocalHandler([]string{t.TempDir()})
	streamed := make(chan struct{})
	var once sync.Once
	done := make(chan error, 1)
	go func() {
		done <- handler.Handle(context.Background(), RemoteCommand{LeaseID: "lease-A", Command: map[string]any{
			"provider": "claude", "operation": "send_turn", "session_id": "s-lease",
			"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "write a lot", "mode": "plan"},
		}}, func(event map[string]any) error {
			if event["kind"] == "text_delta" {
				once.Do(func() { close(streamed) })
			}
			return nil
		})
	}()
	select {
	case <-streamed:
	case err := <-done:
		t.Fatalf("turn ended before any text streamed: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("no text streamed")
	}

	control := func(operation string, payload map[string]any) ([]map[string]any, error) {
		var emitted []map[string]any
		err := handler.Handle(context.Background(), RemoteCommand{LeaseID: "lease-" + operation, Command: map[string]any{
			"provider": "claude", "operation": operation, "session_id": "s-lease",
			"approval_id": "ask-x", "payload": payload,
		}}, func(event map[string]any) error { emitted = append(emitted, event); return nil })
		return emitted, err
	}

	if _, err := control("answer_approval", map[string]any{"decision": "allow", "asked_lease_id": "lease-A"}); err == nil ||
		!strings.Contains(err.Error(), "unknown Claude approval") {
		t.Fatalf("an answer named for this run's lease must reach the run, got %v", err)
	}
	emitted, err := control("answer_approval", map[string]any{"decision": "allow", "asked_lease_id": "lease-Z"})
	if err != nil || len(emitted) != 1 || emitted[0]["refused"] == nil {
		t.Fatalf("an answer named for another lease must be refused, got %#v, %v", emitted, err)
	}

	if _, err := control("interrupt", map[string]any{}); err != nil {
		t.Fatalf("interrupt: %v", err)
	}
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("send_turn never ended")
	}
}
