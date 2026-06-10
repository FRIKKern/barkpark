package apiclient

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

// Wire pins for Client.Duplicate — the TUI's `y` action. The contract mirrors
// Studio's duplicate-doc → Content.clone_document: fresh draft (no _id, no
// status — the server assigns both), title + " (copy)", and content copied
// VERBATIM as raw JSON so nested objects/arrays survive (the editor's scalar
// Values projection would drop them).

// The REAL doc-show response (verified live against QueryController.show):
// the document rides inside "result", beside the envelope's own metadata.
// Decoding the whole body as the doc compiled and "worked" while producing an
// empty document — the fixture pins the wrapped shape so that can't regress.
const dupSourceEnvelope = `{
	"result": {
		"_id": "drafts.post-7",
		"_type": "post",
		"_draft": true,
		"_createdAt": "2026-06-01T10:00:00Z",
		"_updatedAt": "2026-06-09T10:00:00Z",
		"title": "Launch plan",
		"category": "Notes",
		"rating": 4.5,
		"meta": {"tags": ["a", "b"], "depth": {"n": 1}}
	},
	"schemaHash": "e9f23c11b41df19a",
	"syncTags": ["bp:ds:production:doc:post-7"],
	"ms": 0,
	"etag": "abc123"
}`

func dupServer(t *testing.T, docJSON string, mutateBody *[]byte, mutateCalls *int) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/doc/"):
			_, _ = w.Write([]byte(docJSON))
		case strings.Contains(r.URL.Path, "/v1/data/mutate/"):
			*mutateCalls++
			*mutateBody, _ = io.ReadAll(r.Body)
			_, _ = w.Write([]byte(`{"transactionId":"t1","results":[{"id":"drafts.post-8","operation":"create"}]}`))
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func TestDuplicateCopiesContentVerbatimIntoFreshDraft(t *testing.T) {
	var mutateBody []byte
	mutateCalls := 0
	srv := dupServer(t, dupSourceEnvelope, &mutateBody, &mutateCalls)
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	id, err := c.Duplicate("post", "drafts.post-7")
	if err != nil {
		t.Fatalf("Duplicate: %v", err)
	}
	if id != "drafts.post-8" {
		t.Errorf("returned id = %q, want the server-assigned drafts.post-8", id)
	}

	var body struct {
		Mutations []struct {
			Create map[string]interface{} `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(mutateBody, &body); err != nil {
		t.Fatalf("parse mutate body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	create := body.Mutations[0].Create

	if create["_type"] != "post" {
		t.Errorf("_type = %v, want post", create["_type"])
	}
	if create["title"] != "Launch plan (copy)" {
		t.Errorf("title = %v, want %q", create["title"], "Launch plan (copy)")
	}
	// The server assigns both — a duplicate is always a brand-new draft.
	for _, forbidden := range []string{"_id", "status", "_draft", "_createdAt", "_updatedAt"} {
		if _, ok := create[forbidden]; ok {
			t.Errorf("create payload must not carry %q (got %v)", forbidden, create[forbidden])
		}
	}
	// Content fields ride verbatim — scalars AND nested structures.
	if create["category"] != "Notes" {
		t.Errorf("category = %v, want Notes", create["category"])
	}
	if create["rating"] != 4.5 {
		t.Errorf("rating = %v, want 4.5", create["rating"])
	}
	wantMeta := map[string]interface{}{
		"tags":  []interface{}{"a", "b"},
		"depth": map[string]interface{}{"n": float64(1)},
	}
	if !reflect.DeepEqual(create["meta"], wantMeta) {
		t.Errorf("nested meta not copied verbatim: got %v, want %v", create["meta"], wantMeta)
	}
}

func TestDuplicateRefusesPapers(t *testing.T) {
	paper := `{"result": {
		"_id": "drafts.paper-1",
		"_type": "paper",
		"_draft": true,
		"title": "Welcome",
		"blocks": [{"type": "heading", "text": "Hi", "id": "b1"}]
	}}`
	var mutateBody []byte
	mutateCalls := 0
	srv := dupServer(t, paper, &mutateBody, &mutateCalls)
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	_, err := c.Duplicate("paper", "drafts.paper-1")
	if err == nil {
		t.Fatal("duplicating a paper must error — its block tree cannot ride the generic mutate path")
	}
	if !strings.Contains(err.Error(), "Studio") {
		t.Errorf("error should point at Studio, got: %v", err)
	}
	if mutateCalls != 0 {
		t.Errorf("refusal must happen BEFORE any mutation, got %d mutate call(s)", mutateCalls)
	}
}

func TestDuplicateUntitledSourceGetsFallbackTitle(t *testing.T) {
	untitled := `{"result": {"_id": "drafts.post-9", "_type": "post", "_draft": true, "category": "X"}}`
	var mutateBody []byte
	mutateCalls := 0
	srv := dupServer(t, untitled, &mutateBody, &mutateCalls)
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	if _, err := c.Duplicate("post", "drafts.post-9"); err != nil {
		t.Fatalf("Duplicate: %v", err)
	}

	var body struct {
		Mutations []struct {
			Create map[string]interface{} `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(mutateBody, &body); err != nil {
		t.Fatalf("parse mutate body: %v", err)
	}
	if got := body.Mutations[0].Create["title"]; got != "Untitled (copy)" {
		t.Errorf("title = %v, want %q (Studio's clone fallback)", got, "Untitled (copy)")
	}
}
