package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Array-of-strings editing pins (2026-06-12): a FieldArray whose CURRENT
// value is a JSON array of strings (or empty/absent/null) edits in the
// multi-line textarea, one element per line — enter adds an element, ctrl+s
// commits, and commitFieldEdit marshals the lines (trimmed, empties dropped)
// back to a JSON array string in dirtyValues. Arrays containing ANY
// non-string element refuse to open an editor (status line explains why),
// exactly the pre-edit read-only behaviour. saveDocument is TYPED for these
// fields: the patch "set" map carries the real JSON array on the wire, never
// a JSON-encoded string — the server merges the set map verbatim with no
// coercion, so a string would silently change the stored JSONB type.

func arrayModel(extra map[string]json.RawMessage) model {
	return model{
		selectedDoc: &Doc{
			ID:    "drafts.p1",
			Title: "Doc",
			Extra: extra,
		},
		editorSchema: &apiclient.Schema{Name: "post", Fields: []Field{
			{Name: "tags", Title: "Tags", Type: FieldArray},
		}},
		focus:      focusState{Target: FocusEditor},
		showEditor: true,
		width:      100,
		height:     40,
	}
}

func rawTags(s string) map[string]json.RawMessage {
	return map[string]json.RawMessage{"tags": json.RawMessage(s)}
}

// ── Seeding: one element per line ────────────────────────────────────────────

func TestArrayEditSeedsOneElementPerLine(t *testing.T) {
	m := arrayModel(rawTags(`["alpha","beta","gamma"]`))
	cmd := m.startFieldEdit()
	if !m.editing || !m.editingMultiline {
		t.Fatal("a string array should open the multi-line editor")
	}
	if cmd == nil {
		t.Error("textarea focus should return its cursor cmd")
	}
	if got := m.textArea.Value(); got != "alpha\nbeta\ngamma" {
		t.Errorf("seed = %q, want one element per line", got)
	}
}

func TestArrayEmptyOrAbsentEditsFromScratch(t *testing.T) {
	// Absent, empty array, and null all open an empty editor — there is
	// nothing to corrupt, and "[ ] No items yet" needs an add path.
	for name, extra := range map[string]map[string]json.RawMessage{
		"absent": nil,
		"empty":  rawTags(`[]`),
		"null":   rawTags(`null`),
	} {
		m := arrayModel(extra)
		m.startFieldEdit()
		if !m.editing || !m.editingMultiline {
			t.Errorf("%s value should still open the editor", name)
			continue
		}
		if got := m.textArea.Value(); got != "" {
			t.Errorf("%s value should seed empty, got %q", name, got)
		}
	}
}

func TestArrayReseedsFromCommittedDirtyValue(t *testing.T) {
	// A committed-but-unsaved edit lives in dirtyValues as the marshalled
	// JSON array string — reopening the editor must seed from IT, not the
	// stale wire value in Extra.
	m := arrayModel(rawTags(`["old"]`))
	m.dirtyValues = map[string]string{"tags": `["new-a","new-b"]`}
	m.startFieldEdit()
	if got := m.textArea.Value(); got != "new-a\nnew-b" {
		t.Errorf("seed = %q, want the dirty value's elements", got)
	}
}

// ── Refusal: any non-string element stays read-only ──────────────────────────

func TestArrayNonStringElementsRefuseEdit(t *testing.T) {
	for name, raw := range map[string]string{
		"numbers":      `[1,2,3]`,
		"mixed":        `["a",{"b":1}]`,
		"nested array": `[["a"]]`,
		"null element": `["a",null]`,
		"bool element": `[true]`,
		"object value": `{"k":"v"}`,
		"scalar value": `"just a string"`,
	} {
		m := arrayModel(rawTags(raw))
		cmd := m.startFieldEdit()
		if m.editing || m.editingMultiline {
			t.Errorf("%s (%s) must NOT open an editor", name, raw)
		}
		if cmd != nil {
			t.Errorf("%s: refusal should return no focus cmd", name)
		}
		if !m.statusErr || !strings.Contains(m.status, "read-only") {
			t.Errorf("%s: refusal should explain via the status line, got %q", name, m.status)
		}
	}
}

// ── Commit: lines → JSON array string, trimmed, empties dropped ──────────────

func TestArrayCommitMarshalsLinesToJSONArray(t *testing.T) {
	m := arrayModel(rawTags(`["alpha"]`))
	m.startFieldEdit()
	m.textArea.SetValue("  x  \n\ny\nz\n")

	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyCtrlS})
	m2 := mm.(model)
	if m2.editing || m2.editingMultiline {
		t.Fatal("ctrl+s must commit and leave editing mode")
	}
	if got := m2.dirtyValues["tags"]; got != `["x","y","z"]` {
		t.Errorf("dirtyValues[tags] = %q, want trimmed elements, empties dropped", got)
	}
	if !m2.dirty {
		t.Error("commit must mark the doc dirty")
	}
}

func TestArrayCommitAllEmptyLinesIsEmptyArray(t *testing.T) {
	if got := marshalArrayLines("  \n\n  "); got != "[]" {
		t.Errorf("marshalArrayLines = %q, want [] (never null)", got)
	}
}

func TestArrayCommitMirrorsIntoExtra(t *testing.T) {
	// The read path (rawFieldJSON / arrayStringItems) reads Doc.Extra, not
	// Values — commit must mirror the array there so the next renderField
	// shows the new items immediately, before AND after save.
	m := arrayModel(rawTags(`["old"]`))
	m.startFieldEdit()
	m.textArea.SetValue("fresh\nitems")
	m.commitFieldEdit()

	if got := string(m.selectedDoc.Extra["tags"]); got != `["fresh","items"]` {
		t.Errorf("Extra[tags] = %s, want the committed array", got)
	}
	out := strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "fresh") || strings.Contains(out, "old") {
		t.Errorf("renderField should show the new array, got:\n%s", out)
	}
}

// ── Save: the wire body carries a NATIVE JSON array, never a string ──────────

func TestSaveSendsTypedArrayBody(t *testing.T) {
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

	m := arrayModel(rawTags(`["old"]`))
	m.editorSchema.Fields = append(m.editorSchema.Fields,
		Field{Name: "subtitle", Title: "Subtitle", Type: FieldString})
	m.ds = apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	m.dirtyValues = map[string]string{
		"tags":     `["a","b"]`,
		"subtitle": "plain words",
	}
	m.dirty = true
	m.saveDocument()

	var body struct {
		Mutations []struct {
			Patch struct {
				ID   string                     `json:"id"`
				Type string                     `json:"type"`
				Set  map[string]json.RawMessage `json:"set"`
			} `json:"patch"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil {
		t.Fatalf("parse captured mutate body: %v (body %s)", err, captured)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	set := body.Mutations[0].Patch.Set

	// tags must be a JSON array of strings on the wire — the live probe
	// showed a string here stores the literal "[\"a\",\"b\"]" in Postgres.
	var tags []string
	if err := json.Unmarshal(set["tags"], &tags); err != nil {
		t.Fatalf("set.tags is not a JSON array: %s", set["tags"])
	}
	if !reflect.DeepEqual(tags, []string{"a", "b"}) {
		t.Errorf("set.tags = %v, want [a b]", tags)
	}

	// Non-array fields keep the string behaviour byte-identically.
	var subtitle string
	if err := json.Unmarshal(set["subtitle"], &subtitle); err != nil {
		t.Fatalf("set.subtitle is not a JSON string: %s", set["subtitle"])
	}
	if subtitle != "plain words" {
		t.Errorf("set.subtitle = %q", subtitle)
	}

	// Save succeeded — dirty state clears, and the doc stays coherent: Extra
	// still carries the array (mirrored at commit), so renderField shows it.
	if m.dirty || m.dirtyValues != nil {
		t.Errorf("save should clear dirty state, got dirty=%v values=%v", m.dirty, m.dirtyValues)
	}
}
