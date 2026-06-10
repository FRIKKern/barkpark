package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TUI parity pin for gap 7 — `y` duplicate: clones the highlighted row (or
// open editor doc) into a fresh "<title> (copy)" draft via Client.Duplicate,
// then re-queries and drills into the new draft's editor, mirroring Studio's
// duplicate-doc → push_patch flow. Inert on structure panes.

const dupCopyDocJSON = `{"_id":"drafts.post-2","_type":"post","_draft":true,
	"title":"Hello (copy)","_updatedAt":"2026-06-09T10:05:00Z"}`

func TestDuplicateKeyClonesAndDrillsIn(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/doc/"):
			_, _ = w.Write([]byte(postDocJSON))
		case strings.Contains(r.URL.Path, "/v1/data/mutate/"):
			b, _ := io.ReadAll(r.Body)
			mutates = append(mutates, b)
			_, _ = w.Write([]byte(`{"transactionId":"t1","results":[{"id":"drafts.post-2","operation":"create"}]}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			// Both the original and (post-duplicate) the copy — the re-query
			// after the clone must find the new draft to drill into.
			_, _ = w.Write([]byte(`{"result":{"documents":[` + postDocJSON + `,` + dupCopyDocJSON + `]}}`))
		default:
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m = press(t, m, "y")

	if len(mutates) != 1 {
		t.Fatalf("want exactly 1 mutation (the create), got %d", len(mutates))
	}
	var body struct {
		Mutations []struct {
			Create map[string]interface{} `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(mutates[0], &body); err != nil {
		t.Fatalf("parse mutate body: %v", err)
	}
	create := body.Mutations[0].Create
	if create["title"] != "Hello (copy)" {
		t.Errorf("title = %v, want %q", create["title"], "Hello (copy)")
	}
	if _, ok := create["_id"]; ok {
		t.Errorf("duplicate create must carry NO _id, got %v", create["_id"])
	}

	if !m.showEditor || m.selectedDoc == nil || m.selectedDoc.ID != "drafts.post-2" {
		t.Errorf("must drill into the new draft's editor; showEditor=%v selected=%v",
			m.showEditor, m.selectedDoc)
	}
	if m.statusErr || m.status != "duplicated as drafts.post-2" {
		t.Errorf("status = (%q, err=%v), want the duplicated-as confirmation", m.status, m.statusErr)
	}
}

func TestDuplicateKeyInertOnStructurePane(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/v1/data/doc/") ||
			strings.Contains(r.URL.Path, "/v1/data/mutate/") {
			requests++
		}
		_, _ = w.Write([]byte(`{"result":{"documents":[]}}`))
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m.focus = focusState{Target: FocusPane, PaneIndex: 0} // structure pane, not a doc list
	m = press(t, m, "y")

	if requests != 0 {
		t.Errorf("y on a structure pane must be inert, got %d API call(s)", requests)
	}
	if m.status != "" {
		t.Errorf("inert y must set no status, got %q", m.status)
	}
}

// TestSSERefreshKeepsEditorFocus pins the focus-restore in refreshDocViews:
// rebuildPanes nils the editor state before its focus clamp runs, so a
// DataStoreRefreshMsg (the SSE echo of any mutation — including one's OWN
// create/save) demoted FocusEditor to the pane. The user's next ctrl+p /
// ctrl+s then landed on the pane and silently did nothing.
func TestSSERefreshKeepsEditorFocus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/v1/data/query/") {
			_, _ = w.Write([]byte(`{"result":{"documents":[` + postDocJSON + `]}}`))
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	// Drill into the doc's editor (enter on the highlighted row).
	m = press(t, m, "enter")
	if m.focus.Target != FocusEditor || m.selectedDoc == nil {
		t.Fatalf("setup: expected editor focus on the drilled doc, got %+v", m.focus)
	}

	mm, _ := m.Update(DataStoreRefreshMsg{})
	m = mm.(model)

	if m.focus.Target != FocusEditor {
		t.Errorf("SSE refresh must keep editor focus, got %+v", m.focus)
	}
	if !m.showEditor || m.selectedDoc == nil || m.selectedDoc.ID != "drafts.post-1" {
		t.Errorf("editor doc must survive the refresh, got showEditor=%v doc=%+v",
			m.showEditor, m.selectedDoc)
	}
}
