package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Diff-view pins (TUI long-tail, 2026-06-11): buildDiffLines compares the
// editor's dirty-aware values to the published twin per schema field;
// renderDiffView windows the rows through diffScroll.

func diffModel() model {
	return model{
		selectedDoc: &Doc{
			ID:     "drafts.p1",
			Title:  "New Title",
			Status: "draft",
			Values: map[string]string{"category": "Tech", "author": "Knut"},
		},
		editorSchema: &apiclient.Schema{
			Name: "post",
			Fields: []Field{
				{Name: "title", Title: "Title", Type: FieldString},
				{Name: "category", Title: "Category", Type: FieldString},
				{Name: "author", Title: "Author", Type: FieldString},
			},
		},
		width:  100,
		height: 40,
	}
}

func TestBuildDiffLinesChangedAndUnchanged(t *testing.T) {
	m := diffModel()
	pub := Doc{
		ID:     "p1",
		Title:  "Old Title",
		Status: "published",
		Values: map[string]string{"category": "Tech", "author": "Ibsen"},
	}

	out := strings.Join(m.buildDiffLines(&pub), "\n")

	// Changed fields show published as `-` and draft as `+`.
	for _, want := range []string{"- Old Title", "+ New Title", "- Ibsen", "+ Knut"} {
		if !strings.Contains(out, want) {
			t.Errorf("diff missing %q in:\n%s", want, out)
		}
	}
	// Unchanged category collapses to the count line, not a -/+ pair.
	if strings.Contains(out, "- Tech") || strings.Contains(out, "+ Tech") {
		t.Errorf("unchanged field must not diff:\n%s", out)
	}
	if !strings.Contains(out, "1 field(s) unchanged") {
		t.Errorf("unchanged count missing in:\n%s", out)
	}
}

func TestBuildDiffLinesDirtyAwareAndEmptyMarkers(t *testing.T) {
	m := diffModel()
	// An unsaved edit must diff as the draft side (what ctrl+s then ctrl+p ships).
	m.dirtyValues = map[string]string{"author": ""}
	pub := Doc{ID: "p1", Title: "New Title", Values: map[string]string{"category": "Tech", "author": "Ibsen"}}

	out := strings.Join(m.buildDiffLines(&pub), "\n")
	if !strings.Contains(out, "- Ibsen") || !strings.Contains(out, "+ (empty)") {
		t.Errorf("cleared dirty value should diff to (empty), got:\n%s", out)
	}
}

func TestBuildDiffLinesIdentical(t *testing.T) {
	m := diffModel()
	pub := Doc{ID: "p1", Title: "New Title", Values: map[string]string{"category": "Tech", "author": "Knut"}}
	out := strings.Join(m.buildDiffLines(&pub), "\n")
	if !strings.Contains(out, "identical") {
		t.Errorf("identical docs should say so, got:\n%s", out)
	}
}

func TestOpenDiffViewGuards(t *testing.T) {
	// Published doc → no modal, status explains (no fetch needed).
	m := diffModel()
	m.selectedDoc.ID = "p1"
	m.openDiffView()
	if m.diffOpen {
		t.Error("diff must not open on a published doc")
	}
	if !strings.Contains(m.status, "published doc") {
		t.Errorf("status should explain, got %q", m.status)
	}

	// Draft whose twin 404s → no modal, "never published" status.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	m = diffModel()
	m.ds = apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	m.openDiffView()
	if m.diffOpen {
		t.Error("diff must not open without a published twin")
	}
	if !strings.Contains(m.status, "never published") {
		t.Errorf("status should explain, got %q", m.status)
	}

	// Draft with a real twin → modal opens with diff rows.
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"result":{"_id":"p1","_type":"post","title":"Old Title","status":"published","category":"Tech","author":"Knut"}}`))
	}))
	defer srv2.Close()

	m = diffModel()
	m.ds = apiclient.New(apiclient.Config{BaseURL: srv2.URL, Token: "t"})
	m.openDiffView()
	if !m.diffOpen {
		t.Fatalf("diff should open for a draft with a twin (status %q)", m.status)
	}
	joined := strings.Join(m.diffLines, "\n")
	if !strings.Contains(joined, "- Old Title") || !strings.Contains(joined, "+ New Title") {
		t.Errorf("diff lines missing title change:\n%s", joined)
	}
}

func TestRenderDiffViewWindowsAndScrolls(t *testing.T) {
	m := diffModel()
	m.diffOpen = true
	for i := 0; i < 60; i++ {
		m.diffLines = append(m.diffLines, "row")
	}

	out := m.renderDiffView(100, 30)
	if !strings.Contains(out, "Diff: New Title") {
		t.Errorf("diff header missing:\n%s", out)
	}
	if !strings.Contains(out, "more") {
		t.Errorf("overflow indicator missing for 60 rows in a 30-high view:\n%s", out)
	}

	// Scrolled to the end: no overflow indicator.
	m.diffScroll = len(m.diffLines) - 1
	out = m.renderDiffView(100, 30)
	if strings.Contains(out, "more") {
		t.Errorf("scrolled-to-end view must not claim more rows:\n%s", out)
	}
}
