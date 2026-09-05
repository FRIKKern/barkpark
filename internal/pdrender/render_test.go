package pdrender

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// IMPORT-CLEANLINESS INVARIANT (asserted by the verify grep, documented here):
// this package imports ONLY lipgloss + x/ansi + the stdlib. No import of
// github.com/FRIKKern/barkpark (main/TUI model) or internal/apiclient appears
// anywhere under internal/pdrender. See `go list -deps` in the verify step.

var update = flag.Bool("update", false, "regenerate golden files")

// goldenWidths are the column widths every fixture is rendered at.
var goldenWidths = []int{40, 60, 80, 120}

// testRegistry builds a deterministic registry. We force NoColor so the raw
// render carries no ANSI (goldens stay readable) and pin the dark theme so the
// AdaptiveColor resolution is stable regardless of the host terminal.
func testRegistry() *Registry {
	// lipgloss color profile is process-global; pin it to Ascii (no color) so
	// styles render as plain text and goldens are byte-stable in CI. The termenv
	// enum is INVERTED (TrueColor=0, ANSI256=1, ANSI=2, Ascii=3) — Ascii is 3, NOT
	// 0. (The old `SetColorProfile(0)` here was TrueColor; goldens stayed stable
	// only because renderFixture ansi.Strips the output regardless.)
	lipgloss.SetColorProfile(3) // termenv.Ascii == 3 → strips all color/style
	return DefaultRegistry(DarkTheme())
}

func renderFixture(t *testing.T, name string, width int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	reg := testRegistry()
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	out := reg.RenderDoc(blocks, ctx)
	// Strip any residual ANSI for a readable, diffable golden.
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

func TestGolden(t *testing.T) {
	fixtures := []string{"sample.json", "internal_links.json"}
	for _, fx := range fixtures {
		for _, w := range goldenWidths {
			fx, w := fx, w
			name := strings.TrimSuffix(fx, ".json")
			t.Run(name+"_w"+itoa(w), func(t *testing.T) {
				got := renderFixture(t, fx, w)
				goldenPath := filepath.Join("testdata", "golden", name+"_w"+itoa(w)+".txt")
				if *update {
					if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
						t.Fatal(err)
					}
					return
				}
				want, err := os.ReadFile(goldenPath)
				if err != nil {
					t.Fatalf("read golden (run with -update to create): %v", err)
				}
				if got != string(want) {
					t.Errorf("render mismatch for %s at width %d\n--- got ---\n%s\n--- want ---\n%s",
						fx, w, got, string(want))
				}
			})
		}
	}
}

// TestUnknownBlockFallback asserts an unhandled block type yields the labeled
// fallback box (no panic), so a forward-compatible document degrades instead of
// crashing the reader.
func TestUnknownBlockFallback(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	blocks := []Block{{Type: "future-widget", Attrs: map[string]any{"type": "future-widget"}}}

	var out string
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("fallback panicked: %v", r)
			}
		}()
		out = reg.RenderDoc(blocks, ctx)
	}()

	stripped := ansi.Strip(out)
	if !strings.Contains(stripped, "unknown block: future-widget") {
		t.Errorf("expected fallback label, got:\n%s", stripped)
	}
}

// TestLinkProfiles checks OSC8 emission gates on profile.
func TestLinkProfiles(t *testing.T) {
	reg := testRegistry()
	nodes := []any{
		map[string]any{
			"type":     "link",
			"href":     "https://example.com",
			"children": []any{map[string]any{"type": "text", "value": "go"}},
		},
	}

	// High profile → OSC 8 escape present.
	hi := reg.Inline(nodes, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: TrueColor})
	if !strings.Contains(hi, "\x1b]8;;https://example.com\x1b\\") {
		t.Errorf("expected OSC8 hyperlink in TrueColor profile, got %q", hi)
	}

	// Low profile → dim " (href)" suffix instead.
	lo := reg.Inline(nodes, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
	if strings.Contains(lo, "\x1b]8;;") {
		t.Errorf("did not expect OSC8 in NoColor profile, got %q", lo)
	}
	if !strings.Contains(ansi.Strip(lo), "(https://example.com)") {
		t.Errorf("expected dim href suffix in NoColor profile, got %q", ansi.Strip(lo))
	}
}

// TestNestedLinkFlattens verifies the model's non-recursive link rule: a link
// inside a link flattens to plain (no second OSC8 wrapper for the inner href).
func TestNestedLinkFlattens(t *testing.T) {
	reg := testRegistry()
	nodes := []any{
		map[string]any{
			"type": "link",
			"href": "https://outer.example",
			"children": []any{
				map[string]any{
					"type":     "link",
					"href":     "https://inner.example",
					"children": []any{map[string]any{"type": "text", "value": "x"}},
				},
			},
		},
	}
	out := reg.Inline(nodes, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: TrueColor})
	if strings.Contains(out, "inner.example") {
		t.Errorf("inner link href should have flattened away, got %q", out)
	}
	if !strings.Contains(out, "outer.example") {
		t.Errorf("outer link href should survive, got %q", out)
	}
}
