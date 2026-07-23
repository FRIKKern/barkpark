package chat

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/pdrender"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// headingBlocks is a one-heading document whose level-2 heading wears the
// theme's ChromeAccent — the color that differs skin-to-skin (charple #c78ae0
// vs evergreen #3fcf8e in dark). The render path colors headings via lipgloss's
// GLOBAL profile, so the byte difference only appears once TrueColor is forced.
func headingBlocks(text string) json.RawMessage {
	doc := map[string]any{
		"blocks": []any{
			map[string]any{"type": "heading", "level": 2, "text": text},
		},
	}
	raw, _ := json.Marshal(doc)
	return raw
}

// TestThemeReskinChangesBytes is the anti-vacuous proof for the `bp chat --theme`
// wiring: the SAME message rendered through a charple registry and an evergreen
// registry must produce DIFFERENT bytes — otherwise reskinning the transcript
// (run.go reassigns chatRegistry from cfg.Theme) would be a silent no-op.
//
// The SetColorProfile(TrueColor) call is load-bearing: lipgloss heading styles
// emit their theme foreground against the GLOBAL color profile, which defaults
// to NoColor under `go test` (no TTY). Without this line both skins strip to
// byte-IDENTICAL output and the assertion below would pass vacuously. We assert
// that explicitly by also checking that a NoColor profile collapses them.
func TestThemeReskinChangesBytes(t *testing.T) {
	prev := lipgloss.ColorProfile()
	defer lipgloss.SetColorProfile(prev)

	msg := Message{Role: "assistant", Blocks: headingBlocks("Release notes")}
	charpleReg := pdrender.DefaultRegistry(pdrender.ThemeFor("charple", "dark"))
	evergreenReg := pdrender.DefaultRegistry(pdrender.ThemeFor("evergreen", "dark"))

	// Guard the guard: under NoColor the two skins are byte-identical, which is
	// exactly why the TrueColor force is required for a NON-vacuous assertion.
	lipgloss.SetColorProfile(termenv.Ascii) // NoColor floor
	if renderStr(charpleReg, msg) != renderStr(evergreenReg, msg) {
		t.Fatal("under a colorless profile the skins should be byte-identical — the color force is what makes the real assertion meaningful")
	}

	// The real assertion: with TrueColor forced, the palettes emit distinct SGR.
	lipgloss.SetColorProfile(termenv.TrueColor)
	charpleOut := renderStr(charpleReg, msg)
	evergreenOut := renderStr(evergreenReg, msg)
	if charpleOut == evergreenOut {
		t.Fatalf("charple and evergreen must render byte-DIFFERENTLY under TrueColor (reskin is a no-op otherwise)\ncharple:   %q\nevergreen: %q", charpleOut, evergreenOut)
	}
}

func renderStr(reg *pdrender.Registry, msg Message) string {
	return strings.Join(renderAssistantDoc(reg, 80, msg), "\n")
}
