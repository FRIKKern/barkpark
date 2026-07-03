package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

func colorFieldModel(value string) model {
	return model{
		selectedDoc: &Doc{
			ID:     "drafts.p1",
			Title:  "Doc",
			Values: map[string]string{"accent": value},
		},
		editorSchema: &apiclient.Schema{
			Name: "post",
			Fields: []Field{
				{Name: "accent", Title: "Accent", Type: FieldColor},
			},
		},
		width:  100,
		height: 40,
	}
}

// TestFieldColorSwatchGuard proves the editor's FieldColor swatch is driven ONLY
// by a strict #rgb/#rrggbb value. A valid hex paints a real background swatch
// (48;… SGR); a hostile/malformed value renders plain with no swatch, so it
// cannot inject escapes into the terminal (parity with pdrender's
// fieldColorRenderer).
func TestFieldColorSwatchGuard(t *testing.T) {
	lipgloss.SetColorProfile(0) // termenv.TrueColor → a swatch emits 48;2;r;g;b
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	// Valid hex → a real background swatch.
	m := colorFieldModel("#a23925")
	out := strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "\x1b[48;") {
		t.Fatalf("valid hex should paint a background swatch (\\x1b[48;…), got:\n%q", out)
	}

	// Non-hex value → no swatch (no background SGR at all in this non-focused
	// style, which carries only a border foreground color).
	m = colorFieldModel("red; rm -rf /")
	out = strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if strings.Contains(out, "\x1b[48;") {
		t.Errorf("non-hex value must not drive a swatch, got:\n%q", out)
	}

	// Empty → defaults to a valid hex, so the swatch is present.
	m = colorFieldModel("")
	out = strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "\x1b[48;") {
		t.Errorf("empty color defaults to a hex swatch, got:\n%q", out)
	}
}
