package chathost

import (
	"context"
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

func TestLocalHandlerAcknowledgesControlWithoutStartingProvider(t *testing.T) {
	handler := LocalHandler{}
	var event map[string]any
	err := handler.Handle(context.Background(), RemoteCommand{
		Command: map[string]any{"operation": "interrupt", "provider": "codex"},
	}, func(value map[string]any) error {
		event = value
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if event["kind"] != "control_completed" || event["operation"] != "interrupt" {
		t.Fatalf("unexpected event: %#v", event)
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
