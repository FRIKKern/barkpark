package pdrender

import "testing"

// TestResolvePaletteDistinctAndFallback pins the skin-resolution contract the
// `bp chat --theme` wiring rides on: each named palette is a genuinely different
// set of colors (so a reskin actually changes what the terminal draws), and an
// id the palette map doesn't carry resolves to the evergreen default — never a
// zero/partial palette. Palette is a struct of comparable AdaptiveColor fields,
// so `==` is a full-value equality. "light" is deliberately NOT used as a test
// id here (it is not a genPalette id and would resolve to evergreen anyway).
func TestResolvePaletteDistinctAndFallback(t *testing.T) {
	charple := Resolve("charple")
	ember := Resolve("ember")
	evergreen := Resolve("evergreen")

	// Pairwise-distinct: three real skins, three different palettes.
	if charple == ember {
		t.Fatal("charple and ember must resolve to DISTINCT palettes (reskin would be a no-op)")
	}
	if charple == evergreen {
		t.Fatal("charple and evergreen must resolve to DISTINCT palettes")
	}
	if ember == evergreen {
		t.Fatal("ember and evergreen must resolve to DISTINCT palettes")
	}

	// An unknown id falls back to the evergreen default (Resolve's floor).
	if got := Resolve("bogus-not-a-real-skin"); got != evergreen {
		t.Fatalf("unknown id must fall back to evergreen, got %+v", got)
	}
	// The DefaultTheme const IS evergreen — the fallback target is the named default.
	if Resolve(DefaultTheme) != evergreen {
		t.Fatalf("Resolve(DefaultTheme=%q) must equal Resolve(\"evergreen\")", DefaultTheme)
	}
}
