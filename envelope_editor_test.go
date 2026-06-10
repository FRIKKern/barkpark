package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Editor-level pins for the v1-envelope normalization: the classic field
// editor reads doc.Values and saveDocument patches doc.ID — both were latently
// broken against the live flat envelope (legacy "id"/"values" keys never
// arrive). These decode the REAL envelope shape and walk the actual consumers.

const liveDocJSON = `{
	"_createdAt": "2026-06-05T10:19:18.901132Z",
	"_draft": true,
	"_id": "drafts.playground-unpublish-1",
	"_publishedId": "playground-unpublish-1",
	"_rev": "a49ab6f8b38b957cfa3d3a165aabce0f",
	"_type": "post",
	"_updatedAt": "2026-06-05T10:19:18.901132Z",
	"title": "Unpublish me",
	"status": "draft",
	"category": "Tech",
	"author": "Knut"
}`

func liveDoc(t *testing.T) *Doc {
	t.Helper()
	var d Doc
	if err := json.Unmarshal([]byte(liveDocJSON), &d); err != nil {
		t.Fatalf("decode live envelope: %v", err)
	}
	return &d
}

func TestGetFieldValueReadsEnvelopeFields(t *testing.T) {
	m := model{selectedDoc: liveDoc(t)}

	cases := map[string]string{
		"title":    "Unpublish me", // typed special-case
		"status":   "draft",        // typed special-case
		"category": "Tech",         // via normalized Values
		"author":   "Knut",         // via normalized Values
		"missing":  "",
	}
	for field, want := range cases {
		if got := m.getFieldValue(field); got != want {
			t.Errorf("getFieldValue(%q) = %q, want %q", field, got, want)
		}
	}
}

func TestSaveDocumentPatchesEnvelopeID(t *testing.T) {
	var captured []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m := model{
		ds:           apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		selectedDoc:  liveDoc(t),
		editorSchema: &Schema{Name: "post"},
		dirty:        true,
		dirtyValues:  map[string]string{"category": "Updated"},
	}
	m.saveDocument()

	if m.statusErr {
		t.Fatalf("save reported error: %q", m.status)
	}
	var body struct {
		Mutations []struct {
			Patch struct {
				ID   string         `json:"id"`
				Type string         `json:"type"`
				Set  map[string]any `json:"set"`
			} `json:"patch"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil {
		t.Fatalf("parse captured body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	p := body.Mutations[0].Patch
	if p.ID != "drafts.playground-unpublish-1" {
		t.Errorf("patch id = %q, want the envelope _id (was \"\" before normalization)", p.ID)
	}
	if p.Type != "post" || p.Set["category"] != "Updated" {
		t.Errorf("patch payload wrong: type=%q set=%v", p.Type, p.Set)
	}
}
