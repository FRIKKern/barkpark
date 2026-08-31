package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// modelAgainst builds a bare model whose data store points at a server that
// answers every query with the given status + body.
func modelAgainst(t *testing.T, status int, body string) model {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return model{ds: apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t", Dataset: "production"})}
}

func postsNode() *StructureNode {
	return &StructureNode{Type: NodeDocumentTypeList, TypeName: "post", Title: "Posts"}
}

// The bug this pins: a doc-list pane whose query FAILED had no rows, and the
// zero-rows branch rendered "No documents yet" — telling the user the type is
// empty when the read never landed. Both list surfaces must report the
// failure instead.
func TestDocListPreviewReportsAFailedReadInsteadOfEmpty(t *testing.T) {
	for _, status := range []int{401, 403, 500, 502} {
		m := modelAgainst(t, status, `{"error":"nope"}`)
		out := m.buildDocListPreview(postsNode(), 46, 12)
		if strings.Contains(out, "No documents yet") {
			t.Errorf("HTTP %d rendered as an empty type:\n%s", status, out)
		}
		if !strings.Contains(out, "Couldn't load documents") {
			t.Errorf("HTTP %d did not report the failed read:\n%s", status, out)
		}
	}
}

func TestFocusedDocListPaneReportsAFailedRead(t *testing.T) {
	m := modelAgainst(t, 500, `{"error":"boom"}`)
	m.width, m.height = 100, 30
	pane := m.buildDocListPane(postsNode())
	if !pane.ReadFailed {
		t.Fatal("a 500 must set Pane.ReadFailed")
	}
	out := m.renderPane(pane, 46, 12, true)
	if strings.Contains(out, "No documents yet") {
		t.Errorf("focused pane rendered a failed read as empty:\n%s", out)
	}
	if !strings.Contains(out, "Couldn't load documents") {
		t.Errorf("focused pane did not report the failed read:\n%s", out)
	}
}

// The other half of the contract: an honestly empty type is still an honestly
// empty type. A decodable 200 with zero rows keeps the create affordance and
// must never be dressed up as a failure.
func TestHonestlyEmptyTypeStillSaysEmpty(t *testing.T) {
	m := modelAgainst(t, 200, `{"result":{"count":0,"documents":[]}}`)
	pane := m.buildDocListPane(postsNode())
	if pane.ReadFailed {
		t.Fatal("a decodable 200 with zero rows must NOT be marked ReadFailed")
	}
	out := m.buildDocListPreview(postsNode(), 46, 12)
	if !strings.Contains(out, "No documents yet") {
		t.Errorf("empty type lost its empty state:\n%s", out)
	}
	if strings.Contains(out, "Couldn't load documents") {
		t.Errorf("empty type reported a failure it did not have:\n%s", out)
	}
}

// The header count is a claim about the store. A failed read produced no
// number, so it must not print "0".
func TestDocListHeaderCountRefusesToInventZero(t *testing.T) {
	failed := Pane{IsDocList: true, ReadFailed: true}
	if got := docListCount(failed); got != "—" {
		t.Errorf("failed read header count = %q, want %q", got, "—")
	}
	empty := Pane{IsDocList: true}
	if got := docListCount(empty); got != "0" {
		t.Errorf("honestly empty header count = %q, want %q", got, "0")
	}
	full := Pane{IsDocList: true, Items: []PaneItem{{ID: "a"}, {ID: "b"}}}
	if got := docListCount(full); got != "2" {
		t.Errorf("populated header count = %q, want %q", got, "2")
	}
}

// The two placeholders must stay distinguishable — that separation IS the fix.
func TestFailedAndEmptyInteriorsAreDistinct(t *testing.T) {
	failed := strings.Join(failedDocListInterior(), "\n")
	empty := strings.Join(emptyDocListInterior(true), "\n")
	if strings.Contains(failed, "No documents yet") {
		t.Errorf("failure placeholder reuses the empty wording:\n%s", failed)
	}
	if strings.Contains(empty, "Couldn't load") {
		t.Errorf("empty placeholder reuses the failure wording:\n%s", empty)
	}
	// The failure state offers no key: the TUI binds no refresh key, and the
	// empty state's own test already forbids advertising one it can't honour.
	if strings.Contains(failed, "press ") {
		t.Errorf("failure placeholder advertises a key the TUI does not bind:\n%s", failed)
	}
}
