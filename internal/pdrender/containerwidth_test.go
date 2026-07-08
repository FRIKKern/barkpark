package pdrender

import (
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// Regression tests for three defects the portabledoc-showcase paper surfaced
// (2026-07-08): bordered containers force-wrapping their children (lipgloss
// Width includes padding), multi-line code collapsing to one line under a
// colored profile (whole-source sanitize stripped the newlines), and labeled
// heatmap columns drifting off their header.

var testSGR = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func visible(s string) string { return testSGR.ReplaceAllString(s, "") }

// TestContainerChildrenKeepDeclaredWidth: a card's media-slot image renders as a
// bordered box at the card's inner width; before the Width(inner+2) fix the card
// gave lipgloss only inner-2 content columns, so the image box's border split
// across two lines ("…──╮" wrapping to "─╮"). The card must be exactly
// ctx.Width wide with the inner box intact, and the same holds for the other
// padded-border containers (figure, terminal, task-detail).
func TestContainerChildrenKeepDeclaredWidth(t *testing.T) {
	const W = 80
	ctx := RenderCtx{Width: W, Theme: DarkTheme(), Profile: ANSI256}
	reg := DefaultRegistry(DarkTheme())

	card := Block{Type: "card", Attrs: map[string]any{
		"slots": map[string]any{
			"media": []any{map[string]any{"type": "image", "src": "/x.png", "alt": "sample"}},
			"body":  []any{map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "body"}}}},
		},
	}}
	lines := reg.Render(card, ctx)
	if len(lines) < 4 {
		t.Fatalf("card rendered %d lines", len(lines))
	}
	intactInner := regexp.MustCompile(`│ ╭─+╮ +│`)
	sawInner := false
	for i, l := range lines {
		if w := lipgloss.Width(l); w != W {
			t.Errorf("card line %d width = %d, want %d: %q", i, w, W, visible(l))
		}
		if intactInner.MatchString(visible(l)) {
			sawInner = true
		}
	}
	if !sawInner {
		t.Errorf("card media image box has no intact top border (split across lines?):\n%s", visible(strings.Join(lines, "\n")))
	}

	// The sibling containers share the pattern: everything they emit must land
	// exactly on ctx.Width.
	for name, b := range map[string]Block{
		"figure": {Type: "figure", Attrs: map[string]any{"caption": "cap"},
			Child: &Block{Type: "paragraph", Attrs: map[string]any{"content": []any{map[string]any{"type": "text", "value": "child"}}}}},
		"terminal": {Type: "terminal", Attrs: map[string]any{"title": "t",
			"children": []any{map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "line"}}}}}},
		"task-detail": {Type: "task-detail", Attrs: map[string]any{"task": map[string]any{"title": "a task", "status": "open"}}},
	} {
		for i, l := range reg.Render(b, ctx) {
			if w := lipgloss.Width(l); w != W {
				t.Errorf("%s line %d width = %d, want %d: %q", name, i, w, W, visible(l))
			}
		}
	}
}

// TestMultilineCodeKeepsLines: under a colored profile the chroma path sanitizes
// the WHOLE source before Tokenise; sanitizeCodeText there stripped \n and
// collapsed every multi-line block to one line. The render must carry one line
// per source line, tabs intact.
func TestMultilineCodeKeepsLines(t *testing.T) {
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: ANSI256}
	reg := DefaultRegistry(DarkTheme())
	b := Block{Type: "code", Attrs: map[string]any{
		"lang":  "go",
		"value": "one()\ntwo()\n\tthree()",
	}}
	var body []string
	for _, l := range reg.Render(b, ctx) {
		p := visible(l)
		if strings.Contains(p, "one()") || strings.Contains(p, "two()") || strings.Contains(p, "three()") {
			body = append(body, p)
		}
	}
	if len(body) != 3 {
		t.Fatalf("multi-line code rendered as %d content lines, want 3:\n%s", len(body), strings.Join(body, "\n"))
	}
	if strings.Contains(body[0], "two()") {
		t.Fatalf("source lines merged: %q", body[0])
	}
	if !strings.Contains(body[2], "\tthree()") {
		t.Errorf("tab indentation lost: %q", body[2])
	}
}

// TestHeatmapColumnLabelsAlign: with colLabels each column widens to its label
// (glyph repeated, space-separated) so header and cells share one geometry;
// without colLabels the classic 1-glyph contribution grid is unchanged.
func TestHeatmapColumnLabelsAlign(t *testing.T) {
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}
	reg := DefaultRegistry(DarkTheme())

	labeled := Block{Type: "heatmap", Attrs: map[string]any{
		"cells":     []any{[]any{1.0, 0.5, 0.2}, []any{0.2, 1.0, 0.5}},
		"rowLabels": []any{"aa", "b"},
		"colLabels": []any{"Mon", "Tue", "Wed"},
	}}
	lines := reg.Render(labeled, ctx)
	if len(lines) < 4 {
		t.Fatalf("labeled heatmap rendered %d lines", len(lines))
	}
	head, row1, row2 := visible(lines[0]), visible(lines[1]), visible(lines[2])
	if !strings.Contains(head, "Mon Tue Wed") {
		t.Fatalf("header = %q", head)
	}
	if lipgloss.Width(strings.TrimRight(row1, " ")) != lipgloss.Width(strings.TrimRight(head, " ")) {
		t.Errorf("row width %d != header width %d\nhead: %q\nrow:  %q",
			lipgloss.Width(strings.TrimRight(row1, " ")), lipgloss.Width(strings.TrimRight(head, " ")), head, row1)
	}
	// Row "aa" starts with a full-intensity 3-wide cell under "Mon".
	if !strings.HasPrefix(row1, "aa  ███ ") {
		t.Errorf("labeled cells not widened to their columns: %q", row1)
	}
	if !strings.HasPrefix(row2, "b   ") {
		t.Errorf("row label gutter drifted: %q", row2)
	}

	// No labels → the byte-stable 1-glyph grid.
	bare := Block{Type: "heatmap", Attrs: map[string]any{
		"cells": []any{[]any{1.0, 0.5, 0.2}},
	}}
	bareLines := reg.Render(bare, ctx)
	if got := visible(bareLines[0]); got != "█▒·" {
		t.Errorf("unlabeled grid changed: %q", got)
	}
}
