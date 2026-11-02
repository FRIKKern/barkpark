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

func TestDecodeCapsFigureNestingAtTheDepthLimit(t *testing.T) {
	const depth = 4000
	var sb strings.Builder
	for i := 0; i < depth; i++ {
		sb.WriteString(`{"type":"figure","child":`)
	}
	sb.WriteString(`{"type":"paragraph"}`)
	for i := 0; i < depth; i++ {
		sb.WriteString(`}`)
	}
	blocks, err := Decode([]byte(fmt.Sprintf(`{"blocks":[%s]}`, sb.String())))
	if err != nil || len(blocks) != 1 {
		t.Fatalf("Decode: %d blocks, %v", len(blocks), err)
	}
	b := &blocks[0]
	levels := 0
	for ; b.Child != nil; b = b.Child {
		levels++
	}
	if levels != maxNestDepth || b.Type != "paragraph" || attrStr(b.Attrs, "text") != nestedTooDeep {
		t.Fatalf("figure chain: %d levels to a %q %v, want %d to the notice", levels, b.Type, b.Attrs, maxNestDepth)
	}
}

func TestDecodeCapsSectionNestingAtTheDepthLimit(t *testing.T) {
	const depth = 4000
	var sb strings.Builder
	for i := 0; i < depth; i++ {
		sb.WriteString(`{"type":"section","blocks":[`)
	}
	sb.WriteString(`{"type":"paragraph"}`)
	for i := 0; i < depth; i++ {
		sb.WriteString(`]}`)
	}
	blocks, err := Decode([]byte(fmt.Sprintf(`{"blocks":[%s]}`, sb.String())))
	if err != nil || len(blocks) != 1 {
		t.Fatalf("Decode: %d blocks, %v", len(blocks), err)
	}
	b := &blocks[0]
	levels := 0
	for ; len(b.Children) > 0; b = &b.Children[0] {
		levels++
	}
	if levels != maxNestDepth || attrStr(b.Attrs, "text") != nestedTooDeep {
		t.Fatalf("section chain: %d levels to %v, want %d to the notice", levels, b.Attrs, maxNestDepth)
	}
}
