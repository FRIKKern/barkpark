package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// History-view pins (TUI long-tail, 2026-06-11): `H` lists the revision
// family for the editor's doc (bare id), enter stacks the diff modal over the
// list with the `- revision  + current` legend, and the apiclient flattens a
// revision's scalar content into Doc.Values exactly like a live envelope.

const historyJSON = `{"count":2,"revisions":[
  {"id":"d103ad50-fe84-48ed-afe4-f5cea13e96d5","action":"update","title":"Newer","status":"draft","timestamp":"2026-06-11T20:21:11.873627Z"},
  {"id":"826b13de-3fd6-487a-991e-ad1fd275a829","action":"create","title":"Older","status":"draft","timestamp":"2026-06-11T20:20:37.057388Z"}
]}`

const revisionJSON = `{"revision":{
  "id":"826b13de-3fd6-487a-991e-ad1fd275a829","doc_id":"p1","type":"post","dataset":"production",
  "action":"create","title":"Old Title","status":"draft",
  "content":{"category":"History","author":"Ibsen","claim":{"worker":"w"},"count":3},
  "timestamp":"2026-06-11T20:20:37.057388Z"}}`

func historyServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/history/"):
			// The list must be requested under the BARE id, never drafts.<id>.
			if strings.Contains(r.URL.Path, "drafts.") {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			_, _ = w.Write([]byte(historyJSON))
		case strings.Contains(r.URL.Path, "/v1/data/revision/"):
			_, _ = w.Write([]byte(revisionJSON))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func TestRevisionDocFlattensScalars(t *testing.T) {
	srv := historyServer(t)
	defer srv.Close()
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})

	doc, err := c.RevisionDoc("826b13de-3fd6-487a-991e-ad1fd275a829")
	if err != nil {
		t.Fatalf("RevisionDoc: %v", err)
	}
	if doc.ID != "p1" || doc.Title != "Old Title" || doc.Status != "draft" {
		t.Errorf("typed fields wrong: %+v", doc)
	}
	if doc.Values["category"] != "History" || doc.Values["author"] != "Ibsen" || doc.Values["count"] != "3" {
		t.Errorf("scalar Values wrong: %v", doc.Values)
	}
	if _, ok := doc.Values["claim"]; ok {
		t.Errorf("non-scalar content must not flatten into Values: %v", doc.Values)
	}
}

func TestOpenHistoryViewListsRevisionFamily(t *testing.T) {
	srv := historyServer(t)
	defer srv.Close()

	m := diffModel() // drafts.p1 — History must strip to the bare id
	m.ds = apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	m.openHistoryView()
	if !m.historyOpen {
		t.Fatalf("history should open (status %q)", m.status)
	}
	if len(m.historyRevs) != 2 || m.historyRevs[0].Title != "Newer" {
		t.Errorf("revisions wrong: %+v", m.historyRevs)
	}

	out := m.renderHistoryView(100, 30)
	for _, want := range []string{"History:", "update", "create", "enter diff vs current"} {
		if !strings.Contains(out, want) {
			t.Errorf("history view missing %q:\n%s", want, out)
		}
	}
}

func TestHistoryEnterStacksDiffOverList(t *testing.T) {
	srv := historyServer(t)
	defer srv.Close()

	m := diffModel()
	m.ds = apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	m.openHistoryView()
	m.historyCursor = 1 // the "Older" revision (category History, author Ibsen)

	next, _ := m.handleHistoryKey(tea.KeyMsg{Type: tea.KeyEnter})
	nm := next.(model)
	if !nm.diffOpen || !nm.historyOpen {
		t.Fatalf("diff must stack over the still-open history list (diff=%v history=%v)", nm.diffOpen, nm.historyOpen)
	}
	if !strings.Contains(nm.diffLegend, "revision") {
		t.Errorf("legend should name the revision side, got %q", nm.diffLegend)
	}

	joined := strings.Join(nm.diffLines, "\n")
	// Revision had category=History/author=Ibsen; current has Tech/Knut.
	for _, want := range []string{"- History", "+ Tech", "- Ibsen", "+ Knut", "- Old Title", "+ New Title"} {
		if !strings.Contains(joined, want) {
			t.Errorf("revision diff missing %q in:\n%s", want, joined)
		}
	}

	// esc closes the diff and falls back to the list, not the editor.
	after, _ := nm.handleDiffKey(tea.KeyMsg{Type: tea.KeyEsc})
	am := after.(model)
	if am.diffOpen || !am.historyOpen {
		t.Errorf("esc from diff should return to history (diff=%v history=%v)", am.diffOpen, am.historyOpen)
	}
}

func TestOpenHistoryViewEmptyAndError(t *testing.T) {
	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"count":0,"revisions":[]}`))
	}))
	defer empty.Close()

	m := diffModel()
	m.ds = apiclient.New(apiclient.Config{BaseURL: empty.URL, Token: "t"})
	m.openHistoryView()
	if m.historyOpen {
		t.Error("zero revisions must not open the modal")
	}
	if !strings.Contains(m.status, "no revisions") {
		t.Errorf("status should explain, got %q", m.status)
	}

	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer down.Close()

	m = diffModel()
	m.ds = apiclient.New(apiclient.Config{BaseURL: down.URL, Token: "t"})
	m.openHistoryView()
	if m.historyOpen {
		t.Error("a failed fetch must not open the modal")
	}
	if !strings.Contains(m.status, "history failed") {
		t.Errorf("status should surface the error, got %q", m.status)
	}
}
