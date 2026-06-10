package apiclient

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The SDK schema envelope carries the schema's list_preview declaration as
// `listPreview`, where each spec is either a bare field-name string or
// {"field": f, "prefix": p}. LoadSchemas must shape both; schemas without a
// declaration (or with junk specs) must come back with the zero ListPreview.
func TestLoadSchemasParsesListPreview(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"schemas": []map[string]any{
				{
					"name": "task", "title": "Task",
					"listPreview": map[string]any{
						"badge": "lifecycle_status",
						"meta":  map[string]any{"field": "priority", "prefix": "P"},
					},
				},
				{"name": "post", "title": "Post"},
				{
					"name": "junk", "title": "Junk",
					// misdeclared specs degrade to nil, never an error
					"listPreview": map[string]any{"badge": 42, "meta": map[string]any{"prefix": "X"}},
				},
			},
		})
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	got, err := c.LoadSchemas()
	if err != nil {
		t.Fatalf("LoadSchemas: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d schemas, want 3", len(got))
	}

	task := got[0].ListPreview
	if task.Badge == nil || task.Badge.Field != "lifecycle_status" || task.Badge.Prefix != "" {
		t.Errorf("task badge spec wrong: %+v", task.Badge)
	}
	if task.Meta == nil || task.Meta.Field != "priority" || task.Meta.Prefix != "P" {
		t.Errorf("task meta spec wrong: %+v", task.Meta)
	}

	if post := got[1].ListPreview; post.Badge != nil || post.Meta != nil {
		t.Errorf("undeclared schema must have zero ListPreview, got %+v", post)
	}
	if junk := got[2].ListPreview; junk.Badge != nil || junk.Meta != nil {
		t.Errorf("misdeclared specs must degrade to nil, got %+v", junk)
	}
}

// The v1 envelope flattens content fields to the document top level. Doc's
// UnmarshalJSON captures them raw; ContentString renders scalars (string,
// number) and degrades everything else to "" — Studio format_preview parity.
func TestDocContentString(t *testing.T) {
	raw := `{
		"_id": "drafts.t1", "_type": "task", "title": "Wire the bridge",
		"lifecycle_status": "in_progress", "priority": 1, "weight": 1.5,
		"done": true, "claim": {"by": "x"}, "deps": ["a"], "empty": "", "nothing": null
	}`
	var d Doc
	if err := json.Unmarshal([]byte(raw), &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// Typed decode is untouched by the Extra capture.
	if d.Title != "Wire the bridge" {
		t.Errorf("Title = %q", d.Title)
	}

	cases := map[string]string{
		"lifecycle_status": "in_progress",
		"priority":         "1",
		"weight":           "1.5",
		"done":             "", // bool: skipped
		"claim":            "", // object: skipped
		"deps":             "", // array: skipped
		"empty":            "",
		"nothing":          "",
		"missing":          "",
	}
	for field, want := range cases {
		if got := d.ContentString(field); got != want {
			t.Errorf("ContentString(%q) = %q, want %q", field, got, want)
		}
	}

	// A hand-built Doc (nil Extra) must not panic.
	if got := (Doc{}).ContentString("anything"); got != "" {
		t.Errorf("zero Doc ContentString = %q, want \"\"", got)
	}
}
