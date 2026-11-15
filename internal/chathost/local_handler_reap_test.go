package chathost

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"syscall"
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
	installHeldStderrCodex(t, "")

	handler := NewLocalHandler([]string{t.TempDir()})
	handler.WaitDelay = 200 * time.Millisecond
	if kinds, err := handleCodexTurn(handler); err != nil {
		t.Fatalf("Handle() = %v; want nil: the turn completed (events %v)", err, kinds)
	} else if len(kinds) == 0 || kinds[len(kinds)-1] != "turn_completed" {
		t.Fatalf("events %v; want the turn to end with turn_completed", kinds)
	}
}

// A handler that sets no WaitDelay (as main.go's) still bounds the wait for a
// held stderr, at the 5 s default: with no bound, the turn stays open as long
// as the grandchild lives (30 s here, an MCP server's whole life in use). It
// waits out the real default, so it costs about 5 s.
func TestRunCodexBoundsAHeldStderrAtTheDefaultWaitDelay(t *testing.T) {
	record := filepath.Join(t.TempDir(), "grandchild-pid")
	installHeldStderrCodex(t, "BARKPARK_HELPER_STDERR_SECONDS=30 BARKPARK_HELPER_STDERR_PID="+record)
	t.Cleanup(func() {
		if raw, err := os.ReadFile(record); err == nil {
			if pid, err := strconv.Atoi(string(raw)); err == nil {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})

	handler := NewLocalHandler([]string{t.TempDir()})
	type result struct {
		kinds []any
		err   error
	}
	done := make(chan result, 1)
	started := time.Now()
	go func() {
		kinds, err := handleCodexTurn(handler)
		done <- result{kinds, err}
	}()
	select {
	case got := <-done:
		elapsed := time.Since(started)
		if got.err != nil || len(got.kinds) == 0 || got.kinds[len(got.kinds)-1] != "turn_completed" {
			t.Fatalf("Handle() = %v, events %v; want a completed turn", got.err, got.kinds)
		}
		if elapsed < defaultProviderWaitDelay-500*time.Millisecond {
			t.Fatalf("the turn ended after %v; want about the %v default: a shorter bound is in effect", elapsed, defaultProviderWaitDelay)
		}
	case <-time.After(defaultProviderWaitDelay + 10*time.Second):
		t.Fatalf("the turn was still open after %v: a handler with no WaitDelay set waits for the grandchild that holds stderr", defaultProviderWaitDelay+10*time.Second)
	}
}

// The default is what production gets: NewLocalHandler and
// StatusLabelerFromEnv set no WaitDelay.
func TestProviderWaitDelayDefaultsToFiveSeconds(t *testing.T) {
	if defaultProviderWaitDelay != 5*time.Second {
		t.Fatalf("defaultProviderWaitDelay = %v; want 5s", defaultProviderWaitDelay)
	}
	for own, want := range map[time.Duration]time.Duration{0: 5 * time.Second, -time.Second: 5 * time.Second, 200 * time.Millisecond: 200 * time.Millisecond} {
		if got := providerWaitDelay(own); got != want {
			t.Fatalf("providerWaitDelay(%v) = %v; want %v", own, got, want)
		}
	}
	if handler := NewLocalHandler(nil); handler.WaitDelay != 0 {
		t.Fatalf("NewLocalHandler sets WaitDelay %v; want 0 (the default)", handler.WaitDelay)
	}
	labeler, ok := StatusLabelerFromEnv(func(string) string { return "" }).(*ClaudeStatusLabeler)
	if !ok || labeler.WaitDelay != 0 {
		t.Fatalf("StatusLabelerFromEnv = %#v; want a ClaudeStatusLabeler with WaitDelay 0 (the default)", labeler)
	}
}

// installHeldStderrCodex puts a codex on PATH whose turn completes and which
// leaves a grandchild holding its stderr. env: extra NAME=value settings.
func installHeldStderrCodex(t *testing.T, env string) {
	t.Helper()
	dir := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_PROVIDER_HELPER=codex BARKPARK_HELPER_STDERR_CHILD=1 %s exec %q -test.run=TestProviderHelperProcess -- \"$@\"\n", env, binary)
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func handleCodexTurn(handler *LocalHandler) ([]any, error) {
	var kinds []any
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "codex", "operation": "send_turn", "session_id": "session-stderr-held",
		"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "prove it"},
	}}, func(event map[string]any) error {
		kinds = append(kinds, event["kind"])
		return nil
	})
	return kinds, err
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
