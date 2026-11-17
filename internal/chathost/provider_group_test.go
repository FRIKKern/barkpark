//go:build unix

package chathost

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A child the provider started (a tool, a shell command) ends with the turn,
// on every path the turn ends by (task-00d0c5e8ff5dc5d1). Before, the host
// killed the provider alone and the child ran on, reparented, on the person's
// computer. The fake providers below start a child that writes its pid and
// then a heartbeat file; the fake waits for the first heartbeat before it goes
// on, so the child is alive when the turn ends.

// TestGroupProviderHelperProcess is the fake claude or codex (a go-test re-exec
// stub). BARKPARK_GROUP_HELPER=claude|codex picks it, BARKPARK_GROUP_DIR is the
// folder for the child's files and BARKPARK_GROUP_MODE is "complete" (the turn
// completes) or "block" (it waits until the host ends it).
func TestGroupProviderHelperProcess(t *testing.T) {
	provider := os.Getenv("BARKPARK_GROUP_HELPER")
	if provider == "" {
		return
	}
	dir, mode := os.Getenv("BARKPARK_GROUP_DIR"), os.Getenv("BARKPARK_GROUP_MODE")
	decoder := json.NewDecoder(bufio.NewReader(os.Stdin))
	encoder := json.NewEncoder(os.Stdout)
	write := func(value map[string]any) { _ = encoder.Encode(value) }
	startChild := func() {
		// About a minute of heartbeats, so a child the host fails to end does
		// not outlive the test run for long.
		child := exec.Command("sh", "-c", `echo $$ > "$1/child.pid"; i=0; while [ $i -lt 3000 ]; do : > "$1/heartbeat"; sleep 0.02; i=$((i+1)); done`, "sh", dir)
		if mode == "block" {
			// As a tool's shell can: the child holds the provider's stdout,
			// so killing the provider alone never ends the host's read of it.
			child.Stdout = os.Stdout
		}
		if err := child.Start(); err != nil {
			os.Exit(5)
		}
		if !waitForFile(filepath.Join(dir, "heartbeat"), 20*time.Second) {
			os.Exit(6)
		}
	}
	block := func() {
		for {
			var message map[string]any
			if decoder.Decode(&message) != nil {
				os.Exit(0)
			}
		}
	}

	if provider == "claude" {
		var input map[string]any
		_ = decoder.Decode(&input)
		startChild()
		write(map[string]any{"type": "system", "subtype": "init", "session_id": "claude-thread"})
		if mode == "block" {
			block()
		}
		write(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start"}})
		write(map[string]any{"type": "result", "subtype": "success", "is_error": false})
		os.Exit(0)
	}
	for {
		var request map[string]any
		if decoder.Decode(&request) != nil {
			os.Exit(1)
		}
		switch request["method"] {
		case "initialize":
			write(map[string]any{"id": request["id"], "result": map[string]any{}})
		case "thread/start":
			write(map[string]any{"id": request["id"], "result": map[string]any{"thread": map[string]any{"id": "codex-thread"}}})
		case "turn/start":
			startChild()
			write(map[string]any{"id": request["id"], "result": map[string]any{"turn": map[string]any{"id": "codex-turn"}}})
			write(map[string]any{"method": "turn/started", "params": map[string]any{"threadId": "codex-thread", "turn": map[string]any{"id": "codex-turn"}}})
			if mode == "block" {
				block()
			}
			write(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "codex-thread", "turn": map[string]any{"id": "codex-turn", "status": "completed"}}})
			os.Exit(0)
		}
	}
}

// installGroupHelper puts the fake provider on PATH and returns the folder
// its child writes to.
func installGroupHelper(t *testing.T, provider, mode string) string {
	t.Helper()
	dir, bin := t.TempDir(), t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_GROUP_HELPER=%s BARKPARK_GROUP_DIR=%q BARKPARK_GROUP_MODE=%s exec %q -test.run=TestGroupProviderHelperProcess -- \"$@\"\n",
		provider, dir, mode, binary)
	if err := os.WriteFile(filepath.Join(bin, provider), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	// A child the host failed to end is ended here, so a red run leaves
	// nothing behind.
	t.Cleanup(func() {
		if pid, ok := childPid(dir); ok {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return dir
}

func childPid(dir string) (int, bool) {
	raw, err := os.ReadFile(filepath.Join(dir, "child.pid"))
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	return pid, err == nil
}

// assertChildEnded checks, once the turn has returned, that the provider's
// child is gone. A killed child is reaped by init, not by the host, so it can
// answer kill -0 as a zombie for a moment: the check waits for ESRCH, with a
// backstop that only a child left running reaches.
func assertChildEnded(t *testing.T, dir string) {
	t.Helper()
	pid, ok := childPid(dir)
	if !ok {
		t.Fatal("the provider's child never wrote its pid")
	}
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
		if errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
			return
		}
	}
	t.Fatalf("the provider's child (pid %d) is still running 5 s after the turn ended", pid)
}

func groupTurn(provider, sessionID, cwd string) RemoteCommand {
	return RemoteCommand{Command: map[string]any{
		"provider": provider, "operation": "send_turn", "session_id": sessionID,
		"payload": map[string]any{"cwd": cwd, "content": "start a tool", "mode": "plan"},
	}}
}

// The host ends the turn by its context: the person pressed stop, the lease
// was revoked, the host is shutting down, or the Runner closes the turn.
func TestEndingATurnByItsContextEndsTheProvidersChild(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			dir := installGroupHelper(t, provider, "block")
			handler := NewLocalHandler([]string{t.TempDir()})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				done <- handler.Handle(ctx, groupTurn(provider, "session-group-"+provider, handler.ApprovedRoots[0]), func(event map[string]any) error {
					// The fake's first event comes after its child's first heartbeat.
					cancel()
					return nil
				})
			}()
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("Handle() = nil; want the turn ended by its context")
				}
			case <-time.After(20 * time.Second):
				t.Fatal("the turn did not end after its context was cancelled")
			}
			assertChildEnded(t, dir)
		})
	}
}

// The host ends the turn because an event was refused: a refusal for good, or
// the first-event bound (an emit error either way).
func TestEndingATurnOnARefusedEventEndsTheProvidersChild(t *testing.T) {
	dir := installGroupHelper(t, "claude", "block")
	handler := NewLocalHandler([]string{t.TempDir()})
	refused := errors.New("event refused")
	err := handler.Handle(context.Background(), groupTurn("claude", "session-group-refused", handler.ApprovedRoots[0]),
		func(map[string]any) error { return refused })
	if !errors.Is(err, refused) {
		t.Fatalf("Handle() = %v; want the refusal", err)
	}
	assertChildEnded(t, dir)
}

// The "close" control ends a running turn.
func TestClosingASessionEndsTheProvidersChild(t *testing.T) {
	dir := installGroupHelper(t, "claude", "block")
	handler := NewLocalHandler([]string{t.TempDir()})
	const sessionID = "session-group-close"
	started := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- handler.Handle(context.Background(), groupTurn("claude", sessionID, handler.ApprovedRoots[0]), func(map[string]any) error {
			close(started)
			return nil
		})
	}()
	select {
	case <-started:
	case err := <-done:
		t.Fatalf("the turn ended before its first event: %v", err)
	case <-time.After(20 * time.Second):
		t.Fatal("the turn never started")
	}
	var control []map[string]any
	if err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "claude", "operation": "close", "session_id": sessionID,
	}}, func(event map[string]any) error { control = append(control, event); return nil }); err != nil {
		t.Fatalf("close: %v", err)
	}
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("the turn did not end after close")
	}
	assertChildEnded(t, dir)
}

// A turn that completes leaves nothing of the provider running either.
func TestACompletedTurnLeavesNoChildOfTheProviderRunning(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			dir := installGroupHelper(t, provider, "complete")
			handler := NewLocalHandler([]string{t.TempDir()})
			var kinds []any
			err := handler.Handle(context.Background(), groupTurn(provider, "session-group-done-"+provider, handler.ApprovedRoots[0]),
				func(event map[string]any) error { kinds = append(kinds, event["kind"]); return nil })
			if err != nil {
				t.Fatalf("Handle() = %v; want a completed turn (events %v)", err, kinds)
			}
			if len(kinds) == 0 || kinds[len(kinds)-1] != "turn_completed" {
				t.Fatalf("events %v; want the turn to end with turn_completed", kinds)
			}
			assertChildEnded(t, dir)
		})
	}
}

// End to end: the first event meets 503s past the first-event bound, the
// Runner closes the turn, and the provider's child is gone too.
func TestTheFirstEventBoundEndsTheProvidersChild(t *testing.T) {
	dir := installGroupHelper(t, "claude", "block")
	root := t.TempDir()
	server := &leaseServer{
		command:            firstEventTurn(t, root),
		refuseKind:         map[string]int{"session_started": http.StatusServiceUnavailable},
		firstEventDeadline: 100 * time.Millisecond,
		closeDeadline:      2 * time.Second,
		runFor:             20 * time.Second,
	}
	ctx, stop := startRunner(t, server, NewLocalHandler([]string{root}))
	defer stop()
	if !waitCompleted(ctx, server) {
		t.Fatal("the turn was never closed")
	}
	assertChildEnded(t, dir)
}
