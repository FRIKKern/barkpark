package pdrender

import "testing"

// TestCodeRendererBlankSourceRendersNothing pins View/TUI parity for a code
// block with no source: the Elixir composer emits nothing for it (#14806), so
// the Go renderer must contribute zero lines — not an empty accent bar. The
// non-blank control proves the guard is keyed on the SOURCE, not on the
// block, so a real snippet still renders (task-841c27ea82903f48).
func TestCodeRendererBlankSourceRendersNothing(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	cases := []struct {
		name   string
		attrs  map[string]any
		blank  bool
	}{
		{"empty code key", map[string]any{"code": ""}, true},
		{"spaces only", map[string]any{"code": "   "}, true},
		{"newline and tab", map[string]any{"code": "\n\t\n"}, true},
		{"legacy value key blank", map[string]any{"value": " \n "}, true},
		{"no source key at all", map[string]any{"language": "go"}, true},
		{"non-blank control", map[string]any{"code": "fmt.Println(1)", "language": "go"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			lines := reg.Render(Block{Type: "code", Attrs: tc.attrs}, ctx)
			if tc.blank && len(lines) != 0 {
				t.Fatalf("blank source rendered %d line(s), want 0: %q", len(lines), lines)
			}
			if !tc.blank && len(lines) == 0 {
				t.Fatalf("non-blank source rendered nothing — the guard is too wide")
			}
		})
	}
}
