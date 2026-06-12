package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Typed-save pins, round 2 (2026-06-12): numbers and booleans join arrays on
// the wire as REAL JSON types — task.priority's validator hard-rejects the
// string "3" (verified live), and untyped schemas would silently store the
// wrong JSONB type. Number/datetime commits validate; a refused commit keeps
// the editor open.

func typedModel(fields []Field, values map[string]string) model {
	return model{
		selectedDoc: &Doc{ID: "drafts.t1", Title: "T", Values: values},
		editorSchema: &apiclient.Schema{Name: "task", Fields: fields},
		focus:        focusState{Target: FocusEditor},
		showEditor:   true,
		width:        100, height: 40,
	}
}

func TestSaveSendsTypedNumberAndBoolean(t *testing.T) {
	var captured []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"result":{"documents":[],"count":0}}`))
			return
		}
		captured, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m := typedModel([]Field{
		{Name: "priority", Title: "Priority", Type: FieldNumber},
		{Name: "featured", Title: "Featured", Type: FieldBoolean},
		{Name: "note", Title: "Note", Type: FieldString},
	}, map[string]string{})
	m.ds = apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	m.dirty = true
	m.dirtyValues = map[string]string{"priority": "3", "featured": "true", "note": "42"}

	m.saveDocument()

	var body struct {
		Mutations []struct {
			Patch struct {
				Set map[string]json.RawMessage `json:"set"`
			} `json:"patch"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil || len(body.Mutations) != 1 {
		t.Fatalf("bad captured body: %v %s", err, captured)
	}
	set := body.Mutations[0].Patch.Set
	if string(set["priority"]) != "3" {
		t.Errorf("priority on the wire = %s, want the JSON number 3", set["priority"])
	}
	if string(set["featured"]) != "true" {
		t.Errorf("featured on the wire = %s, want the JSON boolean true", set["featured"])
	}
	// A string field whose VALUE is numeric stays a string — type comes from
	// the schema, never from the value.
	if string(set["note"]) != `"42"` {
		t.Errorf("note on the wire = %s, want the JSON string \"42\"", set["note"])
	}
}

func TestNumberCommitValidates(t *testing.T) {
	m := typedModel([]Field{{Name: "priority", Title: "Priority", Type: FieldNumber}}, map[string]string{})
	m.startFieldEdit()
	m.textInput.SetValue("not-a-number")

	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	nm := next.(model)
	if !nm.editing {
		t.Error("a refused number commit must keep the editor open")
	}
	if !nm.statusErr || !strings.Contains(nm.status, "not a number") {
		t.Errorf("status should explain, got %q", nm.status)
	}
	if _, ok := nm.dirtyValues["priority"]; ok {
		t.Error("refused commit must not write dirtyValues")
	}

	// Valid input commits and closes.
	nm.textInput.SetValue(" 2 ")
	after, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	am := after.(model)
	if am.editing || am.dirtyValues["priority"] != "2" {
		t.Errorf("valid number should commit trimmed, got editing=%v val=%q", am.editing, am.dirtyValues["priority"])
	}
}

func TestNormalizeDatetime(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{"", "", true},
		{"2026-06-12", "2026-06-12", true},
		{"2026-06-12 14:30", "2026-06-12T14:30", true},
		{"2026-06-12T14:30", "2026-06-12T14:30", true},
		{"2026-06-12T14:30:00Z", "2026-06-12T14:30:00Z", true},
		{"garbage", "", false},
		{"2026-13-99", "", false},
	}
	for _, c := range cases {
		got, ok := normalizeDatetime(c.in)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("normalizeDatetime(%q) = (%q, %v), want (%q, %v)", c.in, got, ok, c.want, c.ok)
		}
	}
	// "now" stamps an RFC3339 UTC moment.
	if got, ok := normalizeDatetime("now"); !ok || !strings.HasSuffix(got, "Z") || len(got) < 20 {
		t.Errorf("normalizeDatetime(now) = (%q, %v)", got, ok)
	}
}

func TestDatetimeCommitRefusesGarbage(t *testing.T) {
	m := typedModel([]Field{{Name: "publishedAt", Title: "Published At", Type: FieldDatetime}}, map[string]string{})
	m.startFieldEdit()
	m.textInput.SetValue("next tuesday")
	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	nm := next.(model)
	if !nm.editing || !nm.statusErr {
		t.Errorf("garbage datetime should refuse and stay editing (editing=%v err=%v)", nm.editing, nm.statusErr)
	}

	nm.textInput.SetValue("2026-06-12 09:00")
	after, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	am := after.(model)
	if am.dirtyValues["publishedAt"] != "2026-06-12T09:00" {
		t.Errorf("datetime normalize on commit = %q", am.dirtyValues["publishedAt"])
	}
}

func TestNumberFieldRenderAndAnnotation(t *testing.T) {
	m := typedModel([]Field{{Name: "priority", Title: "Priority", Type: FieldNumber}},
		map[string]string{"priority": "2"})
	out := strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "[num]") {
		t.Errorf("number label should carry [num], got:\n%s", out)
	}
	if !strings.Contains(out, "2") {
		t.Errorf("number value should render, got:\n%s", out)
	}
}

// Legacy textinput-direct commits (no key routing) still work — the bool
// return is ignorable for existing callers.
func TestCommitFieldEditDirectCallStillWorks(t *testing.T) {
	m := typedModel([]Field{{Name: "note", Title: "Note", Type: FieldString}}, map[string]string{})
	m.textInput = textinput.New()
	m.textInput.SetValue("hello")
	if !m.commitFieldEdit() {
		t.Fatal("string commit should succeed")
	}
	if m.dirtyValues["note"] != "hello" {
		t.Errorf("dirty = %q", m.dirtyValues["note"])
	}
}

// Validation affordances (Sanity parity): required fields carry the asterisk
// marker + a "(required)" annotation while empty; a schema pattern refuses a
// violating commit (server still owns enforcement — drafts warn, publish
// blocks).
func TestRequiredMarkerAndAnnotation(t *testing.T) {
	f := Field{Name: "kind", Title: "Kind", Type: FieldString, Required: true}
	m := typedModel([]Field{f}, map[string]string{})

	out := strings.Join(m.renderField(f, 60, false, false), "\n")
	if !strings.Contains(out, "KIND *") {
		t.Errorf("required label should carry the asterisk, got:\n%s", out)
	}
	if !strings.Contains(out, "(required)") {
		t.Errorf("empty required field should annotate, got:\n%s", out)
	}

	// Filled → the annotation goes quiet; the marker stays.
	m.selectedDoc.Values = map[string]string{"kind": "task"}
	out = strings.Join(m.renderField(f, 60, false, false), "\n")
	if strings.Contains(out, "(required)") {
		t.Errorf("filled required field must not nag, got:\n%s", out)
	}
	if !strings.Contains(out, "KIND *") {
		t.Errorf("marker should persist when filled, got:\n%s", out)
	}
}

func TestPatternCommitRefusesViolation(t *testing.T) {
	f := Field{Name: "code", Title: "Code", Type: FieldString, Pattern: "^[A-Z]{3}-[0-9]+$"}
	m := typedModel([]Field{f}, map[string]string{})
	m.startFieldEdit()
	m.textInput.SetValue("nope")

	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	nm := next.(model)
	if !nm.editing || !nm.statusErr || !strings.Contains(nm.status, "pattern") {
		t.Errorf("pattern violation should refuse and stay editing (editing=%v status=%q)", nm.editing, nm.status)
	}

	nm.textInput.SetValue("ABC-42")
	after, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	am := after.(model)
	if am.editing || am.dirtyValues["code"] != "ABC-42" {
		t.Errorf("matching value should commit, got editing=%v val=%q", am.editing, am.dirtyValues["code"])
	}

	// Empty always commits (clearing is not a pattern violation); an invalid
	// regex fails open.
	am.editorSchema.Fields[0].Pattern = "(["
	am.fieldCursor = 0
	am.startFieldEdit()
	am.textInput.SetValue("anything")
	final, _ := am.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	fm := final.(model)
	if fm.editing {
		t.Error("invalid schema regex must fail open, not lock the field")
	}
}

// Round 3 polish: long selects open the filterable picker, short ones keep
// the in-place cycle; color commits canonicalize #rrggbb; the API error
// envelope renders human.
func TestSelectRoutingByOptionCount(t *testing.T) {
	short := Field{Name: "size", Title: "Size", Type: FieldSelect, Options: []string{"s", "m", "l"}}
	m := typedModel([]Field{short}, map[string]string{})
	m.startFieldEdit()
	if m.refPicker.active {
		t.Error("3 options should cycle in place, not open the picker")
	}
	if m.dirtyValues["size"] == "" {
		t.Error("cycle should have advanced the value")
	}

	long := Field{Name: "status", Title: "Status", Type: FieldSelect,
		Options: []string{"planning", "active", "review", "blocked", "completed", "archived"}}
	// "status" is a ROW field (getFieldValue's special case, mirroring the
	// server's title/status row contract) — it reads Doc.Status, not Values.
	m = typedModel([]Field{long}, map[string]string{})
	m.selectedDoc.Status = "review"
	m.startFieldEdit()
	if !m.refPicker.active {
		t.Fatal("6 options should open the picker")
	}
	if m.refPicker.cursor != 3 {
		t.Errorf("cursor should land on the current option (review=row 3), got %d", m.refPicker.cursor)
	}
	// Picking a row writes the option string verbatim.
	m.refPicker.cursor = 5
	next, _ := m.handleRefPickerKey(tea.KeyMsg{Type: tea.KeyEnter})
	nm := next.(model)
	if nm.dirtyValues["status"] != "completed" {
		t.Errorf("picked %q, want completed", nm.dirtyValues["status"])
	}
}

func TestColorCommitCanonicalizes(t *testing.T) {
	m := typedModel([]Field{{Name: "accent", Title: "Accent", Type: FieldColor}}, map[string]string{})
	m.startFieldEdit()
	m.textInput.SetValue("3B82F6")
	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	nm := next.(model)
	if nm.dirtyValues["accent"] != "#3b82f6" {
		t.Errorf("color canonical = %q, want #3b82f6", nm.dirtyValues["accent"])
	}

	nm.startFieldEdit()
	nm.textInput.SetValue("teal")
	after, _ := nm.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	am := after.(model)
	if !am.editing || !strings.Contains(am.status, "color") {
		t.Errorf("named colors refuse (editing=%v status=%q)", am.editing, am.status)
	}
}

// Render-layer premium round (2026-06-12): broken references warn, unsaved
// edits dot the label, datetimes show their distance from now.
func TestBrokenReferenceWarns(t *testing.T) {
	f := Field{Name: "author", Title: "Author", Type: FieldReference, RefType: "author"}
	m := typedModel([]Field{f}, map[string]string{"author": "ghost"})

	// Unchecked (no cache entry): bare id, no warning — fetch may have failed.
	out := strings.Join(m.renderField(f, 60, false, false), "\n")
	if strings.Contains(out, "not found") {
		t.Errorf("unchecked ref must not warn:\n%s", out)
	}

	// Checked-and-missing (the cacheRefTitlesFor sentinel): warn.
	m.refTitles = map[string]string{"ghost": ""}
	out = strings.Join(m.renderField(f, 60, false, false), "\n")
	if !strings.Contains(out, "not found") {
		t.Errorf("checked-missing ref should warn:\n%s", out)
	}

	// Resolved: title + dim id, no warning.
	m.refTitles["ghost"] = "Ghost Writer"
	out = strings.Join(m.renderField(f, 60, false, false), "\n")
	if !strings.Contains(out, "Ghost Writer") || strings.Contains(out, "not found") {
		t.Errorf("resolved ref render wrong:\n%s", out)
	}
}

func TestDirtyDotOnLabel(t *testing.T) {
	f := Field{Name: "note", Title: "Note", Type: FieldString}
	m := typedModel([]Field{f}, map[string]string{})

	out := strings.Join(m.renderField(f, 60, false, false), "\n")
	if strings.Contains(out, "●") {
		t.Errorf("clean field must not dot:\n%s", out)
	}
	m.dirtyValues = map[string]string{"note": "edited"}
	out = strings.Join(m.renderField(f, 60, false, false), "\n")
	if !strings.Contains(out, "NOTE ●") {
		t.Errorf("dirty field should dot the label:\n%s", out)
	}
}

func TestRelTimeHint(t *testing.T) {
	if got := relTimeHint(""); got != "" {
		t.Errorf("empty → %q", got)
	}
	if got := relTimeHint("garbage"); got != "" {
		t.Errorf("garbage → %q (the hint must never lie)", got)
	}
	past := time.Now().UTC().Add(-3 * time.Hour).Format(time.RFC3339)
	if got := relTimeHint(past); got != "3h ago" {
		t.Errorf("past → %q, want 3h ago", got)
	}
	future := time.Now().UTC().Add(49 * time.Hour).Format("2006-01-02T15:04")
	if got := relTimeHint(future); got != "in 2d" {
		t.Errorf("future → %q, want in 2d", got)
	}
}
