package main

import (
	"encoding/json"
	"testing"
)

// A reference stored Sanity-style ({"_ref": id, "_type": "reference"}) — the
// shape the API accepts, ?expand resolves, and both create-barkpark-app
// starters seed — reads as its id in the TUI editor, exactly as a bare-id
// reference does. Before, the picker showed "Select ..." over a document that
// had an author (stranger walk, 2026-09-30: article a2 on a local instance).
func TestGetFieldValueReadsRefObject(t *testing.T) {
	const wire = `{
	"_id": "a2", "_type": "article", "_draft": false, "_publishedId": "a2",
	"_rev": "r1", "_createdAt": "2026-09-30T11:06:49Z", "_updatedAt": "2026-09-30T11:07:11Z",
	"title": "Refs Ada",
	"author": {"_ref": "ada", "_type": "reference"},
	"editor": "grace",
	"seo": {"metaTitle": "x"}
}`
	var d Doc
	if err := json.Unmarshal([]byte(wire), &d); err != nil {
		t.Fatalf("decode: %v", err)
	}
	m := model{selectedDoc: &d}

	for field, want := range map[string]string{
		"author": "ada",   // {_ref} object → its id
		"editor": "grace", // bare-id reference, unchanged
		"seo":    "",      // an object with no _ref is NOT a reference
	} {
		if got := m.getFieldValue(field); got != want {
			t.Errorf("getFieldValue(%q) = %q, want %q", field, got, want)
		}
	}
}
