package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/charmbracelet/x/ansi"
)

// Pins for the TUI polish items found dogfooding against a fresh local
// instance (task-9be0f23801649e71).

// The toolbar advertised a "Vision" tab that no key reaches. The TUI has one
// view, so the toolbar names only Structure.
func TestToolbarNamesOnlyReachableViews(t *testing.T) {
	m := model{width: 120, ds: apiclient.New(apiclient.Config{Workspace: "default", Project: "default", Dataset: "production"})}
	out := ansi.Strip(m.renderToolbar())
	if !strings.Contains(out, "[Structure]") {
		t.Errorf("toolbar should name the Structure view; got %q", out)
	}
	if strings.Contains(out, "Vision") {
		t.Errorf("toolbar must not advertise a view no key opens; got %q", out)
	}
}

// The key column was a fixed 14 columns, so the 18-column key
// "j / k · ctrl+d / u" ran into its description, and a narrow terminal cut the
// scope-selector row mid-sentence. The column now fits the longest key, and a
// long description wraps under the description column.
func TestHelpOverlayRowsRenderWhole(t *testing.T) {
	for _, width := range []int{100, 80, 60} {
		m := model{helpOpen: true, width: width}
		out := ansi.Strip(m.renderHelpOverlay(width, 200))
		for _, line := range strings.Split(out, "\n") {
			if w := ansi.StringWidth(line); w > width {
				t.Errorf("width %d: line is %d columns wide: %q", width, w, line)
			}
		}
		flat := strings.Join(strings.Fields(strings.ReplaceAll(out, "│", " ")), " ")
		for _, want := range []string{
			"j / k · ctrl+d / u scroll · half page",
			"create workspace / project (server slugs the name)",
		} {
			if !strings.Contains(flat, want) {
				t.Errorf("width %d: help overlay should render %q whole; got:\n%s", width, want, out)
			}
		}
	}
}

// Lucide icon NAMES ("book", "terminal") printed as words beside the title.
// A known name maps to a glyph and an unknown name to a neutral one.
func TestStructureIconNamesNeverPrintAsText(t *testing.T) {
	cases := map[string]string{
		"book":         "📖",
		"terminal":     "⌨",
		"no-such-icon": iconFallback,
		"📄":            "📄",
		"":             "",
	}
	for in, want := range cases {
		if got := terminalIcon(in); got != want {
			t.Errorf("terminalIcon(%q) = %q, want %q", in, got, want)
		}
	}

	m := model{}
	for _, item := range []PaneItem{{Title: "Book", Icon: "book"}, {Title: "Commands", Icon: "terminal"}} {
		row := ansi.Strip(strings.Join(m.renderPaneItem(item, 30, false, false, false), "\n"))
		if strings.Contains(row, item.Icon+" ") {
			t.Errorf("structure row printed the icon name %q as text: %q", item.Icon, row)
		}
	}
}

// A post whose schema "status" field says "archived" while the document is
// published used to read "[archived]" with a neutral dot. The badge and dot
// now show the publish state, and the content status follows as its own label.
func TestEditorHeaderShowsPublishStateOverContentStatus(t *testing.T) {
	var doc Doc
	if err := json.Unmarshal([]byte(`{
		"_id": "post-1", "_type": "post", "_draft": false,
		"title": "Old news", "status": "archived"
	}`), &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got := publishState(&doc); got != "published" {
		t.Fatalf("publishState = %q, want published", got)
	}
	if got := statusIcon(publishState(&doc)); got != "●" {
		t.Errorf("list dot = %q, want the published dot", got)
	}

	m := model{selectedDoc: &doc, editorSchema: &Schema{Name: "post", Title: "Posts"}}
	header := ansi.Strip(strings.SplitN(m.buildEditorContent(80), "\n", 2)[0])
	if !strings.Contains(header, "[published]") || !strings.Contains(header, "status: archived") {
		t.Errorf("header should show publish state and the content status apart; got %q", header)
	}
	if strings.Contains(header, "[archived]") {
		t.Errorf("content status must not take the publish badge; got %q", header)
	}

	// A content status equal to the publish state is not repeated.
	doc.Values["status"] = "published"
	header = ansi.Strip(strings.SplitN(m.buildEditorContent(80), "\n", 2)[0])
	if strings.Contains(header, "status:") {
		t.Errorf("matching content status should not repeat; got %q", header)
	}

	// Publish and unpublish flips keep the content status and move the badge.
	setPublishState(&doc, "draft")
	if publishState(&doc) != "draft" || doc.Values["status"] != "published" {
		t.Errorf("unpublish flip: state=%q content=%q", publishState(&doc), doc.Values["status"])
	}
}

// A schema with no "status" field of its own keeps Doc.Status as the publish
// state, the contract hand-built documents and older envelopes rely on.
func TestPublishStateWithoutContentStatusReadsStatus(t *testing.T) {
	d := &Doc{ID: "x", Status: "draft"}
	if got := publishState(d); got != "draft" {
		t.Errorf("publishState = %q, want draft", got)
	}
	setPublishState(d, "published")
	if d.Status != "published" {
		t.Errorf("flip should set Status, got %q", d.Status)
	}
}
