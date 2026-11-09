package chathost

import (
	"reflect"
	"testing"
)

func streamEvent(event map[string]any) map[string]any {
	return map[string]any{"type": "stream_event", "event": event}
}

// A turn as Claude streams it with --include-partial-messages: a sentence, a tool
// call, its result, then the answer in a SECOND assistant message (a second
// message_start). task-aa27c3d55ca8d009: the second message_start must not be a
// second turn_started. task-f13fc4b4dc2af6de: the tool call arrives with its name
// and input, and each text block has edges.
func TestClaudeTurnWithTwoMessagesEmitsOneTurnToolItemsAndTextEdges(t *testing.T) {
	session := newActiveLocalSession("claude", nil, nil)
	stream := []map[string]any{
		{"type": "system", "subtype": "init", "session_id": "claude-thread"},
		streamEvent(map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_1"}}),
		streamEvent(map[string]any{"type": "content_block_start", "index": 0.0, "content_block": map[string]any{"type": "text", "text": ""}}),
		streamEvent(map[string]any{"type": "content_block_delta", "index": 0.0, "delta": map[string]any{"type": "text_delta", "text": "Let me check "}}),
		streamEvent(map[string]any{"type": "content_block_delta", "index": 0.0, "delta": map[string]any{"type": "text_delta", "text": "the disk."}}),
		streamEvent(map[string]any{"type": "content_block_stop", "index": 0.0}),
		streamEvent(map[string]any{"type": "content_block_start", "index": 1.0, "content_block": map[string]any{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": map[string]any{}}}),
		streamEvent(map[string]any{"type": "content_block_delta", "index": 1.0, "delta": map[string]any{"type": "input_json_delta", "partial_json": `{"command":"df -h",`}}),
		streamEvent(map[string]any{"type": "content_block_delta", "index": 1.0, "delta": map[string]any{"type": "input_json_delta", "partial_json": `"description":"Check disk space"}`}}),
		streamEvent(map[string]any{"type": "content_block_stop", "index": 1.0}),
		// The whole message follows its stream; its tool call is already announced.
		{"type": "assistant", "message": map[string]any{"content": []any{
			map[string]any{"type": "text", "text": "Let me check the disk."},
			map[string]any{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": map[string]any{"command": "df -h", "description": "Check disk space"}},
		}}},
		streamEvent(map[string]any{"type": "message_stop"}),
		{"type": "user", "message": map[string]any{"content": []any{
			map[string]any{"type": "tool_result", "tool_use_id": "toolu_1", "content": "…", "is_error": false},
		}}},
		streamEvent(map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_2"}}),
		streamEvent(map[string]any{"type": "content_block_start", "index": 0.0, "content_block": map[string]any{"type": "text", "text": ""}}),
		streamEvent(map[string]any{"type": "content_block_delta", "index": 0.0, "delta": map[string]any{"type": "text_delta", "text": "You have 40 GB free."}}),
		streamEvent(map[string]any{"type": "content_block_stop", "index": 0.0}),
		streamEvent(map[string]any{"type": "message_stop"}),
		{"type": "result", "subtype": "success", "is_error": false},
	}
	var events []map[string]any
	for _, message := range stream {
		events = append(events, session.claudeMessage(message)...)
	}
	assertEventKinds(t, events,
		"session_started", "turn_started",
		"item_started", "text_delta", "text_delta", "item_completed", // the first text block
		"item_started", "item_completed", // Bash, then its result
		"item_started", "text_delta", "item_completed", // the answer, a second text block
		"turn_completed")

	if got := events[2]["item"]; !reflect.DeepEqual(got, map[string]any{"type": "text", "id": "text-1"}) {
		t.Fatalf("first text block item = %#v", got)
	}
	if events[8]["item_id"] != "text-2" || events[10]["item_id"] != "text-2" {
		t.Fatalf("the second text block must be its own item: %#v / %#v", events[8], events[10])
	}
	want := map[string]any{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": map[string]any{"command": "df -h", "description": "Check disk space"}}
	if events[6]["item_id"] != "toolu_1" || !reflect.DeepEqual(events[6]["item"], want) {
		t.Fatalf("tool item_started = %#v, want name and whole input %#v", events[6], want)
	}
	done, _ := events[7]["item"].(map[string]any)
	if events[7]["item_id"] != "toolu_1" || done["name"] != "Bash" || done["is_error"] != false {
		t.Fatalf("tool item_completed = %#v", events[7])
	}
}

// A tool call the stream did not carry (no partial messages) is still announced
// once, from the whole assistant message, and a failed result says so.
func TestClaudeTurnAnnouncesAToolFromTheWholeMessageOnce(t *testing.T) {
	session := newActiveLocalSession("claude", nil, nil)
	whole := map[string]any{"type": "assistant", "message": map[string]any{"content": []any{
		map[string]any{"type": "tool_use", "id": "toolu_9", "name": "Read", "input": map[string]any{"file_path": "/tmp/a.txt"}},
	}}}
	events := session.claudeMessage(whole)
	events = append(events, session.claudeMessage(whole)...)
	events = append(events, session.claudeMessage(map[string]any{"type": "user", "message": map[string]any{"content": []any{
		map[string]any{"type": "tool_result", "tool_use_id": "toolu_9", "content": "denied", "is_error": true},
	}}})...)
	assertEventKinds(t, events, "item_started", "item_completed")
	if input, _ := events[0]["item"].(map[string]any)["input"].(map[string]any); input["file_path"] != "/tmp/a.txt" {
		t.Fatalf("item_started input = %#v", events[0])
	}
	if events[1]["item"].(map[string]any)["is_error"] != true {
		t.Fatalf("a failed tool result must say is_error: %#v", events[1])
	}
}
