package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// Bulk publish/unpublish pins (Studio-E3 parity, 2026-06-11): space marks
// doc-list rows by BARE published id, ctrl+p/U run the action over the set
// (each id individually; partial failure reported with the first error),
// marks survive the draft↔published id flip and clear after the action.

func bulkModel() model {
	node := &StructureNode{TypeName: "post"}
	return model{
		focus: focusState{Target: FocusPane, PaneIndex: 0},
		panes: []Pane{{
			Node:      node,
			IsDocList: true,
			Items: []PaneItem{
				{ID: "drafts.p1", Doc: &Doc{ID: "drafts.p1", Status: "draft"}, SourceNode: node},
				{ID: "drafts.p2", Doc: &Doc{ID: "drafts.p2", Status: "draft"}, SourceNode: node},
				{ID: "p3", Doc: &Doc{ID: "p3", Status: "published"}, SourceNode: node},
			},
		}},
		width:  100,
		height: 40,
	}
}

func TestToggleMarkKeysOnBareID(t *testing.T) {
	m := bulkModel()

	m.toggleMark() // cursor 0 → drafts.p1 marks as p1
	if m.marked["p1"] != "post" {
		t.Fatalf("marked = %v, want p1→post", m.marked)
	}

	m.toggleMark() // same row unmarks
	if len(m.marked) != 0 {
		t.Errorf("toggle should unmark, got %v", m.marked)
	}

	// Non-doc rows never mark.
	m.panes[0].Items[0].Doc = nil
	m.toggleMark()
	if len(m.marked) != 0 {
		t.Errorf("structure rows must not mark, got %v", m.marked)
	}
}

func TestBulkPublishPartialFailure(t *testing.T) {
	var published []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			// refreshDocViews re-queries the panes after the action.
			_, _ = w.Write([]byte(`{"result":{"documents":[],"count":0}}`))
			return
		}
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Mutations []map[string]map[string]string `json:"mutations"`
		}
		_ = json.Unmarshal(body, &req)
		id := req.Mutations[0]["publish"]["id"]
		if id == "p2" {
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"error":"boom"}`))
			return
		}
		published = append(published, id)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m.marked = map[string]string{"p1": "post", "p2": "post"}

	m.bulkPublish()

	if len(published) != 1 || published[0] != "p1" {
		t.Errorf("published = %v, want just p1", published)
	}
	if m.marked != nil {
		t.Errorf("marks should clear after the action, got %v", m.marked)
	}
	if !m.statusErr || !strings.Contains(m.status, "published 1, 1 failed") {
		t.Errorf("status should report partial failure, got %q (err=%v)", m.status, m.statusErr)
	}
}

func TestBulkUnpublishAllOK(t *testing.T) {
	count := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"result":{"documents":[],"count":0}}`))
			return
		}
		count++
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m.marked = map[string]string{"p1": "post", "p3": "post"}

	m.bulkUnpublish()

	if count != 2 {
		t.Errorf("want 2 unpublish calls, got %d", count)
	}
	if m.statusErr || !strings.Contains(m.status, "unpublished 2") {
		t.Errorf("status = %q (err=%v)", m.status, m.statusErr)
	}
}

func TestMarkedRowRendersCheck(t *testing.T) {
	m := bulkModel()
	m.marked = map[string]string{"p1": "post"}

	marked := strings.Join(m.renderPaneItem(m.panes[0].Items[0], 40, false, false, true), "\n")
	if !strings.Contains(marked, "✓") {
		t.Errorf("marked row should carry the check glyph:\n%s", marked)
	}
	plain := strings.Join(m.renderPaneItem(m.panes[0].Items[1], 40, false, false, true), "\n")
	if strings.Contains(plain, "✓") {
		t.Errorf("unmarked row must not carry the glyph:\n%s", plain)
	}
}

func TestEscClearsMarksBeforeNavigating(t *testing.T) {
	m := bulkModel()
	m.path = []string{"post"} // something to navigate back from
	m.marked = map[string]string{"p1": "post"}

	// First esc clears marks, path untouched.
	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	nm := next.(model)
	if len(nm.marked) != 0 {
		t.Errorf("first esc should clear marks, got %v", nm.marked)
	}
	if len(nm.path) != 1 {
		t.Errorf("first esc must not navigate, path = %v", nm.path)
	}
}
