package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// server_desk_open_test.go pins what the stranger walk (2026-09-30, a fresh
// local instance, the TUI in a pty) found broken on the SERVER desk:
//
//  1. Studio's desk puts `document_type_list` nodes directly in the root list.
//     rebuildPanes only followed .Child, so Enter on "Post" opened nothing and
//     the editor column said "Select a document to edit" over no list.
//  2. A schema field named `body` (a plain `text` field on a post) never showed
//     its stored value: the envelope's reserved keys are kept out of Doc.Values.
//  3. A document with no title rendered as a bare status dot.

const serverDeskPostsPage = `{"result":{"count":2,"documents":[
  {"_id":"hello","_type":"post","_draft":false,"_updatedAt":"2026-09-30T07:44:22Z","title":"Hello","body":"x"},
  {"_id":"drafts.notitle","_type":"post","_draft":true,"_updatedAt":"2026-09-30T07:44:22Z","body":"no title here"}
]}}`

func serverDeskRoot(t *testing.T) {
	t.Helper()
	prevSchemas, prevRoot := schemas, rootStructure
	t.Cleanup(func() { schemas, rootStructure = prevSchemas, prevRoot })
	schemas = []Schema{{Name: "post", Title: "Post"}}
	var n apiclientDeskNode
	if err := json.Unmarshal([]byte(`{"id":"root","type":"list","title":"Structure","items":[
	  {"id":"post","type":"document_type_list","title":"Post","typeName":"post"},
	  {"id":"div-1","type":"divider"}
	]}`), &n); err != nil {
		t.Fatalf("decode desk: %v", err)
	}
	rootStructure = fromDeskNode(n)
	if rootStructure == nil || len(rootStructure.Items) == 0 || rootStructure.Items[0].Child != nil {
		t.Fatalf("fixture must be the server shape: a document_type_list DIRECTLY in the root list, no Child; got %+v", rootStructure)
	}
}

func TestServerDeskDocumentTypeListOpens(t *testing.T) {
	serverDeskRoot(t)
	m := modelAgainst(t, 200, serverDeskPostsPage)
	m.width, m.height = 120, 40
	m.path = []string{"post"}
	m.rebuildPanes()
	if len(m.panes) != 2 || !m.panes[1].IsDocList {
		t.Fatalf("Enter on a server-desk document_type_list must open its document list; got %d pane(s)", len(m.panes))
	}
	if got := len(m.panes[1].Items); got != 2 {
		t.Fatalf("doc list has %d rows, want 2", got)
	}
	// The untitled row names itself instead of rendering a bare dot.
	if title := m.panes[1].Items[1].Title; !strings.Contains(title, "Untitled") || !strings.Contains(title, "notitle") {
		t.Errorf("an untitled document's row reads %q, want it to say Untitled and name its id", title)
	}
	// The preview column (renderPreview's structure-item arm) resolves the same way.
	if opensTo(rootStructure.Items[0]) != rootStructure.Items[0] {
		t.Error("opensTo must return a childless document_type_list itself")
	}
	if opensTo(rootStructure.Items[1]) != nil {
		t.Error("a divider opens to nothing")
	}
}

func TestBodyFieldShowsItsStoredValue(t *testing.T) {
	serverDeskRoot(t)
	m := modelAgainst(t, 200, serverDeskPostsPage)
	docs, _ := m.ds.QueryResult("post", "")
	if len(docs) != 2 {
		t.Fatalf("fixture: %d docs", len(docs))
	}
	m.selectedDoc = &docs[0]
	if got := m.getFieldValue("body"); got != "x" {
		t.Fatalf("getFieldValue(body) = %q, want the stored \"x\" — a `body: text` field must show its value", got)
	}
	if got := m.getFieldValue("title"); got != "Hello" {
		t.Fatalf("title regressed: %q", got)
	}
}
