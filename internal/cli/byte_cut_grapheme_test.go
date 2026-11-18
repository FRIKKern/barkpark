package cli

import (
	"strings"
	"testing"
)

// task-a743c93d44c11c48: the CLI's byte cuts back off to a grapheme boundary,
// so a flag never ends as one boxed letter.

func TestBodyPreviewDropsAFlagCutInHalf(t *testing.T) {
	// 116 + 8 bytes: byte 120 falls between the flag's two indicators.
	got := bodyPreview([]byte(strings.Repeat("a", 116) + "🇳🇴" + "zz"))
	if want := strings.Repeat("a", 116) + "…"; got != want {
		t.Fatalf("bodyPreview kept %q after the a's, want nothing", strings.TrimPrefix(got, strings.Repeat("a", 116)))
	}
}

func TestClampMCPToolResultDropsAFlagCutInHalf(t *testing.T) {
	keep := mcpToolResultMaxBytes - 4
	got := clampMCPToolResultWithHint(strings.Repeat("a", keep)+"🇳🇴"+strings.Repeat("z", 100), "hint")
	if rest := strings.TrimPrefix(got, strings.Repeat("a", keep)); !strings.HasPrefix(rest, "\n[truncated:") {
		t.Fatalf("clampMCPToolResult kept %q after the a's, want the truncation notice", rest[:min(len(rest), 24)])
	}
}
