package chathost

import (
	"context"
	"errors"
	"os/exec"
	"sync/atomic"
	"testing"
)

// A turn whose emit fails (the Runner gave up publishing an event) returns
// early. The provider child must still be waited for: without cmd.Wait() it
// stays a zombie and its stdout and stderr pipes stay open until the host exits
// (task-248ddc24af006c04). cmd.ProcessState is set only by Wait, and Wait is
// what closes the pipes, so a nil ProcessState after Handle returns is the leak.

func TestRunClaudeWaitsForTheChildAfterAnEmitError(t *testing.T) {
	installProviderHelper(t, "claude")
	cmd := handleWithFailingEmit(t, "claude", "session-reap-claude")
	if cmd.ProcessState == nil {
		t.Fatal("claude was not waited for after an emit error: it is left a zombie with its pipes open")
	}
}

func TestRunCodexWaitsForTheChildAfterAnEmitError(t *testing.T) {
	installProviderHelper(t, "codex")
	cmd := handleWithFailingEmit(t, "codex", "session-reap-codex")
	if cmd.ProcessState == nil {
		t.Fatal("codex was not waited for after an emit error: it is left a zombie with its pipes open")
	}
}

// handleWithFailingEmit runs one send_turn whose first emit fails, and returns
// the provider's *exec.Cmd, read from the active session during that emit.
func handleWithFailingEmit(t *testing.T, provider, sessionID string) *exec.Cmd {
	t.Helper()
	handler := NewLocalHandler([]string{t.TempDir()})
	refused := errors.New("event refused")
	var cmd atomic.Pointer[exec.Cmd]
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": provider, "operation": "send_turn", "session_id": sessionID,
		"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "prove it", "mode": "plan"},
	}}, func(event map[string]any) error {
		if session := handler.active(sessionID); session != nil {
			cmd.CompareAndSwap(nil, session.cmd)
		}
		return refused
	})
	if !errors.Is(err, refused) {
		t.Fatalf("Handle() = %v; want the emit error", err)
	}
	if cmd.Load() == nil {
		t.Fatal("emit ran without an active session, so the child could not be read")
	}
	return cmd.Load()
}
