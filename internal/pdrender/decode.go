package pdrender

import "encoding/json"

// Decode turns a portable-doc document (`{"version":1,"blocks":[…]}`) or a bare
// block array into []Block. It is a convenience for callers (the demo, tests,
// and the future TUI wiring) — pdrender's renderers take []Block, not JSON, so
// this lives at the package edge and uses only encoding/json from the stdlib.
//
// Each block's type-specific fields land in Block.Attrs (the whole decoded map,
// minus nothing — the renderers read what they need). `section.blocks` becomes
// Block.Children and `figure.child` becomes Block.Child, recursively, so the
// renderers never re-parse JSON.
func Decode(raw []byte) ([]Block, error) {
	// Try the document envelope first.
	var env struct {
		Blocks []json.RawMessage `json:"blocks"`
	}
	if err := json.Unmarshal(raw, &env); err == nil && env.Blocks != nil {
		return decodeBlocks(env.Blocks)
	}
	// Fall back to a bare array of blocks.
	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		return nil, err
	}
	return decodeBlocks(arr)
}

func decodeBlocks(raws []json.RawMessage) ([]Block, error) {
	out := make([]Block, 0, len(raws))
	for _, r := range raws {
		b, err := decodeBlock(r)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, nil
}

func decodeBlock(raw json.RawMessage) (Block, error) {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return Block{}, err
	}
	b := Block{
		ID:    attrStr(m, "id"),
		Type:  attrStr(m, "type"),
		Attrs: m,
	}

	// section carries child blocks under "blocks".
	if rawBlocks, ok := m["blocks"]; ok {
		if list, ok := rawBlocks.([]any); ok {
			b.Children = decodeAnyBlocks(list)
		}
	}
	// figure carries a single child under "child".
	if rawChild, ok := m["child"]; ok {
		if cm, ok := rawChild.(map[string]any); ok {
			child := blockFromMap(cm)
			b.Child = &child
		}
	}
	return b, nil
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
// nested section/figure children).
func blockFromMap(m map[string]any) Block {
	b := Block{
		ID:    attrStr(m, "id"),
		Type:  attrStr(m, "type"),
		Attrs: m,
	}
	if rawBlocks, ok := m["blocks"].([]any); ok {
		b.Children = decodeAnyBlocks(rawBlocks)
	}
	if cm, ok := m["child"].(map[string]any); ok {
		child := blockFromMap(cm)
		b.Child = &child
	}
	return b
}
