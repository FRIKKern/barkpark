package chathost

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTextContentSupportsChatBlocks(t *testing.T) {
	got := textContent([]any{
		map[string]any{"type": "text", "text": "first"},
		map[string]any{"type": "image", "source": map[string]any{}},
		map[string]any{"type": "text", "text": "second"},
	})
	if got != "first\nsecond" {
		t.Fatalf("textContent() = %q", got)
	}
}

func TestProviderEnvDropsUnrelatedHostSecrets(t *testing.T) {
	t.Setenv("BARKPARK_TEST_SECRET", "must-not-cross")
	for _, pair := range providerEnv(map[string]any{}) {
		if strings.HasPrefix(pair, "BARKPARK_TEST_SECRET=") {
			t.Fatal("provider inherited an unrelated host secret")
		}
	}
}

func TestProviderEnvAddsOnlyFencedTaskHands(t *testing.T) {
	env := providerEnv(map[string]any{"task_env": map[string]any{
		"BARKPARK_API_TOKEN": "scoped-token",
		"BARKPARK_API_URL":   "https://barkpark.test",
		"BARKPARK_WORKER_ID": "codex-chat-session-1",
		"DATABASE_URL":       "must-not-cross",
	}})
	joined := strings.Join(env, "\n")
	for _, expected := range []string{"BARKPARK_API_TOKEN=scoped-token", "BARKPARK_API_URL=https://barkpark.test", "BARKPARK_WORKER_ID=codex-chat-session-1"} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("missing task hand %q in %q", expected, joined)
		}
	}
	if strings.Contains(joined, "DATABASE_URL=must-not-cross") {
		t.Fatal("unapproved task environment value crossed the host boundary")
	}
}

func TestPoisonedTaskHandsNeverConfigureMCP(t *testing.T) {
	payload := map[string]any{"task_env": map[string]any{
		"BARKPARK_API_TOKEN": "__BARKPARK_CHAT_NO_TASK_HANDS__",
		"BARKPARK_API_URL":   "https://barkpark.test",
	}}
	if config := codexTaskConfig(payload); config != nil {
		t.Fatalf("Codex MCP config = %#v", config)
	}
	path, cleanup, err := writeClaudeMCPConfig(payload)
	defer cleanup()
	if err != nil || path != "" {
		t.Fatalf("Claude MCP config path = %q, err = %v", path, err)
	}
	if !strings.Contains(strings.Join(providerEnv(payload), "\n"), "BARKPARK_API_TOKEN=__BARKPARK_CHAT_NO_TASK_HANDS__") {
		t.Fatal("provider process did not receive the credential fallback poison")
	}
}

func TestClaudePermissionModeRequiresLiveBypassArming(t *testing.T) {
	if mode, err := claudePermissionMode(map[string]any{"mode": "bypassPermissions"}); err != nil || mode != "plan" {
		t.Fatalf("unarmed bypass = %q, %v", mode, err)
	}
	if mode, err := claudePermissionMode(map[string]any{"mode": "bypassPermissions", "bypass_armed": true}); err != nil || mode != "bypassPermissions" {
		t.Fatalf("armed bypass = %q, %v", mode, err)
	}
	if _, err := claudePermissionMode(map[string]any{"mode": "invented"}); err == nil {
		t.Fatal("unknown permission mode must fail closed")
	}
}

func TestLocalHandlerRejectsControlWithoutActiveTurn(t *testing.T) {
	handler := NewLocalHandler(nil)
	err := handler.Handle(context.Background(), RemoteCommand{
		Command: map[string]any{"operation": "steer", "provider": "codex"},
	}, func(value map[string]any) error {
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "has no active turn") {
		t.Fatalf("expected inactive-session control error, got %v", err)
	}
}

func TestClaudeEventMapsSessionDeltaAndCompletion(t *testing.T) {
	started := claudeEvent(map[string]any{"type": "system", "subtype": "init", "session_id": "session-123"})
	if started["kind"] != "session_started" || started["provider_session_id"] != "session-123" {
		t.Fatalf("unexpected session event: %#v", started)
	}

	delta := claudeEvent(map[string]any{
		"type": "stream_event",
		"event": map[string]any{
			"type":  "content_block_delta",
			"delta": map[string]any{"type": "text_delta", "text": "hello"},
		},
	})
	if delta["kind"] != "text_delta" || delta["delta"] != "hello" {
		t.Fatalf("unexpected delta event: %#v", delta)
	}

	completed := claudeEvent(map[string]any{"type": "result", "subtype": "success", "is_error": false})
	if completed["kind"] != "turn_completed" {
		t.Fatalf("unexpected completion event: %#v", completed)
	}
}

func TestCodexEventMapsThreadAndAgentMessage(t *testing.T) {
	started := codexEvent(map[string]any{
		"type":      "thread.started",
		"thread_id": "thread-123",
	})
	if started["kind"] != "session_started" || started["provider_session_id"] != "thread-123" {
		t.Fatalf("unexpected session event: %#v", started)
	}

	delta := codexEvent(map[string]any{
		"type": "item.completed",
		"item": map[string]any{
			"type": "agent_message",
			"text": "done",
		},
	})
	if delta["kind"] != "text_delta" || delta["delta"] != "done" {
		t.Fatalf("unexpected delta event: %#v", delta)
	}
}

func TestCodexEventPreservesSubagentItems(t *testing.T) {
	event := codexEvent(map[string]any{
		"type": "item.started",
		"item": map[string]any{
			"id":                "collab-1",
			"type":              "collabAgentToolCall",
			"receiverThreadIds": []any{"child-1"},
		},
	})
	if event["kind"] != "item_started" || event["item_id"] != "collab-1" {
		t.Fatalf("unexpected subagent event: %#v", event)
	}
}

func TestCodexEventMapsTerminalStates(t *testing.T) {
	completed := codexEvent(map[string]any{"type": "turn.completed"})
	if completed["kind"] != "turn_completed" || completed["terminal_state"] != "completed" {
		t.Fatalf("unexpected completion event: %#v", completed)
	}

	failed := codexEvent(map[string]any{"type": "turn.failed", "error": "boom"})
	if failed["kind"] != "error" {
		t.Fatalf("unexpected failure event: %#v", failed)
	}
}

func TestActiveCodexSessionSteersInterruptsAndAnswersApproval(t *testing.T) {
	reader, writer := io.Pipe()
	session := newActiveLocalSession("codex", nil, writer)
	session.setThreadID("thread-1")
	session.setTurnID("turn-1")
	decoder := json.NewDecoder(reader)

	steerDone := make(chan error, 1)
	go func() {
		steerDone <- session.control(context.Background(), "steer", map[string]any{
			"payload": map[string]any{"content": "focus on tests"},
		})
	}()
	var steer map[string]any
	if err := decoder.Decode(&steer); err != nil {
		t.Fatal(err)
	}
	if steer["method"] != "turn/steer" || nestedString(steer, "params", "expectedTurnId") != "turn-1" {
		t.Fatalf("unexpected steer request: %#v", steer)
	}
	session.codexMessage(map[string]any{"id": steer["id"], "result": map[string]any{}})
	if err := <-steerDone; err != nil {
		t.Fatal(err)
	}

	session.mu.Lock()
	session.approvals["91"] = approvalRequest{id: float64(91), method: "item/commandExecution/requestApproval"}
	session.mu.Unlock()
	approvalDone := make(chan error, 1)
	go func() {
		approvalDone <- session.control(context.Background(), "answer_approval", map[string]any{
			"approval_id": "91", "payload": map[string]any{"decision": "allow"},
		})
	}()
	var approval map[string]any
	if err := decoder.Decode(&approval); err != nil {
		t.Fatal(err)
	}
	if approval["id"] != float64(91) || nestedString(approval, "result", "decision") != "accept" {
		t.Fatalf("unexpected approval response: %#v", approval)
	}
	if err := <-approvalDone; err != nil {
		t.Fatal(err)
	}

	interruptDone := make(chan error, 1)
	go func() {
		interruptDone <- session.control(context.Background(), "interrupt", map[string]any{"payload": map[string]any{}})
	}()
	var interrupt map[string]any
	if err := decoder.Decode(&interrupt); err != nil {
		t.Fatal(err)
	}
	if interrupt["method"] != "turn/interrupt" || nestedString(interrupt, "params", "turnId") != "turn-1" {
		t.Fatalf("unexpected interrupt request: %#v", interrupt)
	}
	session.codexMessage(map[string]any{"id": interrupt["id"], "result": map[string]any{}})
	if err := <-interruptDone; err != nil {
		t.Fatal(err)
	}
	_ = reader.Close()
}

func TestActiveClaudeSessionSteersInterruptsAndAnswersApproval(t *testing.T) {
	reader, writer := io.Pipe()
	session := newActiveLocalSession("claude", nil, writer)
	decoder := json.NewDecoder(reader)

	steerDone := make(chan error, 1)
	go func() {
		steerDone <- session.control(context.Background(), "steer", map[string]any{
			"payload": map[string]any{"mode": "acceptEdits"},
		})
	}()
	var steer map[string]any
	if err := decoder.Decode(&steer); err != nil {
		t.Fatal(err)
	}
	if nestedString(steer, "request", "subtype") != "set_permission_mode" || nestedString(steer, "request", "mode") != "acceptEdits" {
		t.Fatalf("unexpected Claude steer: %#v", steer)
	}
	session.claudeMessage(map[string]any{"type": "control_response", "response": map[string]any{
		"request_id": steer["request_id"], "response": map[string]any{"mode": "acceptEdits"},
	}})
	if err := <-steerDone; err != nil {
		t.Fatal(err)
	}

	session.claudeMessage(map[string]any{
		"type": "control_request", "request_id": "ask-1",
		"request": map[string]any{"subtype": "can_use_tool", "tool_name": "Write", "input": map[string]any{"path": "a.txt"}},
	})
	approvalDone := make(chan error, 1)
	go func() {
		approvalDone <- session.control(context.Background(), "answer_approval", map[string]any{
			"approval_id": "ask-1", "payload": map[string]any{"decision": "allow"},
		})
	}()
	var approval map[string]any
	if err := decoder.Decode(&approval); err != nil {
		t.Fatal(err)
	}
	if nestedString(approval, "response", "response", "behavior") != "allow" || nestedString(approval, "response", "response", "updatedInput", "path") != "a.txt" {
		t.Fatalf("unexpected Claude approval: %#v", approval)
	}
	if err := <-approvalDone; err != nil {
		t.Fatal(err)
	}
	_ = reader.Close()
}

func TestClaudeMCPConfigIsPrivateAndCleanedUp(t *testing.T) {
	path, cleanup, err := writeClaudeMCPConfig(map[string]any{"task_env": map[string]any{
		"BARKPARK_API_TOKEN": "bpcs_scoped-token",
		"BARKPARK_API_URL":   "https://barkpark.test",
		"BARKPARK_WORKER_ID": "claude-chat-session-1",
	}})
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("MCP config mode = %o", info.Mode().Perm())
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), "bpcs_scoped-token") {
		t.Fatalf("MCP config missing scoped token: %v", err)
	}
	cleanup()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return
		}
	}
	t.Fatal("MCP config was not cleaned up")
}

func TestLocalHandlerRunsCodexAppServerEndToEnd(t *testing.T) {
	installProviderHelper(t, "codex")
	handler := NewLocalHandler([]string{t.TempDir()})
	cwd := handler.ApprovedRoots[0]
	var events []map[string]any
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "codex", "operation": "send_turn", "session_id": "session-1",
		"payload": map[string]any{"cwd": cwd, "content": "prove it", "developer_instructions": "Be Task obsessed"},
	}}, func(event map[string]any) error {
		events = append(events, event)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	assertEventKinds(t, events, "session_started", "turn_started", "text_delta", "item_started", "item_completed", "turn_completed")
	if events[2]["delta"] != "codex works" {
		t.Fatalf("unexpected Codex delta: %#v", events[2])
	}
}

func TestLocalHandlerRunsClaudeStreamJSONEndToEnd(t *testing.T) {
	installProviderHelper(t, "claude")
	handler := NewLocalHandler([]string{t.TempDir()})
	cwd := handler.ApprovedRoots[0]
	var events []map[string]any
	err := handler.Handle(context.Background(), RemoteCommand{Command: map[string]any{
		"provider": "claude", "operation": "send_turn", "session_id": "session-2",
		"payload": map[string]any{"cwd": cwd, "content": "prove it", "mode": "plan"},
	}}, func(event map[string]any) error {
		events = append(events, event)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	assertEventKinds(t, events, "session_started", "turn_started", "text_delta", "turn_completed")
	if events[2]["delta"] != "claude works" {
		t.Fatalf("unexpected Claude delta: %#v", events[2])
	}
}

func TestProviderHelperProcess(t *testing.T) {
	provider := os.Getenv("BARKPARK_PROVIDER_HELPER")
	if provider == "" {
		return
	}
	decoder := json.NewDecoder(bufio.NewReader(os.Stdin))
	encoder := json.NewEncoder(os.Stdout)
	write := func(value map[string]any) { _ = encoder.Encode(value) }

	if provider == "claude" {
		var input map[string]any
		_ = decoder.Decode(&input)
		write(map[string]any{"type": "system", "subtype": "init", "session_id": "claude-thread"})
		write(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start"}})
		write(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": "claude works"}}})
		write(map[string]any{"type": "result", "subtype": "success", "is_error": false})
		os.Exit(0)
	}

	for {
		var request map[string]any
		if err := decoder.Decode(&request); err != nil {
			os.Exit(1)
		}
		method, _ := request["method"].(string)
		switch method {
		case "initialized":
			continue
		case "initialize":
			write(map[string]any{"id": request["id"], "result": map[string]any{}})
		case "thread/start":
			write(map[string]any{"id": request["id"], "result": map[string]any{"thread": map[string]any{"id": "codex-thread"}}})
		case "turn/start":
			write(map[string]any{"id": request["id"], "result": map[string]any{"turn": map[string]any{"id": "codex-turn"}}})
			write(map[string]any{"method": "thread/started", "params": map[string]any{"thread": map[string]any{"id": "codex-thread"}}})
			write(map[string]any{"method": "turn/started", "params": map[string]any{"threadId": "codex-thread", "turn": map[string]any{"id": "codex-turn"}}})
			write(map[string]any{"method": "item/agentMessage/delta", "params": map[string]any{"threadId": "codex-thread", "turnId": "codex-turn", "delta": "codex works"}})
			item := map[string]any{"id": "collab-1", "type": "collabAgentToolCall", "receiverThreadIds": []any{"child-1"}}
			write(map[string]any{"method": "item/started", "params": map[string]any{"threadId": "codex-thread", "turnId": "codex-turn", "item": item}})
			write(map[string]any{"method": "item/completed", "params": map[string]any{"threadId": "codex-thread", "turnId": "codex-turn", "item": item}})
			write(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "codex-thread", "turn": map[string]any{"id": "codex-turn", "status": "completed"}}})
			os.Exit(0)
		default:
			write(map[string]any{"id": request["id"], "error": map[string]any{"message": "unexpected method"}})
		}
	}
}

func installProviderHelper(t *testing.T, provider string) {
	t.Helper()
	dir := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_PROVIDER_HELPER=%s exec %q -test.run=TestProviderHelperProcess -- \"$@\"\n", provider, binary)
	path := filepath.Join(dir, provider)
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func assertEventKinds(t *testing.T, events []map[string]any, expected ...string) {
	t.Helper()
	if len(events) != len(expected) {
		t.Fatalf("event count = %d, want %d: %#v", len(events), len(expected), events)
	}
	for index, kind := range expected {
		if events[index]["kind"] != kind {
			t.Fatalf("event %d kind = %v, want %s: %#v", index, events[index]["kind"], kind, events)
		}
	}
}
