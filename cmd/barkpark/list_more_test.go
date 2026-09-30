package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// The TUI's list and reference picker read through QueryResult, which sent no
// limit: every read got the route's default 100-row page and dropped
// `hasMore`, so a type with 131 documents listed 100 with a count of 100 and a
// reference to the 101st could not be picked (stranger walk, 2026-10-01).

// pagedServer answers /query/<type> with `total` gadget rows, honouring
// ?limit (default 100) and reporting hasMore the way the query route does.
func pagedServer(t *testing.T, total int) (*httptest.Server, *[]string) {
	t.Helper()
	var mu sync.Mutex
	var queries []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		queries = append(queries, r.URL.RawQuery)
		mu.Unlock()
		limit := 100
		if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 {
			limit = l
		}
		n := total
		if n > limit {
			n = limit
		}
		docs := make([]map[string]any, 0, n)
		for i := 1; i <= n; i++ {
			docs = append(docs, map[string]any{"_id": fmt.Sprintf("gadget-%d", i), "_type": "gadget", "title": fmt.Sprintf("Gadget %d", i)})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"documents": docs, "hasMore": total > limit}})
	}))
	t.Cleanup(srv.Close)
	return srv, &queries
}

func pagedListModel(srv *httptest.Server) model {
	node := &StructureNode{Title: "Gadget", TypeName: "gadget"}
	m := model{
		ds:     apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t", Dataset: "production"}),
		focus:  focusState{Target: FocusPane, PaneIndex: 0},
		width:  120,
		height: 40,
	}
	m.panes = []Pane{m.buildDocListPane(node)}
	return m
}

func TestDocListMarksATruncatedPageAndLoadsMore(t *testing.T) {
	srv, _ := pagedServer(t, 131)
	m := pagedListModel(srv)
	p := m.panes[0]
	if len(p.Items) != 100 || !p.HasMore || docListCount(p) != "100+" {
		t.Fatalf("first page: %d items, HasMore=%v, count %q — want 100, true, \"100+\"", len(p.Items), p.HasMore, docListCount(p))
	}

	m.loadMoreDocs()
	p = m.panes[0]
	if len(p.Items) != 131 || p.HasMore || docListCount(p) != "131" {
		t.Fatalf("after +: %d items, HasMore=%v, count %q — want 131, false, \"131\"", len(p.Items), p.HasMore, docListCount(p))
	}
	// A refresh rebuild keeps the extended page.
	if again := m.buildDocListPane(p.Node); len(again.Items) != 131 {
		t.Errorf("rebuild after + listed %d, want the extended 131", len(again.Items))
	}
}

func TestDocListThatFitsShowsAPlainCount(t *testing.T) {
	srv, _ := pagedServer(t, 3)
	m := pagedListModel(srv)
	if p := m.panes[0]; len(p.Items) != 3 || p.HasMore || docListCount(p) != "3" {
		t.Fatalf("got %d items, HasMore=%v, count %q", len(p.Items), p.HasMore, docListCount(p))
	}
}

func TestRefPickerAsksForEveryCandidate(t *testing.T) {
	srv, queries := pagedServer(t, 131)
	m := pagedListModel(srv)
	*queries = nil
	m.openRefPicker(Field{Name: "author", Type: FieldReference, RefType: "gadget"})
	if len(m.refPicker.items) != 131 {
		t.Errorf("picker offered %d candidates, want all 131", len(m.refPicker.items))
	}
	if len(*queries) != 1 {
		t.Fatalf("want one query, got %v", *queries)
	}
	q := (*queries)[0]
	for _, want := range []string{"limit=1000", "fields=title"} {
		if !strings.Contains(q, want) {
			t.Errorf("picker query %q missing %s", q, want)
		}
	}
}
