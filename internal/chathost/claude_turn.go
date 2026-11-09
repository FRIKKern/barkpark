package chathost

import (
	"encoding/json"
	"fmt"
	"strings"
)

// claudeTurn reads one Claude run's stream-json (one send_turn) and says what the
// turn is doing, in the runtime kinds Barkpark already knows from the codex path:
//
//	first message_start          → turn_started (Claude sends one per assistant
//	                               message; a tool-using turn has several, and a
//	                               second turn_started made the Recorder drop the
//	                               text before it: task-aa27c3d55ca8d009)
//	text block start / stop      → item_started / item_completed {type: "text"}:
//	                               where one text ends and the next begins, so a
//	                               client can show two messages, not one run-on text
//	tool_use block stop          → item_started {type: "tool_use", id, name, input}
//	                               (the input is whole once its block stops)
//	its tool_result              → item_completed, the same item plus is_error
//
// Everything else goes through claudeEvent unchanged (task-f13fc4b4dc2af6de).
type claudeTurn struct {
	started bool
	texts   int
	blocks  map[int]*claudeBlock
	tools   map[string]map[string]any // started tool_use items awaiting their result
	seen    map[string]bool           // tool_use ids already announced
}

type claudeBlock struct {
	kind  string
	id    string
	name  string
	input strings.Builder
}

func newClaudeTurn() *claudeTurn {
	return &claudeTurn{blocks: map[int]*claudeBlock{}, tools: map[string]map[string]any{}, seen: map[string]bool{}}
}

func (c *claudeTurn) events(message map[string]any) []map[string]any {
	switch message["type"] {
	case "stream_event":
		event, _ := message["event"].(map[string]any)
		return c.streamEvent(event)
	case "assistant":
		// The whole message. Its tool calls were normally announced from the
		// stream already; this catches one the stream did not carry.
		var out []map[string]any
		for _, block := range contentBlocks(message) {
			if block["type"] == "tool_use" {
				if id, _ := block["id"].(string); id != "" && !c.seen[id] {
					input, _ := block["input"].(map[string]any)
					out = append(out, c.startTool(id, fmt.Sprint(block["name"]), input))
				}
			}
		}
		return out
	case "user":
		var out []map[string]any
		for _, block := range contentBlocks(message) {
			if block["type"] != "tool_result" {
				continue
			}
			id, _ := block["tool_use_id"].(string)
			item, ok := c.tools[id]
			if !ok {
				continue
			}
			delete(c.tools, id)
			done := map[string]any{}
			for k, v := range item {
				done[k] = v
			}
			isError, _ := block["is_error"].(bool)
			done["is_error"] = isError
			out = append(out, map[string]any{"kind": "item_completed", "item_id": id, "item": done})
		}
		return out
	}
	if event := claudeEvent(message); event != nil {
		return []map[string]any{event}
	}
	return nil
}

func (c *claudeTurn) streamEvent(event map[string]any) []map[string]any {
	index := -1
	if n, ok := event["index"].(float64); ok {
		index = int(n)
	}
	switch event["type"] {
	case "message_start":
		c.blocks = map[int]*claudeBlock{}
		if c.started {
			return nil
		}
		c.started = true
		return []map[string]any{{"kind": "turn_started"}}
	case "content_block_start":
		block, _ := event["content_block"].(map[string]any)
		switch block["type"] {
		case "text":
			c.texts++
			b := &claudeBlock{kind: "text", id: fmt.Sprintf("text-%d", c.texts)}
			c.blocks[index] = b
			return []map[string]any{{"kind": "item_started", "item_id": b.id, "item": map[string]any{"type": "text", "id": b.id}}}
		case "tool_use":
			id, _ := block["id"].(string)
			c.blocks[index] = &claudeBlock{kind: "tool_use", id: id, name: fmt.Sprint(block["name"])}
		}
		return nil
	case "content_block_delta":
		delta, _ := event["delta"].(map[string]any)
		if delta["type"] == "input_json_delta" {
			if b := c.blocks[index]; b != nil && b.kind == "tool_use" {
				partial, _ := delta["partial_json"].(string)
				b.input.WriteString(partial)
			}
			return nil
		}
	case "content_block_stop":
		b := c.blocks[index]
		delete(c.blocks, index)
		switch {
		case b == nil:
			return nil
		case b.kind == "text":
			return []map[string]any{{"kind": "item_completed", "item_id": b.id, "item": map[string]any{"type": "text", "id": b.id}}}
		case b.kind == "tool_use" && b.id != "" && !c.seen[b.id]:
			input := map[string]any{}
			if raw := strings.TrimSpace(b.input.String()); raw != "" {
				_ = json.Unmarshal([]byte(raw), &input) // a malformed input still names the tool
			}
			return []map[string]any{c.startTool(b.id, b.name, input)}
		}
		return nil
	}
	if event := claudeEvent(map[string]any{"type": "stream_event", "event": event}); event != nil {
		return []map[string]any{event}
	}
	return nil
}

func (c *claudeTurn) startTool(id, name string, input map[string]any) map[string]any {
	if input == nil {
		input = map[string]any{}
	}
	item := map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}
	c.seen[id] = true
	c.tools[id] = item
	return map[string]any{"kind": "item_started", "item_id": id, "item": item}
}

func contentBlocks(message map[string]any) []map[string]any {
	inner, _ := message["message"].(map[string]any)
	list, _ := inner["content"].([]any)
	out := make([]map[string]any, 0, len(list))
	for _, v := range list {
		if block, ok := v.(map[string]any); ok {
			out = append(out, block)
		}
	}
	return out
}
