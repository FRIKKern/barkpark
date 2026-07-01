package pdrender

import (
	"fmt"
	"strings"
	"testing"
)

// TestDecodeSkipsNonObjectBlocks asserts pdrender's forward-compat rule: a
// document never crashes the reader. A JSON null or a bare non-object element
// in "blocks" is skipped, not fatal, and never yields a Type=="" block that
// paints a bogus unknown-type box.
func TestDecodeSkipsNonObjectBlocks(t *testing.T) {
	blocks, err := Decode([]byte(`{"blocks":[{"type":"paragraph"},null,"garbage",{"type":"paragraph"}]}`))
	if err != nil {
		t.Fatalf("Decode: unexpected error: %v", err)
	}
	if len(blocks) != 2 {
		t.Fatalf("Decode: got %d blocks, want 2", len(blocks))
	}
	for i, b := range blocks {
		if b.Type == "" {
			t.Errorf("block %d has empty Type — a non-object element leaked through", i)
		}
	}
}

// TestDecodeCapsNestingDepth asserts the depth cap: a pathologically-nested
// document (thousands deep here, but arbitrary from the API) decodes without the
// process fatally overflowing its goroutine stack, and the resulting tree is
// truncated at maxBlockDepth rather than descending forever. (Depth is kept just
// under encoding/json's own ~10k nesting limit so json.Unmarshal itself does not
// reject the input before our recursion is exercised.)
func TestDecodeCapsNestingDepth(t *testing.T) {
	// Build a figure nested `depth` levels deep, each carrying the next under
	// "child": figure{child: figure{child: … paragraph}}.
	const depth = 4000
	var sb strings.Builder
	for i := 0; i < depth; i++ {
		sb.WriteString(`{"type":"figure","child":`)
	}
	sb.WriteString(`{"type":"paragraph"}`)
	for i := 0; i < depth; i++ {
		sb.WriteString(`}`)
	}
	raw := []byte(fmt.Sprintf(`{"blocks":[%s]}`, sb.String()))

	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("Decode: unexpected error: %v", err)
	}
	if len(blocks) != 1 {
		t.Fatalf("Decode: got %d top-level blocks, want 1", len(blocks))
	}

	// Walk the Child chain. It must stop (Child == nil) at or before the cap,
	// never continuing all the way down the 10k-deep source.
	levels := 1
	for b := &blocks[0]; b.Child != nil; b = b.Child {
		levels++
		if levels > maxBlockDepth+1 {
			t.Fatalf("Decode: child chain reached %d levels, not truncated at maxBlockDepth=%d", levels, maxBlockDepth)
		}
	}
	if levels <= maxBlockDepth {
		t.Fatalf("Decode: child chain only %d levels, expected truncation right at the cap (maxBlockDepth=%d)", levels, maxBlockDepth)
	}
}

// TestDecodeCapsSectionNestingDepth is the section/"blocks" analogue: a deeply
// nested section chain must likewise truncate at the cap without crashing.
func TestDecodeCapsSectionNestingDepth(t *testing.T) {
	const depth = 4000
	var sb strings.Builder
	for i := 0; i < depth; i++ {
		sb.WriteString(`{"type":"section","blocks":[`)
	}
	sb.WriteString(`{"type":"paragraph"}`)
	for i := 0; i < depth; i++ {
		sb.WriteString(`]}`)
	}
	raw := []byte(fmt.Sprintf(`{"blocks":[%s]}`, sb.String()))

	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("Decode: unexpected error: %v", err)
	}
	if len(blocks) != 1 {
		t.Fatalf("Decode: got %d top-level blocks, want 1", len(blocks))
	}

	levels := 1
	for b := &blocks[0]; len(b.Children) > 0; b = &b.Children[0] {
		levels++
		if levels > maxBlockDepth+1 {
			t.Fatalf("Decode: section chain reached %d levels, not truncated at maxBlockDepth=%d", levels, maxBlockDepth)
		}
	}
	if levels <= maxBlockDepth {
		t.Fatalf("Decode: section chain only %d levels, expected truncation right at the cap (maxBlockDepth=%d)", levels, maxBlockDepth)
	}
}
