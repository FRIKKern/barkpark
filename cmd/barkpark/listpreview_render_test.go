package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/charmbracelet/lipgloss"
)

// list_preview row formatting (Studio parity in the doc-list panes):
//   - declared schema → badge right-aligned dim on the title row, meta dim
//     " · "-joined on the subtitle row;
//   - undeclared schema → rows byte-identical to the pre-list_preview render;
//   - narrow pane → the badge is dropped FIRST (toolbar degradation order).

func docItem(badge, meta string) PaneItem {
	return PaneItem{
		ID: "t1", Title: "Wire the bridge", Icon: "○", Status: "draft",
		Subtitle: "2d ago", Badge: badge, Meta: meta,
	}
}

// legacyDocLines re-derives the exact pre-list_preview row strings from the
// same shared styles renderPaneItem uses, pinning "no declaration → unchanged".
func legacyDocLines(item PaneItem, width int) []string {
	dot := statusStyle(item.Status).Render(item.Icon)
	title := truncate(item.Title, width-6)
	return []string{
		fmt.Sprintf(" %s %s", dot, normalItemStyle.Render(title)),
		fmt.Sprintf("     %s", dimStyle.Render(item.Subtitle)),
	}
}

func TestDocRowWithoutDeclarationIsByteIdentical(t *testing.T) {
	m := model{}
	item := docItem("", "")
	for _, width := range []int{18, 30, 60} {
		got := m.renderPaneItem(item, width, false, false, true)
		want := legacyDocLines(item, width)
		if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
			t.Errorf("width %d: undeclared row diverged\n got %q\nwant %q", width, got, want)
		}
	}
}

func TestDocRowWithBadgeAndMeta(t *testing.T) {
	m := model{}
	got := m.renderPaneItem(docItem("in_progress", "P1"), 50, false, false, true)
	if len(got) != 2 {
		t.Fatalf("want 2 lines, got %d", len(got))
	}

	if !strings.Contains(got[0], "[in_progress]") {
		t.Errorf("title row missing badge: %q", got[0])
	}
	// Right-aligned: the badge's closing bracket sits one slack column in from
	// the row edge, and the row never exceeds the pane width.
	if w := lipgloss.Width(got[0]); w != 50-1 {
		t.Errorf("badge row width = %d, want %d (right-aligned)", w, 49)
	}
	if !strings.Contains(got[1], "2d ago · P1") {
		t.Errorf("subtitle row missing meta: %q", got[1])
	}
}

func TestDocRowMetaWithEmptySubtitle(t *testing.T) {
	m := model{}
	item := docItem("", "P1")
	item.Subtitle = "" // zero UpdatedAt → timeAgo "" — no dangling " · "
	got := m.renderPaneItem(item, 50, false, false, true)
	if !strings.Contains(got[1], "P1") || strings.Contains(got[1], "·") {
		t.Errorf("empty-subtitle meta row wrong: %q", got[1])
	}
}

func TestDocRowDropsBadgeFirstWhenNarrow(t *testing.T) {
	m := model{}
	// width 20: titleMax 14; "[in_progress]"+1 = 14 would leave 0 < 10 title
	// columns → the badge must drop and the row must render exactly as if the
	// schema declared no badge (meta survives — it costs no title columns).
	withBadge := m.renderPaneItem(docItem("in_progress", "P1"), 20, false, false, true)
	noBadge := m.renderPaneItem(docItem("", "P1"), 20, false, false, true)
	if withBadge[0] != noBadge[0] {
		t.Errorf("narrow pane must drop the badge first\n got %q\nwant %q", withBadge[0], noBadge[0])
	}
	if !strings.Contains(withBadge[1], "P1") {
		t.Errorf("meta must survive the narrow pane: %q", withBadge[1])
	}
}

func TestDocRowBadgeKeptAtExactFit(t *testing.T) {
	m := model{}
	// width 30: titleMax 24; badge "[x]"+1 = 4 leaves 20 ≥ 10 → badge renders.
	got := m.renderPaneItem(docItem("x", ""), 30, false, false, true)
	if !strings.Contains(got[0], "[x]") {
		t.Errorf("short badge must render at width 30: %q", got[0])
	}
}

// previewValue resolves a spec against a doc; nil spec / missing value → "".
func TestPreviewValue(t *testing.T) {
	doc := Doc{Extra: map[string]json.RawMessage{
		"lifecycle_status": json.RawMessage(`"in_progress"`),
		"priority":         json.RawMessage(`1`),
	}}

	if got := previewValue(doc, nil); got != "" {
		t.Errorf("nil spec: %q", got)
	}
	if got := previewValue(doc, &apiclient.PreviewSpec{Field: "lifecycle_status"}); got != "in_progress" {
		t.Errorf("badge value: %q", got)
	}
	if got := previewValue(doc, &apiclient.PreviewSpec{Field: "priority", Prefix: "P"}); got != "P1" {
		t.Errorf("prefixed meta: %q", got)
	}
	if got := previewValue(doc, &apiclient.PreviewSpec{Field: "missing", Prefix: "P"}); got != "" {
		t.Errorf("missing field must skip the prefix too: %q", got)
	}
}
