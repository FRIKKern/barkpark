package chathost

import (
	"context"
	"encoding/json"
	"io"
	"testing"
)

// task-98e736d8d75285f0: Barkpark stores U+FFFD for U+0000 in an event
// (ChatHosts.EventText), so the answer names an approval by that id. The host
// keeps it under that id and answers the provider with the provider's own id.
// Today Claude ids are UUIDs and Codex ids are integers, so this is the first
// id the two sides would disagree on.

func TestClaudeApprovalWhoseIDHoldsNULIsAnsweredWithTheRawID(t *testing.T) {
	reader, writer := io.Pipe()
	defer reader.Close()
	session := newActiveLocalSession("claude", nil, writer)
	decoder := json.NewDecoder(reader)

	events := session.claudeMessage(map[string]any{
		"type": "control_request", "request_id": "r\x001",
		"request": map[string]any{"subtype": "can_use_tool", "tool_name": "Write", "input": map[string]any{"path": "a.txt"}},
	})
	if len(events) != 1 || events[0]["approval_id"] != "r�1" {
		t.Fatalf("approval event: %#v", events)
	}

	done := make(chan error, 1)
	go func() {
		done <- session.control(context.Background(), "answer_approval", map[string]any{
			"approval_id": "r�1", "payload": map[string]any{"decision": "allow"},
		})
	}()
	var reply map[string]any
	if err := decoder.Decode(&reply); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got := nestedString(reply, "response", "request_id"); got != "r\x001" {
		t.Fatalf("request_id sent back = %q, want the CLI's own id", got)
	}
	if nestedString(reply, "response", "response", "updatedInput", "path") != "a.txt" {
		t.Fatalf("updatedInput: %#v", reply)
	}
}

func TestCodexApprovalWhoseIDHoldsNULIsAnsweredWithTheRawID(t *testing.T) {
	reader, writer := io.Pipe()
	defer reader.Close()
	session := newActiveLocalSession("codex", nil, writer)
	decoder := json.NewDecoder(reader)

	event, _ := session.codexMessage(map[string]any{
		"id": "a\x0091", "method": "item/commandExecution/requestApproval",
		"params": map[string]any{"threadId": "thread-1", "turnId": "turn-1", "itemId": "cmd-1"},
	})
	if event["approval_id"] != "a�91" {
		t.Fatalf("approval event: %#v", event)
	}

	done := make(chan error, 1)
	go func() {
		done <- session.control(context.Background(), "answer_approval", map[string]any{
			"approval_id": "a�91", "payload": map[string]any{"decision": "allow"},
		})
	}()
	var reply map[string]any
	if err := decoder.Decode(&reply); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if reply["id"] != "a\x0091" || nestedString(reply, "result", "decision") != "accept" {
		t.Fatalf("reply to the app-server: %#v", reply)
	}
}

// Ids a provider sends today keep their bytes, as the key and in the reply.
func TestApprovalKeyLeavesCleanIDsAlone(t *testing.T) {
	if got := approvalKey(float64(91)); got != "91" {
		t.Fatalf("approvalKey(91) = %q", got)
	}
	for _, id := range []string{"ask-1", "3f2a9c1e-7b1d-4c2e-9a0f-1b2c3d4e5f60", "emoji 🐕", "\u0001", "�", `the literal \u0000`} {
		if got := approvalKey(id); got != id {
			t.Fatalf("approvalKey(%q) = %q", id, got)
		}
	}
}
