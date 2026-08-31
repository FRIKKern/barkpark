package chathost

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRunClaudePublishesTerminalErrorOnPrematureExit is the regression for the
// hang: the claude subprocess exits 0 without ever emitting a stream-json
// record of type "result". Before the fix, runClaude returned nil in this
// shape, so Runner.start (runner.go) published NO terminal frame and
// the chat turn hung forever.
func TestRunClaudePublishesTerminalErrorOnPrematureExit(t *testing.T) {
	installClaudeTurnHelper(t, "no_result")
	handler := NewLocalHandler([]string{t.TempDir()})
	cwd := handler.ApprovedRoots[0]
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": "session-premature-exit",
		"payload": map[string]any{"cwd": cwd, "content": "prove it", "mode": "plan"},
	}}, func(event map[string]any) error { return nil })
	if err == nil {
		t.Fatal("Handle() = nil; want a non-nil error when claude exits 0 without a result record (Runner.start only publishes a terminal frame on a non-nil Handle error)")
	}
	if !strings.Contains(err.Error(), "exited before turn completion") {
		t.Fatalf("Handle() error = %q; want it to name the premature exit the way runCodex's sibling guard does", err.Error())
	}
}

// TestRunClaudeReturnsNilWhenResultRecordSeen is the mirror case: the happy
// path, where claude DOES emit a result record before exiting 0, must stay
// unchanged and return nil.
func TestRunClaudeReturnsNilWhenResultRecordSeen(t *testing.T) {
	installClaudeTurnHelper(t, "with_result")
	handler := NewLocalHandler([]string{t.TempDir()})
	cwd := handler.ApprovedRoots[0]
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": "session-clean-result",
		"payload": map[string]any{"cwd": cwd, "content": "prove it", "mode": "plan"},
	}}, func(event map[string]any) error { return nil })
	if err != nil {
		t.Fatalf("Handle() = %v; want nil on the unchanged happy path (a result record was seen)", err)
	}
}

// TestClaudeTurnHelperProcess is a go-test re-exec stub (same technique as
// TestProviderHelperProcess in local_handler_test.go): installClaudeTurnHelper
// wires it up as the "claude" binary on PATH. BARKPARK_CLAUDE_TURN_HELPER
// selects whether it ever emits a {"type":"result"} record before exiting 0.
func TestClaudeTurnHelperProcess(t *testing.T) {
	mode := os.Getenv("BARKPARK_CLAUDE_TURN_HELPER")
	if mode == "" {
		return
	}
	decoder := json.NewDecoder(bufio.NewReader(os.Stdin))
	var input map[string]any
	_ = decoder.Decode(&input)

	encoder := json.NewEncoder(os.Stdout)
	write := func(value map[string]any) { _ = encoder.Encode(value) }

	write(map[string]any{"type": "system", "subtype": "init", "session_id": "claude-thread"})
	write(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start"}})
	if mode == "with_result" {
		write(map[string]any{"type": "result", "subtype": "success", "is_error": false})
	}
	os.Exit(0)
}

func installClaudeTurnHelper(t *testing.T, mode string) {
	t.Helper()
	dir := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_CLAUDE_TURN_HELPER=%s exec %q -test.run=TestClaudeTurnHelperProcess -- \"$@\"\n", mode, binary)
	path := filepath.Join(dir, "claude")
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}
