package manifest

import (
	"strings"
	"testing"
)

// task-a743c93d44c11c48: the 2,048-byte cut backs off to a grapheme boundary,
// so a flag in a server body never ends as one boxed letter.
func TestClampErrBodyDropsAFlagCutInHalf(t *testing.T) {
	// 2,044 + 8 bytes: byte 2,048 falls between the flag's two indicators.
	in := strings.Repeat("a", 2044) + "🇳🇴" + "tail"
	got := clampErrBody(in)
	if want := strings.Repeat("a", 2044) + "…"; got != want {
		t.Fatalf("clampErrBody kept %q after the a's, want nothing", strings.TrimPrefix(got, strings.Repeat("a", 2044)))
	}
}
