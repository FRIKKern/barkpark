package pdrender

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
)

const (
	maxNestDepth  = 100
	maxJSONDepth  = 1000
	nestedTooDeep = "Nested too deep to show"
	slotEach      = "*"
)

var blockSlots = func() map[string][][]string {
	slots := map[string][][]string{
		"section":    {{"blocks", slotEach}, {"children", slotEach}},
		"columns":    {{"columns", slotEach, slotEach}},
		"terminal":   {{"blocks", slotEach}, {"children", slotEach}},
		"expandable": {{"blocks", slotEach}, {"children", slotEach}},
		"tabs":       {{"tabs", slotEach, "blocks", slotEach}},
		"steps":      {{"steps", slotEach, "blocks", slotEach}, {"steps", slotEach, "children", slotEach}},
		"figure":     {{"child"}},
		"card": {
			{"slots", "action", slotEach},
			{"slots", "body", slotEach},
			{"slots", "media", slotEach},
			{"slots", "title", slotEach},
		},
		"callout": {{"slots", "body", slotEach}},
		"note": {
			{"slots", "body", slotEach},
			{"slots", "label", slotEach},
			{"slots", "lead", slotEach},
		},
		"stage": {
			{"slots", "detail", slotEach},
			{"slots", "kind", slotEach},
			{"slots", "title", slotEach},
		},
	}
	for _, list := range []string{"list", "ordered-list", "numbered_list", "bulletList", "bullet_list", "bulleted-list", "bulleted_list"} {
		slots[list] = [][]string{{"items", slotEach, "children", slotEach}}
	}
	return slots
}()

// Decode turns a portable-doc document (`{"version":1,"blocks":[…]}`) or a bare
// block array into []Block. It is a convenience for callers (the demo, tests,
// and the future TUI wiring) — pdrender's renderers take []Block, not JSON, so
// this lives at the package edge and uses only encoding/json from the stdlib.
//
// Each block's type-specific fields land in Block.Attrs (the whole decoded map,
// minus nothing — the renderers read what they need). Container `children`
// (preferred) or legacy `blocks` becomes Block.Children and `figure.child`
// becomes Block.Child, recursively, so the renderers never re-parse JSON.
func Decode(raw []byte) ([]Block, error) {
	raw = clipJSONDepth(raw, maxJSONDepth)
	var env struct {
		Blocks []json.RawMessage `json:"blocks"`
	}
	if err := json.Unmarshal(raw, &env); err == nil && env.Blocks != nil {
		return decodeBlocks(env.Blocks), nil
	}
	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		return nil, err
	}
	return decodeBlocks(arr), nil
}

func clipJSONDepth(raw []byte, limit int) []byte {
	var out []byte
	depth, skipFrom := 0, 0
	inString, escaped := false, false
	for i, c := range raw {
		if inString {
			if out != nil && skipFrom == 0 {
				out = append(out, c)
			}
			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == '"':
				inString = false
			}
			continue
		}
		switch c {
		case '"':
			inString = true
		case '[', '{':
			depth++
			if depth > limit && skipFrom == 0 {
				if out == nil {
					out = append(make([]byte, 0, len(raw)), raw[:i]...)
				}
				skipFrom = depth
				out = append(out, "null"...)
			}
		case ']', '}':
			depth--
			if depth+1 == skipFrom {
				skipFrom = 0
				continue
			}
		}
		if out != nil && skipFrom == 0 {
			out = append(out, c)
		}
	}
	if out == nil {
		return raw
	}
	return out
}

func decodeBlocks(raws []json.RawMessage) []Block {
	out := make([]Block, 0, len(raws))
	for _, r := range raws {
		// Forward-compat: a document never crashes the reader. Skip JSON null
		// and any element that isn't an object (bare string/number) rather than
		// aborting the whole document — same tolerance as decodeAnyBlocks.
		if bytes.Equal(bytes.TrimSpace([]byte(r)), []byte("null")) {
			continue
		}
		m, err := decodeBlockMap(r)
		if err != nil {
			continue
		}
		out = append(out, blockFromMap(capDepth(m, 0).(map[string]any)))
	}
	return out
}

func decodeBlockMap(raw json.RawMessage) (map[string]any, error) {
	var m map[string]any
	err := json.Unmarshal(raw, &m)
	var typeErr *json.UnmarshalTypeError
	if !errors.As(err, &typeErr) {
		return m, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var n map[string]any
	if err := dec.Decode(&n); err != nil {
		return nil, err
	}
	return floatNumbers(n).(map[string]any), nil
}

func floatNumbers(v any) any {
	switch x := v.(type) {
	case json.Number:
		if f, err := strconv.ParseFloat(string(x), 64); err == nil {
			return f
		}
		return string(x)
	case []any:
		for i, e := range x {
			x[i] = floatNumbers(e)
		}
	case map[string]any:
		for k, e := range x {
			x[k] = floatNumbers(e)
		}
	}
	return v
}

func capDepth(block any, depth int) any {
	m, ok := block.(map[string]any)
	if !ok {
		return block
	}
	if depth >= maxNestDepth {
		return map[string]any{"type": "paragraph", "text": nestedTooDeep}
	}
	typ, _ := m["type"].(string)
	for _, path := range blockSlots[typ] {
		updateSlot(m, path, func(child any) any { return capDepth(child, depth+1) })
	}
	return m
}

func updateSlot(v any, path []string, fn func(any) any) any {
	if len(path) == 0 {
		return fn(v)
	}
	if path[0] == slotEach {
		list, ok := v.([]any)
		if !ok {
			return v
		}
		for i, e := range list {
			list[i] = updateSlot(e, path[1:], fn)
		}
		return list
	}
	m, ok := v.(map[string]any)
	if !ok {
		return v
	}
	if child, ok := m[path[0]]; ok {
		m[path[0]] = updateSlot(child, path[1:], fn)
	}
	return m
}

// decodeAnyBlocks converts an already-decoded []any of block maps into []Block.
func decodeAnyBlocks(list []any) []Block {
	out := make([]Block, 0, len(list))
	for _, item := range list {
		if cm, ok := item.(map[string]any); ok {
			out = append(out, blockFromMap(cm))
		}
	}
	return out
}

// blockFromMap builds a Block from an already-decoded map (recursing into
// nested container/figure children).
func blockFromMap(m map[string]any) Block {
	b := Block{
		ID:    attrStr(m, "id"),
		Type:  attrStr(m, "type"),
		Attrs: m,
	}
	if list := containerBlockList(m, b.Type); list != nil {
		b.Children = decodeAnyBlocks(list)
	}
	if cm, ok := m["child"].(map[string]any); ok {
		child := blockFromMap(cm)
		b.Child = &child
	}
	return b
}

// containerBlockList mirrors the web reader's container_children/1 contract
// for the two TUI renderers that consume Block.Children. `children` is the
// canonical expandable wire key; `blocks` remains the section/legacy fallback.
func containerBlockList(m map[string]any, blockType string) []any {
	if blockType != "section" && blockType != "expandable" {
		return nil
	}
	if children, ok := m["children"].([]any); ok {
		return children
	}
	if blocks, ok := m["blocks"].([]any); ok {
		return blocks
	}
	return nil
}
