package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// A slug stored Sanity-style — {"current": "…"}, what both create-barkpark-app
// starters seed — read as EMPTY in the TUI: the field ghosted a slug derived
// from the title ("Seed slug" -> seed-slug) and enter→enter saved that string
// over the real one, changing both value and stored shape (stranger walk,
// 2026-10-01: post r2d-slug-obj on a local instance).

func slugModel(extra map[string]json.RawMessage) model {
	return model{
		selectedDoc: &Doc{ID: "drafts.r2d-slug-obj", Title: "Seed slug", Extra: extra},
		editorSchema: &apiclient.Schema{Name: "post", Fields: []Field{
			{Name: "slug", Title: "Slug", Type: FieldSlug},
			{Name: "meta", Title: "Meta", Type: FieldString},
		}},
		focus:      focusState{Target: FocusEditor},
		showEditor: true,
		width:      100,
		height:     40,
	}
}

func TestSlugObjectReadsItsCurrent(t *testing.T) {
	m := slugModel(map[string]json.RawMessage{
		"slug": json.RawMessage(`{"_type":"slug","current":"seed-style-slug"}`),
		"meta": json.RawMessage(`{"current":"not-a-slug"}`),
	})
	if got := m.getFieldValue("slug"); got != "seed-style-slug" {
		t.Errorf("getFieldValue(slug) = %q, want the stored current", got)
	}
	// Only a SLUG field reads `current`: an object in a string field is not a slug.
	if got := m.getFieldValue("meta"); got != "" {
		t.Errorf("getFieldValue(meta) = %q, want \"\" for a non-slug object", got)
	}
	// Opening the editor seeds the real slug, not the title-derived ghost.
	m.fieldCursor = 0
	m.startFieldEdit()
	if got := m.textInput.Value(); got != "seed-style-slug" {
		t.Errorf("editor seeded %q, want the stored slug (not the ghost seed-slug)", got)
	}
}

func saveSlug(t *testing.T, extra map[string]json.RawMessage, edited string) json.RawMessage {
	t.Helper()
	var captured []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/v1/data/mutate/") {
			captured, _ = io.ReadAll(r.Body)
			_, _ = w.Write([]byte(`{"transactionId":"t1","results":[]}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	m := slugModel(extra)
	m.ds = apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	m.dirtyValues = map[string]string{"slug": edited}
	m.dirty = true
	m.saveDocument()
	var body struct {
		Mutations []struct {
			Patch struct {
				Set map[string]json.RawMessage `json:"set"`
			} `json:"patch"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil || len(body.Mutations) != 1 {
		t.Fatalf("parse captured mutate body: %v (%s)", err, captured)
	}
	return body.Mutations[0].Patch.Set["slug"]
}

func TestSlugSaveKeepsTheObjectShape(t *testing.T) {
	got := saveSlug(t, map[string]json.RawMessage{
		"slug": json.RawMessage(`{"_type":"slug","current":"seed-style-slug"}`),
	}, "renamed-slug")
	var obj map[string]string
	if err := json.Unmarshal(got, &obj); err != nil {
		t.Fatalf("set.slug is not an object: %s", got)
	}
	if obj["current"] != "renamed-slug" || obj["_type"] != "slug" {
		t.Errorf("set.slug = %s, want {_type: slug, current: renamed-slug}", got)
	}
}

func TestSlugSaveKeepsAStringAString(t *testing.T) {
	for name, extra := range map[string]map[string]json.RawMessage{
		"string": {"slug": json.RawMessage(`"studio-style-slug"`)},
		"absent": nil,
	} {
		got := saveSlug(t, extra, "new-slug")
		var s string
		if err := json.Unmarshal(got, &s); err != nil || s != "new-slug" {
			t.Errorf("%s: set.slug = %s, want the string \"new-slug\"", name, got)
		}
	}
}
