package cli

import (
	"strings"
	"testing"
)

// TestReadCappedOverLimit asserts readCapped fails loudly (rather than silently
// truncating) when the body exceeds the cap. Uses a tiny 10-byte cap against a
// 20-byte reader so the test allocates nothing large.
func TestReadCappedOverLimit(t *testing.T) {
	_, err := readCapped(strings.NewReader(strings.Repeat("x", 20)), 10)
	if err == nil {
		t.Fatal("expected error for over-limit body, got nil")
	}
	if !strings.Contains(err.Error(), "refusing to parse a truncated body") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

// TestReadCappedUnderLimit asserts an under-cap body reads through intact.
func TestReadCappedUnderLimit(t *testing.T) {
	b, err := readCapped(strings.NewReader("hello"), 10)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(b) != "hello" {
		t.Fatalf("got %q, want %q", b, "hello")
	}
}

// TestReadCappedAtLimit asserts a body exactly at the cap is accepted (the +1
// sentinel read must not misfire on the boundary).
func TestReadCappedAtLimit(t *testing.T) {
	b, err := readCapped(strings.NewReader("0123456789"), 10)
	if err != nil {
		t.Fatalf("unexpected error at boundary: %v", err)
	}
	if len(b) != 10 {
		t.Fatalf("got %d bytes, want 10", len(b))
	}
}
