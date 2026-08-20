package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func renderLineage(t *testing.T, attrs map[string]any) string {
	t.Helper()
	reg := testRegistry()
	b := Block{Type: "lineage", Attrs: attrs}
	return ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
}

// TestLineageRenderer proves the lineage block renders THROUGH the registry:
// overline, title, value+unit and body all land, in authored order. One
// assertion set covering both the renderer and its DefaultRegistry
// registration.
func TestLineageRenderer(t *testing.T) {
	got := renderLineage(t, map[string]any{
		"nodes": []any{
			map[string]any{
				"overline": "jan–sep 2025",
				"title":    "nextgen-go-cli",
				"value":    "335",
				"unit":     "commits",
				"body":     "Et kveldsprosjekt med én forfatter.",
			},
			map[string]any{"overline": "2026", "title": "Navnebyttet: Scaffy"},
		},
	})
	for _, want := range []string{
		"jan–sep 2025", "nextgen-go-cli", "335 commits", "Et kveldsprosjekt", "2026", "Navnebyttet: Scaffy",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("lineage render missing %q, got:\n%s", want, got)
		}
	}
	if strings.Index(got, "jan–sep 2025") > strings.Index(got, "2026") {
		t.Fatalf("lineage nodes must keep authored order, got:\n%s", got)
	}
}

// TestLineageRendererEmpty pins the honest empty state: no nodes (or only
// nodes with nothing to say) → the dim `[lineage — no data]` line, never the
// unsupported-block fallback.
func TestLineageRendererEmpty(t *testing.T) {
	for name, attrs := range map[string]map[string]any{
		"no nodes key": {},
		"empty nodes":  {"nodes": []any{}},
		"contentless":  {"nodes": []any{map[string]any{"source": "paper:x", "unit": "ms"}}},
	} {
		if got := renderLineage(t, attrs); !strings.Contains(got, "[lineage — no data]") {
			t.Fatalf("%s: empty lineage should degrade to the dim no-data line, got %q", name, got)
		}
	}
}

// TestLineageRendererKilde pins the kilde law: only datum-bearing nodes (those
// with a `value`) carry the obligation; own `source` wins over sourceDefault;
// an https ref labels with the scheme and trailing slash stripped.
func TestLineageRendererKilde(t *testing.T) {
	got := renderLineage(t, map[string]any{
		"sourceDefault": "paper:scaffy-benchmark",
		"nodes": []any{
			map[string]any{"overline": "jan–sep 2025", "title": "nextgen-go-cli", "value": "335"},
			map[string]any{"overline": "2026", "title": "Navnebyttet"}, // no value → no obligation
			map[string]any{"overline": "i dag", "value": "22", "source": "https://jarl.no/prosjekter/scaffy/"},
		},
	})
	if !strings.Contains(got, "Kilder: paper:scaffy-benchmark · jarl.no/prosjekter/scaffy") {
		t.Fatalf("lineage kilde line wrong, got:\n%s", got)
	}
	if strings.Contains(got, "https://") {
		t.Fatalf("https kilde label must strip the scheme, got:\n%s", got)
	}
}

// TestLineageRendererValuelessNodesStampNoKilde pins the other half of the
// datum law: a lineage of value-less nodes has no provenance obligation, so a
// sourceDefault alone renders NO kilde line.
func TestLineageRendererValuelessNodesStampNoKilde(t *testing.T) {
	got := renderLineage(t, map[string]any{
		"sourceDefault": "paper:scaffy-benchmark",
		"nodes":         []any{map[string]any{"overline": "2026", "title": "Navnebyttet"}},
	})
	if strings.Contains(got, "Kilde") {
		t.Fatalf("value-less nodes must stamp no kilde, got:\n%s", got)
	}
}

// TestLineageRendererInvalidRefRendersNothing pins the invalid-ref law on this
// family member too: `paper:` slugs are lowercase by law, so an uppercase slug
// does not parse and renders no kilde.
func TestLineageRendererInvalidRefRendersNothing(t *testing.T) {
	got := renderLineage(t, map[string]any{
		"nodes": []any{map[string]any{"title": "x", "value": "1", "source": "paper:Not-A-Slug"}},
	})
	if strings.Contains(got, "Kilde") {
		t.Fatalf("invalid source ref must render no kilde, got:\n%s", got)
	}
}
