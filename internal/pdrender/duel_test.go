package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func renderDuel(t *testing.T, attrs map[string]any) string {
	t.Helper()
	reg := testRegistry()
	b := Block{Type: "duel", Attrs: attrs}
	return ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
}

// TestDuelRenderer proves the duel block renders THROUGH the registry — the
// legend header, the row (label + both display values verbatim + unit), and
// the authored delta line. One assertion set covering both the renderer and
// its DefaultRegistry registration.
func TestDuelRenderer(t *testing.T) {
	got := renderDuel(t, map[string]any{
		"legendA": "Med katalogen",
		"legendB": "Bare hendene",
		"rows": []any{
			map[string]any{"label": "add-error-shape", "delta": "−30 %", "valueA": "1 478", "valueB": "2 121", "unit": "ms"},
		},
	})
	for _, want := range []string{"Med katalogen", "Bare hendene", "add-error-shape", "1 478", "2 121", " vs ", "−30 %", "ms"} {
		if !strings.Contains(got, want) {
			t.Fatalf("duel render missing %q, got:\n%s", want, got)
		}
	}
}

// TestDuelRendererEmpty pins the honest empty state: no rows → the dim
// `[duel — no data]` line, never the unsupported-block fallback.
func TestDuelRendererEmpty(t *testing.T) {
	got := renderDuel(t, map[string]any{"legendA": "A", "legendB": "B"})
	if !strings.Contains(got, "[duel — no data]") {
		t.Fatalf("empty duel should degrade to the dim no-data line, got %q", got)
	}
}

// TestDuelRendererLegendsRequired pins the "both legends REQUIRED" law: rows
// without a named arm B are a meaningless comparison → the no-data degrade.
func TestDuelRendererLegendsRequired(t *testing.T) {
	got := renderDuel(t, map[string]any{
		"legendA": "Med katalogen",
		"rows":    []any{map[string]any{"label": "x", "valueA": "1", "valueB": "2"}},
	})
	if !strings.Contains(got, "[duel — no data]") {
		t.Fatalf("duel without legendB should degrade, got %q", got)
	}
}

// TestDuelRendererKilde pins the kilde law: a datum row's commit ref labels as
// "commit:" + first 7 hex; per-row source and the block sourceDefault dedup by
// RAW ref in first-use order under the plural "Kilder".
func TestDuelRendererKilde(t *testing.T) {
	got := renderDuel(t, map[string]any{
		"legendA":       "A",
		"legendB":       "B",
		"sourceDefault": "commit:591fdcd53",
		"rows": []any{
			map[string]any{"label": "a", "valueA": "1", "valueB": "2"},
			map[string]any{"label": "b", "valueA": "3", "valueB": "4", "source": "task:jdf-bl-historiene"},
			map[string]any{"label": "c", "valueA": "5", "valueB": "6"}, // sourceDefault again → deduped
		},
	})
	if !strings.Contains(got, "Kilder: commit:591fdcd · task:jdf-bl-historiene") {
		t.Fatalf("duel kilde line wrong, got:\n%s", got)
	}
	if strings.Count(got, "commit:591fdcd") != 1 {
		t.Fatalf("duel kilde must dedup by raw ref, got:\n%s", got)
	}
}

// TestDuelRendererKildeSingular pins the singular word: ONE valid ref → "Kilde".
func TestDuelRendererKildeSingular(t *testing.T) {
	got := renderDuel(t, map[string]any{
		"legendA": "A",
		"legendB": "B",
		"rows":    []any{map[string]any{"label": "a", "valueA": "1", "valueB": "2", "source": "paper:scaffy-benchmark"}},
	})
	if !strings.Contains(got, "Kilde: paper:scaffy-benchmark") {
		t.Fatalf("duel singular kilde wrong, got:\n%s", got)
	}
	if strings.Contains(got, "Kilder") {
		t.Fatalf("one ref must use the singular word, got:\n%s", got)
	}
}

// TestDuelRendererInvalidRefRendersNothing pins the invalid-ref law: a ref
// that does not parse is not evidence — no kilde line at all.
func TestDuelRendererInvalidRefRendersNothing(t *testing.T) {
	got := renderDuel(t, map[string]any{
		"legendA": "A",
		"legendB": "B",
		"rows":    []any{map[string]any{"label": "a", "valueA": "1", "valueB": "2", "source": "commit:XYZ"}},
	})
	if strings.Contains(got, "Kilde") {
		t.Fatalf("invalid source ref must render no kilde, got:\n%s", got)
	}
}
