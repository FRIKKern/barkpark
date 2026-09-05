package pdrender

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// stubCodelistResolver is the caller-supplied codelist seam under test: it maps
// the fixture's (onixedit, issue 73, FBA) tuple → a human Thema label. Mirrors
// how the OnixEdit plugin would inject &Content.codelist_label.
func stubCodelistResolver(plugin, issue, code string) string {
	if plugin == "onixedit" && issue == "73" && code == "FBA" {
		return "Modern & contemporary fiction"
	}
	return "" // unresolved → renderer falls back to the raw code
}

// renderM2Fixture renders the M2 fixture with NoColor pinned (byte-stable
// goldens) AND both resolvers wired so codelist resolves a label and any
// reference would resolve a title. V2AsJSON stays false (the flat-summary
// default under test).
func renderM2Fixture(t *testing.T, name string, width int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	reg := testRegistry() // pins lipgloss to Ascii (NoColor)
	ctx := RenderCtx{
		Width:            width,
		Theme:            DarkTheme(),
		Profile:          NoColor,
		RefResolver:      stubRefResolver,
		CodelistResolver: stubCodelistResolver,
	}
	out := reg.RenderDoc(blocks, ctx)
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM2 renders the M2 block fixture at every golden width and diffs it
// against the checked-in golden (regenerate with -update).
func TestGoldenM2(t *testing.T) {
	const fx = "sample_m2.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM2Fixture(t, fx, w)
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
				t.Errorf("M2 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestM2BlocksNeverPanic asserts every new M2 block type renders without panic,
// including degenerate empties (the never-crash contract). It renders each block
// at a tiny width (forcing the below-MinWidth flat path) and a normal width.
func TestM2BlocksNeverPanic(t *testing.T) {
	reg := testRegistry()
	blocks := []Block{
		{Type: "diagram", Attrs: map[string]any{"type": "diagram"}},
		{Type: "diagram", Attrs: map[string]any{"type": "diagram", "source": "graph LR\n  A-->B", "caption": "c"}},
		{Type: "asciicast", Attrs: map[string]any{"type": "asciicast"}},
		{Type: "asciicast", Attrs: map[string]any{"type": "asciicast", "src": "https://x/y.cast", "duration": 9, "cols": 80, "rows": 24}},
		{Type: "image", Attrs: map[string]any{"type": "image"}},
		{Type: "image", Attrs: map[string]any{"type": "image", "src": "https://x/y.png", "alt": "a", "width": 10, "height": 20}},
		{Type: "composite", Attrs: map[string]any{"type": "composite", "label": "C"}},
		{Type: "arrayOf", Attrs: map[string]any{"type": "arrayOf", "label": "A"}},
		{Type: "codelist", Attrs: map[string]any{"type": "codelist", "label": "K"}},
		{Type: "localizedText", Attrs: map[string]any{"type": "localizedText", "label": "L"}},
		{Type: "form", Attrs: map[string]any{"type": "form"}},
		{Type: "questionnaire", Attrs: map[string]any{"type": "questionnaire", "questions": []any{
			map[string]any{"id": "q", "type": "weird-unknown-type", "prompt": "p"},
		}}},
	}
	for _, b := range blocks {
		b := b
		for _, w := range []int{10, 80} {
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("%s at width %d panicked: %v", b.Type, w, r)
					}
				}()
				_ = reg.RenderDoc([]Block{b}, RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor})
			}()
		}
	}
}

// TestCodelistResolverFires asserts the injected CodelistResolver wins, with
// raw-code and em-dash fallbacks — the codelist twin of TestFieldReferenceResolver.
func TestCodelistResolverFires(t *testing.T) {
	reg := testRegistry()
	mk := func(code string) Block {
		return Block{Type: "codelist", Attrs: map[string]any{
			"type": "codelist", "label": "Thema", "plugin": "onixedit", "codelistId": "73", "value": code,
		}}
	}

	// Resolver present + a resolvable code → the human label.
	withRes := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor, CodelistResolver: stubCodelistResolver}
	got := ansi.Strip(strings.Join(reg.Render(mk("FBA"), withRes), "\n"))
	if !strings.Contains(got, "Modern & contemporary fiction") {
		t.Errorf("expected resolved codelist label, got %q", got)
	}

	// Resolver present but UNRESOLVABLE code → raw code (resolver returned "").
	got = ansi.Strip(strings.Join(reg.Render(mk("ZZZ"), withRes), "\n"))
	if !strings.Contains(got, "ZZZ") {
		t.Errorf("expected raw-code fallback for unresolved code, got %q", got)
	}

	// No resolver → raw code.
	noRes := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	got = ansi.Strip(strings.Join(reg.Render(mk("FBA"), noRes), "\n"))
	if !strings.Contains(got, "FBA") {
		t.Errorf("expected raw-code fallback with no resolver, got %q", got)
	}

	// Empty code → em-dash.
	got = ansi.Strip(strings.Join(reg.Render(mk(""), withRes), "\n"))
	if !strings.Contains(got, "—") {
		t.Errorf("expected em-dash for empty code, got %q", got)
	}
}

// TestCompositeFlattening asserts the composite renderer flattens each subfield
// to "<title>: <scalar>", with nested map/list values flattened to "k: v, …".
func TestCompositeFlattening(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "composite", Attrs: map[string]any{
		"type":  "composite",
		"label": "Dimensions",
		"fields": []any{
			map[string]any{"name": "width", "title": "Width"},
			map[string]any{"name": "meta"}, // no title → falls back to name
			map[string]any{"name": "missing", "title": "Missing"},
		},
		"value": map[string]any{
			"width": 19.5,
			"meta":  map[string]any{"unit": "cm", "scale": 1.0},
			// "missing" absent → em-dash
		},
	}}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	got := ansi.Strip(strings.Join(reg.Render(block, ctx), "\n"))

	if !strings.Contains(got, "Width: 19.5") {
		t.Errorf("expected scalar subfield row, got:\n%s", got)
	}
	// Nested map flattens with sorted keys: scale before unit.
	if !strings.Contains(got, "meta: scale: 1, unit: cm") {
		t.Errorf("expected flattened nested-map row, got:\n%s", got)
	}
	if !strings.Contains(got, "Missing: —") {
		t.Errorf("expected em-dash for an absent subfield, got:\n%s", got)
	}
}

// TestArrayOfEmptyEmDash asserts an empty arrayOf renders a single "—" row.
func TestArrayOfEmptyEmDash(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "arrayOf", Attrs: map[string]any{
		"type": "arrayOf", "label": "Tags", "value": []any{},
	}}
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	got := ansi.Strip(strings.Join(reg.Render(block, ctx), "\n"))
	if !strings.Contains(got, "—") {
		t.Errorf("expected em-dash for empty arrayOf, got:\n%s", got)
	}
}

// TestV2AsJSONOptOut asserts the V2AsJSON flag flips composite to a JSON dump
// (and that the default is the flat summary, NOT the dump).
func TestV2AsJSONOptOut(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "composite", Attrs: map[string]any{
		"type":   "composite",
		"label":  "Dimensions",
		"fields": []any{map[string]any{"name": "width", "title": "Width"}},
		"value":  map[string]any{"width": 19.5},
	}}

	// Default (flat summary): the "<title>: <scalar>" row, no JSON braces.
	def := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if strings.Contains(def, "{") {
		t.Errorf("default should be flat summary (no JSON), got:\n%s", def)
	}
	if !strings.Contains(def, "Width: 19.5") {
		t.Errorf("default flat summary missing the subfield row, got:\n%s", def)
	}

	// V2AsJSON: a JSON dump of the value (braces present).
	js := ansi.Strip(strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor, V2AsJSON: true}), "\n"))
	if !strings.Contains(js, "{") || !strings.Contains(js, "\"width\"") {
		t.Errorf("V2AsJSON should dump JSON, got:\n%s", js)
	}
}

// TestAsciicastOSC8Gating checks the asciicast placeholder emits an OSC8 link at
// a high profile and a dim " (src)" suffix at NoColor — the same honesty gate
// the action CTA + inline link use.
func TestAsciicastOSC8Gating(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "asciicast", Attrs: map[string]any{
		"type": "asciicast", "src": "https://x.example/demo.cast", "duration": 42, "cols": 80, "rows": 24,
	}}

	hi := strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: TrueColor}), "\n")
	if !strings.Contains(hi, "\x1b]8;;https://x.example/demo.cast\x1b\\") {
		t.Errorf("expected OSC8 link at TrueColor, got %q", hi)
	}

	lo := strings.Join(reg.Render(block, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n")
	if strings.Contains(lo, "\x1b]8;;") {
		t.Errorf("did not expect OSC8 at NoColor, got %q", lo)
	}
	stripped := ansi.Strip(lo)
	if !strings.Contains(stripped, "(https://x.example/demo.cast)") {
		t.Errorf("expected dim src suffix at NoColor, got %q", stripped)
	}
	// Metadata suffix present: "0:42 · 80x24".
	if !strings.Contains(stripped, "0:42") || !strings.Contains(stripped, "80x24") {
		t.Errorf("expected duration + dims in the asciicast meta, got %q", stripped)
	}
}

// TestDiagramKindDetection asserts mermaidKind reads the kind keyword from the
// first non-directive source line, skipping init directives / front-matter.
func TestDiagramKindDetection(t *testing.T) {
	cases := map[string]string{
		"flowchart TD\n  A-->B":                  "flowchart",
		"graph LR\n  A-->B":                      "graph",
		"sequenceDiagram\n  A->>B: hi":           "sequenceDiagram",
		"%%{init: {'theme':'x'}}%%\ngraph TD\nA": "graph",
		"":                                       "diagram",
		"   ":                                    "diagram",
	}
	for src, want := range cases {
		if got := mermaidKind(src); got != want {
			t.Errorf("mermaidKind(%q) = %q, want %q", src, got, want)
		}
	}
}
