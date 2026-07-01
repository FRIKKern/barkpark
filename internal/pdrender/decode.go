package pdrender

import (
	"bytes"
	"encoding/json"
)

// maxBlockDepth caps how deep the decoder recurses into nested section `blocks`
// and figure `child`. Portable-doc content is attacker-controllable (API-served),
// and Go grows a goroutine's stack to a 1GB hard limit before *fatally* aborting
// the process — a crash that recover() cannot catch. A crafted document nested
// tens of thousands deep would drive exactly that. Past the cap we keep the block
// itself but stop descending (Children/Child left nil), so a pathological document
// renders truncated instead of crashing the whole TUI/CLI. Same attacker-driven
// render-time-DoS class already hardened in form.go's scaleLadder.
const maxBlockDepth = 64

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
		return decodeBlocks(env.Blocks, 0)
	}
	// Fall back to a bare array of blocks.
	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		return nil, err
	}
	return decodeBlocks(arr, 0)
}

func decodeBlocks(raws []json.RawMessage, depth int) ([]Block, error) {
	out := make([]Block, 0, len(raws))
	for _, r := range raws {
		// Forward-compat: a document never crashes the reader. Skip JSON null
		// and any element that isn't an object (bare string/number) rather than
		// aborting the whole document — same tolerance as decodeAnyBlocks.
		if bytes.Equal(bytes.TrimSpace([]byte(r)), []byte("null")) {
			continue
		}
		b, err := decodeBlock(r, depth)
		if err != nil {
			continue
		}
		out = append(out, b)
	}
	return out, nil
}

func decodeBlock(raw json.RawMessage, depth int) (Block, error) {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return Block{}, err
	}
	b := Block{
		ID:    attrStr(m, "id"),
		Type:  attrStr(m, "type"),
		Attrs: m,
	}

	// Depth cap: keep this block but stop descending into its children, so a
	// pathologically-nested document truncates instead of stack-overflowing.
	if depth >= maxBlockDepth {
		return b, nil
	}

	// section carries child blocks under "blocks".
	if rawBlocks, ok := m["blocks"]; ok {
		if list, ok := rawBlocks.([]any); ok {
			b.Children = decodeAnyBlocks(list, depth+1)
		}
	}
	// figure carries a single child under "child".
	if rawChild, ok := m["child"]; ok {
		if cm, ok := rawChild.(map[string]any); ok {
			child := blockFromMap(cm, depth+1)
			b.Child = &child
		}
	}
	return b, nil
}

// decodeAnyBlocks converts an already-decoded []any of block maps into []Block.
func decodeAnyBlocks(list []any, depth int) []Block {
	out := make([]Block, 0, len(list))
	for _, item := range list {
		if cm, ok := item.(map[string]any); ok {
			out = append(out, blockFromMap(cm, depth))
		}
	}
	return out
}

// blockFromMap builds a Block from an already-decoded map (recursing into
// nested section/figure children).
func blockFromMap(m map[string]any, depth int) Block {
	b := Block{
		ID:    attrStr(m, "id"),
		Type:  attrStr(m, "type"),
		Attrs: m,
	}
	// Depth cap: keep this block but stop descending (see decodeBlock).
	if depth >= maxBlockDepth {
		return b
	}
	if rawBlocks, ok := m["blocks"].([]any); ok {
		b.Children = decodeAnyBlocks(rawBlocks, depth+1)
	}
	if cm, ok := m["child"].(map[string]any); ok {
		child := blockFromMap(cm, depth+1)
		b.Child = &child
	}
	return b
}
