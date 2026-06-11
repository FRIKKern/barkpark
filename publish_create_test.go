package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// TUI parity pins for the two wired-up gaps:
//   - ctrl+p publish: sends {"publish":{"id":<bare id>,"type":…}} for a draft,
//     refuses when dirty (save first), no-ops on a published doc.
//   - n new: sends {"create":{"_type":…,"title":…}} with NO _id (the server
//     assigns drafts.<type>-<n>) and drills into the new doc's editor.
//   - pure-render: the editor footer reflects publish state (draft → the
//     ctrl+p button; published → a dim, action-free checkmark).

func draftDoc(t *testing.T) *Doc {
	t.Helper()
	var d Doc
	if err := json.Unmarshal([]byte(liveDocJSON), &d); err != nil {
		t.Fatalf("decode live envelope: %v", err)
	}
	return &d
}

func TestPublishSendsBareIDPublishMutation(t *testing.T) {
	var captured []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"transactionId":"t1","results":[{"id":"playground-unpublish-1","operation":"publish"}]}`))
	}))
	defer srv.Close()

	m := model{
		ds:           apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		selectedDoc:  draftDoc(t),
		editorSchema: &Schema{Name: "post"},
	}
	m.publishDocument()

	if m.statusErr {
		t.Fatalf("publish reported error: %q", m.status)
	}
	var body struct {
		Mutations []struct {
			Publish struct {
				ID   string `json:"id"`
				Type string `json:"type"`
			} `json:"publish"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil {
		t.Fatalf("parse captured body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	p := body.Mutations[0].Publish
	if p.ID != "playground-unpublish-1" {
		t.Errorf("publish id = %q, want the BARE published id (drafts. prefix stripped)", p.ID)
	}
	if p.Type != "post" {
		t.Errorf("publish type = %q, want post", p.Type)
	}
	// Optimistic flip, mirroring saveDocument's in-memory apply.
	if m.selectedDoc.Status != "published" || m.selectedDoc.ID != "playground-unpublish-1" {
		t.Errorf("optimistic flip wrong: status=%q id=%q", m.selectedDoc.Status, m.selectedDoc.ID)
	}
	if m.status != "published" {
		t.Errorf("status = %q, want published", m.status)
	}
}

func TestPublishRefusesWhenDirty(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m := model{
		ds:           apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		selectedDoc:  draftDoc(t),
		editorSchema: &Schema{Name: "post"},
		dirty:        true,
		dirtyValues:  map[string]string{"category": "Edited"},
	}
	m.publishDocument()

	if requests != 0 {
		t.Errorf("dirty publish must not hit the API, got %d request(s)", requests)
	}
	if !m.statusErr || m.status != "save first (ctrl+s)" {
		t.Errorf("status = (%q, err=%v), want the save-first error", m.status, m.statusErr)
	}
	if m.selectedDoc.Status != "draft" {
		t.Errorf("doc must stay a draft, got %q", m.selectedDoc.Status)
	}
}

func TestPublishNoopsOnPublishedDoc(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	doc := draftDoc(t)
	doc.Status = "published"
	doc.ID = "playground-unpublish-1"
	m := model{
		ds:           apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		selectedDoc:  doc,
		editorSchema: &Schema{Name: "post"},
	}
	m.publishDocument()

	if requests != 0 {
		t.Errorf("ctrl+p on a published doc is publish-only no-op, got %d request(s)", requests)
	}
	if m.status != "" {
		t.Errorf("no-op must set no status, got %q", m.status)
	}
}

// TestCreateSendsCreateMutationAndDrillsIn drives the full n-key path: prompt
// → title → enter. The create mutation must carry NO _id (the server assigns
// drafts.<type>-<n>); the model must then re-query, select the new doc, and
// land in its editor.
func TestCreateSendsCreateMutationAndDrillsIn(t *testing.T) {
	prevSchemas, prevRoot := schemas, rootStructure
	defer func() { schemas, rootStructure = prevSchemas, prevRoot }()
	schemas = []Schema{{Name: "post", Title: "Posts", Icon: "📄"}}
	initRootStructure()

	const newDocJSON = `{"_id":"drafts.post-42","_type":"post","_draft":true,
		"title":"Hello","_updatedAt":"2026-06-09T10:00:00Z"}`

	var capturedMutate []byte
	created := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/mutate/"):
			capturedMutate, _ = io.ReadAll(r.Body)
			created = true
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"transactionId":"t1","results":[{"id":"drafts.post-42","operation":"create","document":` + newDocJSON + `}]}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			docs := "[]"
			if created {
				docs = "[" + newDocJSON + "]"
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":` + docs + `}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	m := model{
		ds:     apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		width:  120,
		height: 40,
		path:   []string{"post"},
	}
	m.rebuildPanes()
	if len(m.panes) != 2 || !m.panes[1].IsDocList {
		t.Fatalf("setup: want a doc-list pane at index 1, got %d panes", len(m.panes))
	}
	m.focus = focusState{Target: FocusPane, PaneIndex: 1}

	// n → the title prompt opens, scoped to the pane's type.
	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("n")})
	m = mm.(model)
	if !m.creating || m.creatingType != "post" {
		t.Fatalf("n must open the create prompt for post, got creating=%v type=%q", m.creating, m.creatingType)
	}

	// Type the title, enter → create + drill in.
	m.textInput.SetValue("Hello")
	mm, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm.(model)

	var body struct {
		Mutations []struct {
			Create map[string]any `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(capturedMutate, &body); err != nil {
		t.Fatalf("parse captured mutate body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	c := body.Mutations[0].Create
	if c["_type"] != "post" || c["title"] != "Hello" {
		t.Errorf("create payload wrong: %v", c)
	}
	if _, hasID := c["_id"]; hasID {
		t.Errorf("create must carry NO _id (server assigns drafts.<type>-<n>), got %v", c["_id"])
	}

	if m.creating {
		t.Error("prompt must close after enter")
	}
	if !m.showEditor || m.focus.Target != FocusEditor {
		t.Errorf("must drill into the new doc's editor, got showEditor=%v focus=%v", m.showEditor, m.focus.Target)
	}
	if m.selectedDoc == nil || m.selectedDoc.ID != "drafts.post-42" {
		t.Fatalf("selectedDoc = %+v, want the server-assigned drafts.post-42", m.selectedDoc)
	}
	if m.statusErr || m.status != "created Hello" {
		t.Errorf("status = (%q, err=%v), want created confirmation", m.status, m.statusErr)
	}
	// The new doc appears in the (re-queried) list with the cursor parked on it.
	pane := m.panes[1]
	if pane.Cursor >= len(pane.Items) || pane.Items[pane.Cursor].ID != "drafts.post-42" {
		t.Errorf("doc-list cursor not on the new doc: cursor=%d items=%d", pane.Cursor, len(pane.Items))
	}
}

func TestCreateEscCancelsPrompt(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"result":{"documents":[]}}`))
	}))
	defer srv.Close()

	m := model{
		ds:           apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		creating:     true,
		creatingType: "post",
	}
	mutatesBefore := requests
	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	m = mm.(model)
	if m.creating {
		t.Error("esc must cancel the create prompt")
	}
	if requests != mutatesBefore {
		t.Errorf("esc must send nothing, got %d request(s)", requests-mutatesBefore)
	}
}

// Pure-render pins for the footer's publish-state text.
func TestEditorFooterPublishState(t *testing.T) {
	schema := &Schema{Name: "post", Title: "Posts", Icon: "📄"}

	draft := draftDoc(t)
	m := model{selectedDoc: draft, editorSchema: schema}
	out := m.buildEditorContent(80)
	if !strings.Contains(out, "Ctrl+P publish") {
		t.Errorf("draft footer must advertise the ctrl+p binding:\n%s", out)
	}
	if strings.Contains(out, "published ✓") {
		t.Errorf("draft footer must not show the published checkmark")
	}

	pub := draftDoc(t)
	pub.Status = "published"
	pub.ID = "playground-unpublish-1"
	m = model{selectedDoc: pub, editorSchema: schema}
	out = m.buildEditorContent(80)
	if !strings.Contains(out, "published ✓") {
		t.Errorf("published footer must show the dim checkmark:\n%s", out)
	}
	if strings.Contains(out, "Ctrl+P publish") {
		t.Errorf("published footer must not advertise a publish action")
	}
}

// TestUnpublishDemotesPublishedDoc pins U's wire shape and guards: sends
// {"unpublish":{"id":<bare>,"type":…}} for a published doc, optimistically
// flips to the drafts. twin, and no-ops on a draft (ctrl+p's peer, separate
// key by design).
func TestUnpublishDemotesPublishedDoc(t *testing.T) {
	var captured []byte
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		captured, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"transactionId":"t1","results":[{"id":"playground-unpublish-1","operation":"unpublish"}]}`))
	}))
	defer srv.Close()

	doc := draftDoc(t)
	doc.Status = "published"
	doc.ID = "playground-unpublish-1"
	m := model{
		ds:           apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		selectedDoc:  doc,
		editorSchema: &Schema{Name: "post"},
	}
	m.unpublishDocument()

	var body struct {
		Mutations []struct {
			Unpublish struct {
				ID   string `json:"id"`
				Type string `json:"type"`
			} `json:"unpublish"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil || len(body.Mutations) != 1 {
		t.Fatalf("want 1 unpublish mutation, got err=%v body=%s", err, captured)
	}
	u := body.Mutations[0].Unpublish
	if u.ID != "playground-unpublish-1" || u.Type != "post" {
		t.Errorf("unpublish = %+v, want bare id + post", u)
	}
	if m.selectedDoc.Status != "draft" || m.selectedDoc.ID != "drafts.playground-unpublish-1" {
		t.Errorf("optimistic flip wrong: status=%q id=%q", m.selectedDoc.Status, m.selectedDoc.ID)
	}

	// Inert on a draft: no second request.
	m.unpublishDocument()
	if requests != 1 {
		t.Errorf("U on a draft must be a no-op, got %d requests", requests)
	}
}

// TestEditorFooterAdvertisesUnpublish: the published footer carries the U hint.
func TestEditorFooterAdvertisesUnpublish(t *testing.T) {
	doc := draftDoc(t)
	doc.Status = "published"
	m := model{selectedDoc: doc, editorSchema: &Schema{Name: "post", Title: "Posts"}}
	if out := m.buildEditorContent(80); !strings.Contains(out, "U unpublish") {
		t.Errorf("published footer must advertise U unpublish:\n%s", out)
	}
}
