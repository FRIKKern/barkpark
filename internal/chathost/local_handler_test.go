package chathost

import (
	"context"
	"strings"
	"testing"
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
	for _, pair := range providerEnv() {
		if strings.HasPrefix(pair, "BARKPARK_TEST_SECRET=") {
			t.Fatal("provider inherited an unrelated host secret")
		}
	}
}

func TestLocalHandlerRejectsUnsupportedControl(t *testing.T) {
	handler := LocalHandler{}
	err := handler.Handle(context.Background(), RemoteCommand{
		Command: map[string]any{"operation": "steer", "provider": "codex"},
	}, func(value map[string]any) error {
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "unsupported registered-host operation") {
		t.Fatalf("expected unsupported control error, got %v", err)
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
