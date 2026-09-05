package apiclient

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// QueryResult must tell a refused/broken/unreachable read apart from an
// honestly empty one. Query itself collapses all of them into a nil slice,
// which is why the TUI's doc-list pane announced "No documents yet" over a 500.
func TestQueryResultOutcomes(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		body     string
		wantDocs int
		want     DocReadOutcome
	}{
		{"populated 200", 200, `{"result":{"documents":[{"_id":"a","_type":"post"}]}}`, 1, DocReadOK},
		{"honestly empty 200", 200, `{"result":{"count":0,"documents":[]}}`, 0, DocReadOK},
		{"top-level fallback", 200, `{"documents":[{"_id":"a","_type":"post"}]}`, 1, DocReadOK},
		{"404 names nothing", 404, `{"error":"not_found"}`, 0, DocReadNotFound},
		{"401 unauthenticated", 401, `{"error":"unauthorized"}`, 0, DocReadForbidden},
		{"403 refused", 403, `{"error":"forbidden"}`, 0, DocReadForbidden},
		{"500 server fault", 500, `{"error":"boom"}`, 0, DocReadServerError},
		{"502 proxy fault", 502, `<html>Bad Gateway</html>`, 0, DocReadServerError},
		{"429 throttled", 429, `{"error":"slow down"}`, 0, DocReadUnreachable},
		{"200 undecodable body", 200, `<html>502 Bad Gateway</html>`, 0, DocReadUnreachable},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(c.status)
				_, _ = w.Write([]byte(c.body))
			}))
			defer srv.Close()
			cl := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})
			// The 429 row is now genuinely retried (retry_backpressure.go), so
			// without this seam this table would spend the real backoff on
			// every run. Same package, so the transport's test sleep is
			// reachable; the CLASSIFICATION under test is unchanged.
			cl.retry.sleep = func(time.Duration) {}

			docs, outcome := cl.QueryResult("post", "")
			if outcome != c.want {
				t.Errorf("QueryResult outcome = %d, want %d", outcome, c.want)
			}
			if got := outcome.Failed(); got != (c.want != DocReadOK) {
				t.Errorf("Failed() = %v for outcome %d", got, outcome)
			}
			if len(docs) != c.wantDocs {
				t.Errorf("QueryResult docs = %d, want %d", len(docs), c.wantDocs)
			}
			// Query must stay behaviour-identical: same rows, outcome dropped.
			if plain := cl.Query("post", ""); len(plain) != c.wantDocs {
				t.Errorf("Query docs = %d, want %d (Query must not change)", len(plain), c.wantDocs)
			}
		})
	}
}

// GetPerspectiveResult is the single-document twin and must classify the same
// statuses the same way — a 403 there used to read as DocReadUnreachable, which
// is what made `bp task claim`'s diagnosis say "may simply be unreachable" over
// a flat refusal.
func TestGetPerspectiveResultSeparatesRefusalFromUnreachable(t *testing.T) {
	cases := []struct {
		status int
		want   DocReadOutcome
	}{
		{404, DocReadNotFound},
		{401, DocReadForbidden},
		{403, DocReadForbidden},
		{500, DocReadServerError},
		{503, DocReadServerError},
		{429, DocReadUnreachable},
	}
	for _, c := range cases {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(c.status)
			_, _ = w.Write([]byte(`{"error":"x"}`))
		}))
		cl := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})
		cl.retry.sleep = func(time.Duration) {} // see the note in TestQueryResultOutcomes
		doc, outcome := cl.GetPerspectiveResult("task", "t1", "drafts")
		srv.Close()
		if outcome != c.want {
			t.Errorf("HTTP %d outcome = %d, want %d", c.status, outcome, c.want)
		}
		if doc.ID != "" {
			t.Errorf("HTTP %d returned a document: %+v", c.status, doc)
		}
		// The pre-existing bool surface must not move.
		if _, ok := cl.GetPerspective("task", "t1", "drafts"); ok {
			t.Errorf("HTTP %d: GetPerspective reported ok", c.status)
		}
	}
}

// A transport failure (nothing listening) is Unreachable, not an empty page.
func TestQueryResultTransportErrorIsUnreachable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close() // nothing is listening any more

	cl := New(Config{BaseURL: url, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})
	docs, outcome := cl.QueryResult("post", "")
	if outcome != DocReadUnreachable {
		t.Fatalf("dead server outcome = %d, want DocReadUnreachable (%d)", outcome, DocReadUnreachable)
	}
	if len(docs) != 0 {
		t.Fatalf("dead server returned %d docs", len(docs))
	}
}

// The outcome discriminator must not disturb the request the server sees:
// same path, same filter and perspective params Query has always sent.
func TestQueryResultSendsTheSameRequestAsQuery(t *testing.T) {
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.URL.RequestURI())
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"documents": []any{}}})
	}))
	defer srv.Close()

	cl := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "w", Project: "p", Dataset: "production"})
	cl.Perspective = "drafts"
	cl.Query("post", "status == 'open'")
	cl.QueryResult("post", "status == 'open'")

	if len(seen) != 2 {
		t.Fatalf("expected 2 requests, got %d: %v", len(seen), seen)
	}
	if seen[0] != seen[1] {
		t.Fatalf("QueryResult sent a different request:\n Query:       %s\n QueryResult: %s", seen[0], seen[1])
	}
}

// The constants are append-only: the three that existed before this change keep
// their wire values, so `outcome != DocReadOK` / `== DocReadNotFound` in
// callers written against the old enum still mean what they meant.
func TestDocReadOutcomeConstantsAreAppendOnly(t *testing.T) {
	for _, c := range []struct {
		name string
		got  DocReadOutcome
		want DocReadOutcome
	}{
		{"DocReadOK", DocReadOK, 0},
		{"DocReadNotFound", DocReadNotFound, 1},
		{"DocReadUnreachable", DocReadUnreachable, 2},
	} {
		if c.got != c.want {
			t.Errorf("%s = %d, want %d — renumbering breaks every caller compiled against the old enum", c.name, c.got, c.want)
		}
	}
}

// Every outcome must describe itself distinctly, and a failure must never
// describe itself as a success.
func TestDocReadOutcomeDescribe(t *testing.T) {
	all := []DocReadOutcome{DocReadOK, DocReadNotFound, DocReadUnreachable, DocReadForbidden, DocReadServerError}
	seen := map[string]DocReadOutcome{}
	for _, o := range all {
		d := o.Describe()
		if d == "" {
			t.Errorf("outcome %d describes itself as empty", o)
		}
		if prior, dup := seen[d]; dup {
			t.Errorf("outcome %d and %d share the description %q", prior, o, d)
		}
		seen[d] = o
	}
	if got := DocReadOutcome(99).Describe(); got == "" || got == DocReadOK.Describe() {
		t.Errorf("an unknown outcome described itself as %q — it must never read as success", got)
	}
	if !DocReadForbidden.Failed() || !DocReadServerError.Failed() || DocReadOK.Failed() {
		t.Error("Failed() disagrees with the outcome it was given")
	}
}
