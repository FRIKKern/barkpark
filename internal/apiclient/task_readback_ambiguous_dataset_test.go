package apiclient

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// A doc_id held by two datasets makes the bare GET /v1/tasks/:doc_id refuse
// 409 ambiguous_dataset. Measured live against guerrilla 2026-09-17 on a
// scratch twin: `bp task stamp <twin> <w> <epoch> -d production --met` LANDED
// the criterion (the store held met:true with the sent evidence) and then
// printed "✗ NOT confirmed — treat this stamp as NOT stored and stamp again",
// because the read-back went to the BARE route and got the 409. A ledger
// writer that reports a landed write as lost, and instructs a re-write, is the
// exact failure the PDS success-claim law exists to prevent.
//
// RED ARM: delete the `status == http.StatusConflict` retry in TaskGetContent
// and this test fails with `task read-back … status 409`.
func TestTaskGetContentRetriesTheAmbiguousDatasetRefusalWithTheResolvedDataset(t *testing.T) {
	var mu sync.Mutex
	var seen []string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.URL.RequestURI())
		mu.Unlock()
		if r.URL.Query().Get("dataset") == "" {
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"ambiguous_dataset","details":{"datasets":["aker-brygge","production"]}}}`))
			return
		}
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"twin","status":"published","lifecycle_status":"open","content":{"kind":"task"}}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	rb, err := c.TaskGetContent("twin")
	if err != nil {
		t.Fatalf("read-back of an ambiguous twin must resolve by naming the caller's dataset, got error: %v", err)
	}
	if rb.DocID != "twin" || len(rb.Content) == 0 {
		t.Fatalf("read-back returned an empty row: %+v", rb)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 2 {
		t.Fatalf("expected exactly two reads (bare, then dataset-named), got %d: %v", len(seen), seen)
	}
	if strings.Contains(seen[0], "dataset=") {
		t.Errorf("the FIRST read must stay bare so non-ambiguous rows keep the server's drafts. fallback; got %q", seen[0])
	}
	if !strings.Contains(seen[1], "dataset=production") {
		t.Errorf("the retry must name the resolved dataset; got %q", seen[1])
	}
}

// THE QUIET ARM: a row that is NOT ambiguous must be read exactly as before —
// one bare request, no dataset param anywhere. This is what makes the retry
// safe: a row living only in a non-default dataset still resolves through the
// bare route's own fallback, and would 404 if the client started pinning
// ?dataset=production to every read-back.
func TestTaskGetContentSendsNoDatasetParamWhenTheBareRouteAnswers(t *testing.T) {
	var mu sync.Mutex
	var seen []string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.URL.RequestURI())
		mu.Unlock()
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"lonely","status":"published","lifecycle_status":"open","content":{"kind":"task"}}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})
	if _, err := c.TaskGetContent("lonely"); err != nil {
		t.Fatalf("unambiguous read-back must succeed unchanged: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 1 {
		t.Fatalf("an answered bare read must not be retried; requests: %v", seen)
	}
	if strings.Contains(seen[0], "dataset=") {
		t.Errorf("no dataset param may be pinned to an unambiguous read-back; got %q", seen[0])
	}
}

// A 409 with NO resolved dataset has nothing to retry with, and must surface
// the refusal rather than loop or invent one.
func TestTaskGetContentSurfacesTheConflictWhenNoDatasetIsResolved(t *testing.T) {
	var mu sync.Mutex
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		n++
		mu.Unlock()
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"ambiguous_dataset"}}`))
	}))
	defer srv.Close()

	// New() floors an empty Dataset at "production", so the no-dataset case is
	// constructed by clearing the field on the built client.
	c := New(Config{BaseURL: srv.URL, Token: "t"})
	c.Dataset = ""
	_, err := c.TaskGetContent("twin")
	if err == nil || !strings.Contains(err.Error(), "409") {
		t.Fatalf("a 409 with no dataset to name must surface as a read failure naming 409; got %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if n != 1 {
		t.Fatalf("with no dataset resolved there is nothing to retry; requests = %d", n)
	}
}
