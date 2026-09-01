package main

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// The doc-list panes are covered in doclist_read_failure_test.go. This file
// covers the OTHER TUI surfaces that read through Query and rendered a failed
// read as an absence: the single-document editor, its preview column, and the
// reference picker.

const emptyPage = `{"result":{"count":0,"documents":[]}}`

func docNode() *StructureNode {
	return &StructureNode{Type: NodeDocument, TypeName: "settings", Title: "Settings"}
}

// ── NodeDocument: the editor ─────────────────────────────────────────────────

// A NodeDocument whose read failed left selectedDoc nil, and renderEditor fell
// through to the "Select a document to edit" splash — inviting a choice from a
// list that was never fetched.
func TestEditorReportsAFailedSingleDocumentRead(t *testing.T) {
	m := modelAgainst(t, 503, `{"error":"down"}`)
	m.path = []string{"settings"}
	docs, outcome := m.ds.QueryResult(docNode().TypeName, "")
	if len(docs) != 0 || !outcome.Failed() {
		t.Fatalf("fixture: want a failed empty read, got %d docs outcome=%d", len(docs), outcome)
	}
	m.docReadFailed = outcome.Failed()

	out := m.renderEditor(60, 14, true)
	if strings.Contains(out, "Select a document") || strings.Contains(out, "Select a content type") {
		t.Errorf("failed document read rendered the empty-state splash:\n%s", out)
	}
	if !strings.Contains(out, "Couldn't load this document") {
		t.Errorf("failed document read did not report the failure:\n%s", out)
	}
}

// The honest empty case keeps the splash it always had.
func TestEditorKeepsTheEmptySplashOnAnHonestEmptyRead(t *testing.T) {
	m := modelAgainst(t, 200, emptyPage)
	m.path = []string{"settings"}
	_, outcome := m.ds.QueryResult(docNode().TypeName, "")
	if outcome.Failed() {
		t.Fatalf("fixture: want an OK read, got outcome=%d", outcome)
	}
	m.docReadFailed = outcome.Failed()

	out := m.renderEditor(60, 14, true)
	if !strings.Contains(out, "Select a document") {
		t.Errorf("honest empty read lost the empty-state splash:\n%s", out)
	}
	if strings.Contains(out, "Couldn't load") {
		t.Errorf("honest empty read reported a failure it did not have:\n%s", out)
	}
}

// rebuildPanes owns the flag: it must SET it when the singleton's read fails
// and CLEAR it on a rebuild that succeeds, so a transient failure can never
// stick to the editor after the server comes back.
func TestRebuildPanesSetsAndClearsDocReadFailed(t *testing.T) {
	singletonRoot := func(t *testing.T) {
		t.Helper()
		prevSchemas, prevRoot := schemas, rootStructure
		t.Cleanup(func() { schemas, rootStructure = prevSchemas, prevRoot })
		schemas = []Schema{{Name: "settings", Title: "Settings", Icon: "⚙"}}
		rootStructure = List().ID("root").Title("Structure").Items(
			ListItem().ID("settings").Title("Settings").
				Child(Document().SchemaType("settings").DocumentID("settings").Build()).
				Build(),
		).Build()
	}

	t.Run("failed read sets it", func(t *testing.T) {
		singletonRoot(t)
		m := modelAgainst(t, 500, `{"error":"boom"}`)
		m.width, m.height = 120, 40
		m.path = []string{"settings"}
		m.rebuildPanes()
		if !m.docReadFailed {
			t.Fatal("a failed singleton read left docReadFailed false — the editor would show the empty splash")
		}
		if m.selectedDoc != nil {
			t.Fatalf("a failed read produced a document: %+v", m.selectedDoc)
		}
		out := m.renderEditor(60, 14, true)
		if !strings.Contains(out, "Couldn't load this document") {
			t.Errorf("editor did not report the failed singleton read:\n%s", out)
		}
	})

	t.Run("successful read clears it", func(t *testing.T) {
		singletonRoot(t)
		m := modelAgainst(t, 200, `{"result":{"documents":[{"_id":"settings","_type":"settings","title":"Settings"}]}}`)
		m.width, m.height = 120, 40
		m.path = []string{"settings"}
		m.docReadFailed = true // stale flag from an earlier failure
		m.rebuildPanes()
		if m.docReadFailed {
			t.Error("a successful rebuild left the stale failure flag set")
		}
		if m.selectedDoc == nil {
			t.Fatal("a successful read selected no document")
		}
	})
}

// ── NodeDocument: the preview column ─────────────────────────────────────────

// The NodeDocument preview returned a bare "" on a failed read — a literally
// blank column, the most silent form of the same lie.
func TestNodeDocumentPreviewReportsAFailedRead(t *testing.T) {
	build := func(status int, body string) string {
		m := modelAgainst(t, status, body)
		host := &StructureNode{Type: NodeList, Title: "Root"}
		item := &StructureNode{ID: "settings", Title: "Settings", Child: docNode()}
		host.Items = []*StructureNode{item}
		m.panes = []Pane{{
			Node:  host,
			Items: []PaneItem{{ID: "settings", Title: "Settings", SourceNode: item}},
		}}
		m.focus = focusState{Target: FocusPane, PaneIndex: 0}
		return m.renderPreview(40, 10)
	}

	failed := build(500, `{"error":"boom"}`)
	if strings.TrimSpace(failed) == "" {
		t.Error("failed NodeDocument preview rendered a blank column")
	}
	if !strings.Contains(failed, "Couldn't load this document") {
		t.Errorf("failed NodeDocument preview did not report the failure:\n%s", failed)
	}

	// An honest empty read keeps the old blank preview — there is genuinely
	// nothing to show, and inventing an error there would be the same lie
	// pointed the other way.
	ok := build(200, emptyPage)
	if strings.Contains(ok, "Couldn't load") {
		t.Errorf("honest empty read reported a failure it did not have:\n%s", ok)
	}
}

// ── Reference picker ─────────────────────────────────────────────────────────

// openRefPicker reported EVERY empty list as "no <type> documents" — asserting
// the type is empty over a refusal. The two suggest opposite next steps.
func TestRefPickerNamesAFailedReadRatherThanClaimingEmpty(t *testing.T) {
	m := modelAgainst(t, 403, `{"error":"forbidden"}`)
	m.openRefPicker(Field{Name: "author", Type: FieldReference, RefType: "person"})
	if got := m.refPicker.err; !strings.Contains(got, "couldn't load person") {
		t.Errorf("refused ref read reported %q, want it to name the failure", got)
	}
	if strings.Contains(m.refPicker.err, "no person documents") {
		t.Errorf("refused ref read claimed the type is empty: %q", m.refPicker.err)
	}
}

func TestRefPickerStillSaysEmptyForAnHonestlyEmptyType(t *testing.T) {
	m := modelAgainst(t, 200, emptyPage)
	m.openRefPicker(Field{Name: "author", Type: FieldReference, RefType: "person"})
	if got := m.refPicker.err; got != "no person documents" {
		t.Errorf("honestly empty ref type reported %q, want %q", got, "no person documents")
	}
}

func TestRefPickerEmptyErrorMapping(t *testing.T) {
	if got := refPickerEmptyError("person", apiclient.DocReadOK); got != "no person documents" {
		t.Errorf("OK → %q", got)
	}
	for _, o := range []apiclient.DocReadOutcome{
		apiclient.DocReadForbidden, apiclient.DocReadServerError,
		apiclient.DocReadUnreachable, apiclient.DocReadNotFound,
	} {
		got := refPickerEmptyError("person", o)
		if !strings.HasPrefix(got, "couldn't load person") {
			t.Errorf("outcome %d → %q, want a failure message", o, got)
		}
	}
}

// cacheRefTitlesFor marks a reference "broken" with a "" sentinel. It used to
// gate that on len(docs) > 0, a proxy wrong in BOTH directions: a FAILED read
// marked nothing (right, by luck) but so did a SUCCESSFUL read of an empty
// type — leaving a genuinely dangling reference unflagged.
func TestCacheRefTitlesMarksBrokenOnlyOnASuccessfulRead(t *testing.T) {
	schema := &Schema{
		Name:   "post",
		Fields: []Field{{Name: "author", Type: FieldReference, RefType: "person"}},
	}

	// A successful read of an EMPTY type: the reference is genuinely dangling.
	ok := modelAgainst(t, 200, emptyPage)
	ok.selectedDoc = &Doc{ID: "p1", Values: map[string]string{"author": "person-gone"}}
	ok.editorSchema = schema
	ok.refTitles = map[string]string{}
	ok.cacheRefTitlesFor(schema)
	if title, marked := ok.refTitles["person-gone"]; !marked || title != "" {
		t.Errorf("a successful read of an empty type must mark the dangling ref broken; got (%q, %v)", title, marked)
	}

	// A FAILED read: we learned nothing, so nothing may be marked broken.
	failed := modelAgainst(t, 500, `{"error":"boom"}`)
	failed.selectedDoc = &Doc{ID: "p1", Values: map[string]string{"author": "person-maybe-fine"}}
	failed.editorSchema = schema
	failed.refTitles = map[string]string{}
	failed.cacheRefTitlesFor(schema)
	if _, marked := failed.refTitles["person-maybe-fine"]; marked {
		t.Error("a failed read marked a reference broken on no evidence")
	}
}
