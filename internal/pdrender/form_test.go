package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// A crafted scale block with min/max chosen so that max-min overflows int64
// (1e19 > math.MaxInt64) must NOT panic in make([]string, …). The guard has to
// fall through to the compact "min … max" branch instead of the ladder loop.
// scale values arrive as strings (decoded JSON attrInt path via strconv.Atoi).
func TestScaleLadderSpanOverflowNoPanic(t *testing.T) {
	q := map[string]any{
		"scale": map[string]any{
			"min": "-5000000000000000000",
			"max": "5000000000000000000",
		},
	}

	// A panic here (e.g. "makeslice: cap out of range") fails the test.
	got := scaleLadder(q, lipgloss.NewStyle())

	if !strings.Contains(got, " … ") {
		t.Fatalf("expected compact %q form for an overflowing span, got %q", " … ", got)
	}
}
