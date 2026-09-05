package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The inline live-value seam (lvw-t1, wire §3/§6/§9): ValueResolver turns a
// valueref node into the CURRENT canonical value; everything else (nil
// resolver, "" miss, malformed node) degrades to the node's pinned `fallback`
// literal — never an error, never a blank. Golden cases come VERBATIM from the
// shared fixture home (fixtures/portable-doc-inline/, mirrored in
// testdata/portable-doc-inline/ — the same JSON the api and web suites consume).

// valuerefFixture is the shared golden shape: `values` (target → flat
// envelope) drives the stub resolver; a MISSING `values` key means "no
// resolver wired at all".
type valuerefFixture struct {
	Case          string                    `json:"case"`
	Values        map[string]map[string]any `json:"values"`
	HasValues     bool                      `json:"-"`
	Block         json.RawMessage           `json:"block"`
	ExpectVisible string                    `json:"expect_visible"`
	ExpectAbsent  string                    `json:"expect_absent"`
}

func loadValuerefFixture(t *testing.T, name string) valuerefFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "portable-doc-inline", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	var fx valuerefFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode fixture %s: %v", name, err)
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err == nil {
		_, fx.HasValues = probe["values"]
	}
	return fx
}

// renderValuerefFixture renders the fixture's single block through the
// pinned-NoColor registry (the chipDoc pattern) and returns ANSI-stripped text.
func renderValuerefFixture(t *testing.T, fx valuerefFixture) string {
	t.Helper()
	blocks, err := Decode(json.RawMessage("[" + string(fx.Block) + "]"))
	if err != nil {
		t.Fatalf("decode block: %v", err)
	}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	if fx.HasValues {
		values := fx.Values
		ctx.ValueResolver = func(target, field string) string {
			if env, ok := values[target]; ok {
				if s, ok := env[field].(string); ok {
					return s
				}
			}
			return ""
		}
	}
	stripped := ansi.Strip(testRegistry().RenderDoc(blocks, ctx))
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, "valueref/"+fx.Case, stripped)
	return stripped
}

func TestValuerefGoldenFixtures(t *testing.T) {
	for _, name := range []string{
		"valueref-resolved.json",
		"valueref-unresolved-fallback.json",
		"valueref-missing-resolver.json",
	} {
		t.Run(name, func(t *testing.T) {
			fx := loadValuerefFixture(t, name)
			out := renderValuerefFixture(t, fx)
			if !strings.Contains(out, fx.ExpectVisible) {
				t.Fatalf("%s: expected visible %q, got: %q", fx.Case, fx.ExpectVisible, out)
			}
			if strings.Contains(out, fx.ExpectAbsent) {
				t.Fatalf("%s: %q must NOT render (D6: children/stale value ignored), got: %q",
					fx.Case, fx.ExpectAbsent, out)
			}
		})
	}
}

// Wire §9 (5): the safety node is CHILDLESS and the assertion is VISIBLE
// fallback text — a with-children node (or a bare no-crash check) passes
// vacuously against Go's historical blank for childless unknowns.
func TestValuerefChildlessRendersFallbackVisibly(t *testing.T) {
	blocks := []Block{{
		ID:   "b1",
		Type: "paragraph",
		Attrs: map[string]any{"content": []any{map[string]any{
			"type": "valueref", "target": "launch-metrics",
			"field": "launch_delay", "fallback": "12 weeks",
		}}},
	}}
	out := ansi.Strip(testRegistry().RenderDoc(blocks, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}))
	if !strings.Contains(out, "12 weeks") {
		t.Fatalf("childless valueref must show its fallback VISIBLY, got: %q", out)
	}
}

// The "" return is the miss convention (v2fields.go): empty string → fallback,
// exactly like a nil resolver.
func TestValuerefEmptyResolverReturnFallsBack(t *testing.T) {
	blocks := []Block{{
		ID:   "b1",
		Type: "paragraph",
		Attrs: map[string]any{"content": []any{map[string]any{
			"type": "valueref", "target": "t", "field": "f", "fallback": "pinned",
		}}},
	}}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor,
		ValueResolver: func(string, string) string { return "" }}
	out := ansi.Strip(testRegistry().RenderDoc(blocks, ctx))
	if !strings.Contains(out, "pinned") {
		t.Fatalf("empty resolver return must degrade to fallback, got: %q", out)
	}
}

// Wire §3: `field` is a single top-level name — a dot-path never reaches the
// resolver (fallback), so resolver and visibility gate can never disagree on
// the segment being read.
func TestValuerefDotPathFieldNeverResolves(t *testing.T) {
	blocks := []Block{{
		ID:   "b1",
		Type: "paragraph",
		Attrs: map[string]any{"content": []any{map[string]any{
			"type": "valueref", "target": "t", "field": "a.b", "fallback": "pinned",
		}}},
	}}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor,
		ValueResolver: func(target, field string) string {
			t.Fatalf("resolver must not be called for dot-path field, got (%q,%q)", target, field)
			return ""
		}}
	out := ansi.Strip(testRegistry().RenderDoc(blocks, ctx))
	if !strings.Contains(out, "pinned") {
		t.Fatalf("dot-path field must degrade to fallback, got: %q", out)
	}
}

// Wire §9 (6): a hostile canonical value carrying raw terminal escape bytes
// renders INERT — sanitizeText strips the C0 controls so the value cannot
// repaint or hijack the reader's terminal.
func TestValuerefInjectionRendersInert(t *testing.T) {
	blocks := []Block{{
		ID:   "b1",
		Type: "paragraph",
		Attrs: map[string]any{"content": []any{map[string]any{
			"type": "valueref", "target": "t", "field": "f", "fallback": "fb",
		}}},
	}}
	hostile := "<script>alert(1)</script>\x1b[2Jsafe"
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor,
		ValueResolver: func(string, string) string { return hostile }}
	out := testRegistry().RenderDoc(blocks, ctx) // NOT stripped — assert raw bytes
	if strings.Contains(out, "\x1b[2J") {
		t.Fatalf("raw ESC sequence must be stripped, got: %q", out)
	}
	if !strings.Contains(ansi.Strip(out), "safe") {
		t.Fatalf("the sanitized remainder must still render, got: %q", out)
	}
}

// Again-unknown safety (wire §6/§9): a future inline type with a D6-style
// dual-written text child renders that child VISIBLY; a childless one renders
// nothing — and neither crashes.
func TestAgainUnknownInlineTypeDegrades(t *testing.T) {
	blocks := []Block{{
		ID:   "b1",
		Type: "paragraph",
		Attrs: map[string]any{"content": []any{
			map[string]any{"type": "some-2027-node", "children": []any{
				map[string]any{"type": "text", "value": "dual-written fallback"},
			}},
			map[string]any{"type": "some-childless-2027-node"},
		}},
	}}
	out := ansi.Strip(testRegistry().RenderDoc(blocks, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}))
	if !strings.Contains(out, "dual-written fallback") {
		t.Fatalf("unknown-with-children must render its children, got: %q", out)
	}
}
