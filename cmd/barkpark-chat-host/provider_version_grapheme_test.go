package main

import (
	"strings"
	"testing"
)

// task-a743c93d44c11c48: the 200-byte provider-version cut backs off to a
// grapheme boundary, so a flag never ends as one boxed letter.
func TestProviderVersionDropsAFlagCutInHalf(t *testing.T) {
	// 196 + 8 bytes: byte 200 falls between the flag's two indicators.
	prefix := "v" + strings.Repeat("a", 195)
	got := providerVersion([]byte(prefix + "🇳🇴" + "tail"))
	if got != prefix {
		t.Fatalf("providerVersion kept %q after the prefix, want nothing", strings.TrimPrefix(got, prefix))
	}
}
