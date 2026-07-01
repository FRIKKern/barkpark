package pdrender

import "testing"

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
