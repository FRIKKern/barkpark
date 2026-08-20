package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// TestDividerNarrowWidthGuard locks the dividerRenderer `if gw >= w` guard
// (blocks.go). The golden suite only exercises widths >= 40 (goldenWidths min
// is 40), so the sub-glyph-width path is otherwise uncovered — yet pdrender is
// also a standalone CLI renderer where ctx.Width can be caller-supplied, and
// clampWidth floors Width at 1 (not at the glyph width 3), so `gw >= w` is the
// ONLY thing standing between a narrow terminal and a panic.
//
// RED-ON-REMOVAL PROOF (what this test protects): the divider glyph " § " has
// display width gw=3. At ctx.Width:2, clampWidth(2)=2, so w=2 < gw=3. WITHOUT
// the guard the code falls through to:
//
//	side  = (w - gw) / 2      = (2 - 3) / 2 = 0     (Go trunc-toward-zero)
//	right = strings.Repeat("─", w-gw-side) = Repeat("─", 2-3-0) = Repeat("─", -1)
//
// and strings.Repeat PANICS on a negative count ("strings: negative Repeat
// count"). WITH the guard, w<gw returns the trimmed glyph ("§") as a single
// 1-cell line. Deleting `if gw >= w { … }` from blocks.go turns this test from
// PASS into a panic — that is the regression it exists to catch.
func TestDividerNarrowWidthGuard(t *testing.T) {
	// Pin the process-global lipgloss color profile to Ascii so the output
	// carries no ANSI (same discipline as testRegistry); we assert on plain text.
	testRegistry()

	// Width:2 is below the glyph width (3) — the guard's exact trigger. Render
	// through the real registry dispatch so the divider block path is exercised
	// end-to-end, not just the renderer in isolation.
	reg := testRegistry()
	ctx := RenderCtx{Width: 2, Theme: DarkTheme(), Profile: NoColor}

	var lines []string
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("dividerRenderer panicked at Width:2 — the gw>=w guard in blocks.go is missing or broken; strings.Repeat got a negative count: %v", r)
			}
		}()
		lines = reg.Render(Block{Type: "divider"}, ctx)
	}()

	// Sane, bounded output: exactly one line, non-empty, carrying the glyph, and
	// no wider than the (clamped) target. The guard degrades to the trimmed
	// glyph "§" rather than a crushed rule band.
	if len(lines) != 1 {
		t.Fatalf("expected exactly 1 divider line at Width:2, got %d: %q", len(lines), lines)
	}
	out := ansi.Strip(lines[0])
	if strings.TrimSpace(out) == "" {
		t.Fatalf("expected a non-empty 1-cell divider at Width:2, got %q", out)
	}
	if !strings.Contains(out, "§") {
		t.Fatalf("expected the trimmed glyph %q in the narrow-divider degrade, got %q", "§", out)
	}
	if w := lipgloss.Width(out); w > 3 {
		t.Fatalf("narrow-divider degrade should stay tiny (<=3 cells), got width %d: %q", w, out)
	}
}
