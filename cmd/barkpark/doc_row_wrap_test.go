package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// task-76d8adc13225bc4e: the SELECTED (and inactive-cursor) doc row rendered
// its subtitle through a Width(width) style, which WORD-WRAPS content wider
// than the pane into a multi-line string. One "line" of the list interior then
// held three physical rows, starting at column 0, so every row below shifted
// and the pane's columns broke (measured headless at 160x45 on a seeded blog:
// "0m ago · Server" / "Components + Barkpark =" / "happy cache."). The subtitle
// is now truncated like the title.
func TestDocRowLongSubtitleStaysOneLineInEveryState(t *testing.T) {
	m := model{}
	item := PaneItem{
		ID: "post-rsc", Title: "RSC and headless CMS", Icon: "●", Status: "published",
		Subtitle: "0m ago", Meta: "Server Components + Barkpark = happy cache.",
	}
	const width = 28
	for _, st := range []struct {
		name             string
		selected, cursor bool
	}{
		{"plain", false, false},
		{"selected", true, false},
		{"cursor", false, true},
	} {
		got := m.renderPaneItem(item, width, st.selected, st.cursor, true)
		if len(got) != 2 {
			t.Fatalf("%s: %d lines, want 2", st.name, len(got))
		}
		for i, line := range got {
			if strings.Contains(line, "\n") {
				t.Errorf("%s: line %d wrapped into %d physical rows: %q",
					st.name, i, strings.Count(line, "\n")+1, line)
			}
			if w := lipgloss.Width(line); w > width {
				t.Errorf("%s: line %d is %d columns, pane is %d: %q", st.name, i, w, width, line)
			}
		}
	}
}
