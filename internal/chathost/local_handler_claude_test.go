package chathost

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
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
	if mode == "interrupt" || mode == "error_result" {
		write(map[string]any{"type": "stream_event", "event": map[string]any{
			"type": "content_block_delta", "index": 0.0,
			"delta": map[string]any{"type": "text_delta", "text": "partial "},
		}})
	}
	if mode == "interrupt" {
		// Wait for the host's interrupt control request, acknowledge it, then end
		// the way the real claude did on 2026-11-13: an error result.
		for {
			var message map[string]any
			if err := decoder.Decode(&message); err != nil {
				os.Exit(3)
			}
			request, _ := message["request"].(map[string]any)
			if message["type"] == "control_request" && request["subtype"] == "interrupt" {
				write(map[string]any{"type": "control_response", "response": map[string]any{
					"subtype": "success", "request_id": message["request_id"],
				}})
				break
			}
		}
	}
	if mode == "interrupt" || mode == "error_result" {
		write(claudeInterruptedResult())
	}
	os.Exit(0)
}

// claudeInterruptedResult is the result object the real claude sent after an
// interrupt (task-bb50d873c868f411), byte for byte in the fields that matter.
func claudeInterruptedResult() map[string]any {
	return map[string]any{
		"type": "result", "subtype": "error_during_execution", "is_error": true,
		"errors": []any{"[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"},
	}
}

// runClaudeHelperTurn runs one send_turn against the helper and returns every
// event the host emitted. With interrupt, it presses Stop once text has streamed.
func runClaudeHelperTurn(t *testing.T, mode string, interrupt bool) []map[string]any {
	t.Helper()
	installClaudeTurnHelper(t, mode)
	handler := NewLocalHandler([]string{t.TempDir()})
	sessionID := "session-" + mode
	var mu sync.Mutex
	var events []map[string]any
	streamed := make(chan struct{})
	var once sync.Once
	done := make(chan error, 1)
	go func() {
		done <- handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
			"provider": "claude", "operation": "send_turn", "session_id": sessionID,
			"payload": map[string]any{"cwd": handler.ApprovedRoots[0], "content": "write a lot", "mode": "plan"},
		}}, func(event map[string]any) error {
			mu.Lock()
			events = append(events, event)
			mu.Unlock()
			if event["kind"] == "text_delta" {
				once.Do(func() { close(streamed) })
			}
			return nil
		})
	}()
	if interrupt {
		select {
		case <-streamed:
		case err := <-done:
			t.Fatalf("turn ended before any text streamed: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("no text streamed")
		}
		var control []map[string]any
		if err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
			"provider": "claude", "operation": "interrupt", "session_id": sessionID,
		}}, func(event map[string]any) error { control = append(control, event); return nil }); err != nil {
			t.Fatalf("interrupt: %v", err)
		}
		if len(control) != 1 || control[0]["kind"] != "control_completed" {
			t.Fatalf("interrupt emitted %#v; want one control_completed", control)
		}
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("send_turn Handle() = %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("send_turn never ended")
	}
	mu.Lock()
	defer mu.Unlock()
	return events
}

// TestRunClaudeInterruptedTurnEndsAsInterruptedNotError: Stop on a streaming
// Claude turn. Claude answers the interrupt with an error result; before the
// fix the host passed that on as kind "error", so a client could not tell "the
// person pressed stop" from "the run failed" (task-bb50d873c868f411).
func TestRunClaudeInterruptedTurnEndsAsInterruptedNotError(t *testing.T) {
	events := runClaudeHelperTurn(t, "interrupt", true)
	last := events[len(events)-1]
	if last["kind"] != "turn_completed" || last["terminal_state"] != "interrupted" {
		t.Fatalf("terminal event = %#v; want kind turn_completed, terminal_state interrupted", last)
	}
	for _, event := range events {
		if event["kind"] == "error" {
			t.Fatalf("an interrupted turn emitted an error event: %#v", event)
		}
	}
}

// TestRunClaudeErrorResultWithoutInterruptStaysError is the control: the same
// error result with no Stop asked is a real failure and must stay kind error.
func TestRunClaudeErrorResultWithoutInterruptStaysError(t *testing.T) {
	events := runClaudeHelperTurn(t, "error_result", false)
	last := events[len(events)-1]
	if last["kind"] != "error" || last["terminal_state"] != "failed" {
		t.Fatalf("terminal event = %#v; want kind error, terminal_state failed", last)
	}
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
