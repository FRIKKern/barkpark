package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Editor-level pins for the v1-envelope normalization: the classic field
// editor reads doc.Values and saveDocument patches doc.ID — both were latently
// broken against the live flat envelope (legacy "id"/"values" keys never
// arrive). These decode the REAL envelope shape and walk the actual consumers.

const liveDocJSON = `{
	"_createdAt": "2026-06-05T10:19:18.901132Z",
	"_draft": true,
	"_id": "drafts.playground-unpublish-1",
	"_publishedId": "playground-unpublish-1",
	"_rev": "a49ab6f8b38b957cfa3d3a165aabce0f",
	"_type": "post",
	"_updatedAt": "2026-06-05T10:19:18.901132Z",
	"title": "Unpublish me",
	"status": "draft",
	"category": "Tech",
	"author": "Knut"
}`

func liveDoc(t *testing.T) *Doc {
	t.Helper()
	var d Doc
	if err := json.Unmarshal([]byte(liveDocJSON), &d); err != nil {
		t.Fatalf("decode live envelope: %v", err)
	}
	return &d
}

func TestGetFieldValueReadsEnvelopeFields(t *testing.T) {
	m := model{selectedDoc: liveDoc(t)}

	cases := map[string]string{
		"title":    "Unpublish me", // typed special-case
		"status":   "draft",        // typed special-case
		"category": "Tech",         // via normalized Values
		"author":   "Knut",         // via normalized Values
		"missing":  "",
	}
	for field, want := range cases {
		if got := m.getFieldValue(field); got != want {
			t.Errorf("getFieldValue(%q) = %q, want %q", field, got, want)
		}
	}
}

func TestSaveDocumentPatchesEnvelopeID(t *testing.T) {
	var captured []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m := model{
		ds:           apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}),
		selectedDoc:  liveDoc(t),
		editorSchema: &Schema{Name: "post"},
		dirty:        true,
		dirtyValues:  map[string]string{"category": "Updated"},
	}
	m.saveDocument()

	if m.statusErr {
		t.Fatalf("save reported error: %q", m.status)
	}
	var body struct {
		Mutations []struct {
			Patch struct {
				ID   string         `json:"id"`
				Type string         `json:"type"`
				Set  map[string]any `json:"set"`
			} `json:"patch"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil {
		t.Fatalf("parse captured body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	p := body.Mutations[0].Patch
	if p.ID != "drafts.playground-unpublish-1" {
		t.Errorf("patch id = %q, want the envelope _id (was \"\" before normalization)", p.ID)
	}
	if p.Type != "post" || p.Set["category"] != "Updated" {
		t.Errorf("patch payload wrong: type=%q set=%v", p.Type, p.Set)
	}
}

// TestEditorRendersRawObjectFields pins the read-only raw-JSON surface for
// non-scalar fields: a task's claim {worker, epoch, resources} must be
// VISIBLE in the editor (clamped pretty JSON), not a bare "..." placeholder —
// the terminal shows the same truth Studio's read-only panels do.
func TestEditorRendersRawObjectFields(t *testing.T) {
	docJSON := `{
		"_id": "drafts.task-9", "_type": "task", "_draft": true,
		"title": "Claimed task",
		"claim": {"worker": "agent-a", "epoch": 2, "resources": ["lib/render.ex"]}
	}`
	var d Doc
	if err := json.Unmarshal([]byte(docJSON), &d); err != nil {
		t.Fatalf("decode: %v", err)
	}

	m := model{
		width:       120,
		height:      40,
		selectedDoc: &d,
		editorSchema: &Schema{
			Name: "task",
			Fields: []Field{
				{Name: "title", Title: "Title", Type: FieldString},
				{Name: "claim", Title: "Claim", Type: FieldRaw},
			},
		},
	}

	out := m.buildEditorContent(100)
	for _, want := range []string{`"worker"`, "agent-a", "lib/render.ex"} {
		if !strings.Contains(out, want) {
			t.Errorf("editor must render the claim's %q, got no match", want)
		}
	}
}

// TestEditorEmptyObjectFieldKeepsPlaceholder: no data → the dim placeholder,
// not empty JSON noise.
func TestEditorEmptyObjectFieldKeepsPlaceholder(t *testing.T) {
	var d Doc
	_ = json.Unmarshal([]byte(`{"_id":"drafts.t1","_type":"task","title":"x"}`), &d)

	m := model{
		width: 120, height: 40, selectedDoc: &d,
		editorSchema: &Schema{Name: "task", Fields: []Field{
			{Name: "claim", Title: "Claim", Type: FieldRaw},
		}},
	}
	out := m.buildEditorContent(100)
	if strings.Contains(out, "{") {
		t.Errorf("empty object field must not render JSON, got: %q", out)
	}
}

// TestEditorScrollReachesTailFields drives j through handleKey across a long
// (24-field, task-dossier-shaped) form and asserts the viewport follows the
// cursor all the way down. The old ~3-lines-per-field scroll heuristic
// undershot boxed fields (~5-6 real lines), so the viewport stopped following
// around field 13 and the tail (claim/dependencies) was keyboard-unreachable.
func TestEditorScrollReachesTailFields(t *testing.T) {
	fields := make([]Field, 0, 24)
	for i := 0; i < 19; i++ {
		fields = append(fields, Field{Name: fmt.Sprintf("f%d", i), Title: fmt.Sprintf("F%d", i), Type: FieldString})
	}
	fields = append(fields, Field{Name: "claim", Title: "Claim", Type: FieldRaw})
	for i := 20; i < 24; i++ {
		fields = append(fields, Field{Name: fmt.Sprintf("f%d", i), Title: fmt.Sprintf("F%d", i), Type: FieldRaw})
	}

	var d Doc
	_ = json.Unmarshal([]byte(`{"_id":"drafts.t1","_type":"task","title":"x",
		"claim":{"worker":"agent-a","epoch":1,"resources":["lib/render.ex"]}}`), &d)

	m := model{
		width: 140, height: 40,
		selectedDoc:  &d,
		editorSchema: &Schema{Name: "task", Title: "Task", Fields: fields},
		showEditor:   true,
		focus:        focusState{Target: FocusEditor},
	}
	m.viewport = viewport.New(100, 30)
	m.vpReady = true
	m.refreshViewport()

	for i := 0; i < 19; i++ {
		mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
		m = mm.(model)
	}
	if m.fieldCursor != 19 {
		t.Fatalf("fieldCursor = %d, want 19 (the claim field)", m.fieldCursor)
	}

	// The claim field's REAL first line must be inside the visible window.
	fieldWidth := m.calcEditorWidth() - 4
	if fieldWidth < 20 {
		fieldWidth = 20
	}
	target := 4
	for i := 0; i < 19; i++ {
		target += len(m.renderField(m.editorSchema.Fields[i], fieldWidth, false, false)) + 1
	}
	top, bottom := m.viewport.YOffset, m.viewport.YOffset+m.viewport.Height
	if target < top || target > bottom {
		t.Errorf("claim line %d outside visible window [%d, %d] — scroll did not follow", target, top, bottom)
	}
}
