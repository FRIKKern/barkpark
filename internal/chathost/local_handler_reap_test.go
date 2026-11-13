package chathost

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
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

// A codex turn that completed stays a good turn when a grandchild still holds
// codex's stderr after codex exits 0: Wait then answers exec.ErrWaitDelay, and
// before the fix Handle returned it, so the Runner published an error terminal
// after a good reply (review of #26164).
func TestRunCodexCompletedTurnIgnoresAStderrHeldPastWaitDelay(t *testing.T) {
	previous := providerWaitDelay
	providerWaitDelay = 200 * time.Millisecond
	t.Cleanup(func() { providerWaitDelay = previous })

	dir := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_PROVIDER_HELPER=codex BARKPARK_HELPER_STDERR_CHILD=1 exec %q -test.run=TestProviderHelperProcess -- \"$@\"\n", binary)
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	handler := NewLocalHandler([]string{t.TempDir()})
	var kinds []any
	err = handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "codex", "operation": "send_turn", "session_id": "session-stderr-held",
		"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "prove it"},
	}}, func(event map[string]any) error {
		kinds = append(kinds, event["kind"])
		return nil
	})
	if err != nil {
		t.Fatalf("Handle() = %v; want nil: the turn completed (events %v)", err, kinds)
	}
	if len(kinds) == 0 || kinds[len(kinds)-1] != "turn_completed" {
		t.Fatalf("events %v; want the turn to end with turn_completed", kinds)
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
