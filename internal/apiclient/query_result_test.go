package apiclient

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The query controller wraps the page under {"result":{"documents":[...]}}.
// Query must read that path (the TUI's empty-lists bug was reading top-level
// "documents"); a top-level "documents" is accepted as a fallback.
func TestQueryParsesResultWrapper(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"result": map[string]any{
				"count":     2,
				"documents": []map[string]any{{"_id": "a", "_type": "post"}, {"_id": "b", "_type": "post"}},
			},
		})
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})
	if got := c.Query("post", ""); len(got) != 2 {
		t.Fatalf("result-wrapped: got %d docs, want 2", len(got))
	}
}

func TestQueryTopLevelFallback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"documents": []map[string]any{{"_id": "a", "_type": "post"}}})
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})
	if got := c.Query("post", ""); len(got) != 1 {
		t.Fatalf("top-level fallback: got %d docs, want 1", len(got))
	}
}
