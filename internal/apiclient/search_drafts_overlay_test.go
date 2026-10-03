package apiclient

import (
	"net/url"
	"testing"
)

// task-14bded0bdeacb661: the TUI client runs with Perspective "drafts", and
// Search forwarded it. On /v1/data/search `drafts` means DRAFT ROWS ONLY, while
// on the query/doc endpoints the TUI lists use it means "the drafts. twin, else
// the published row". So the TUI search never found published content
// (measured: q=RSC → 0 under drafts, 3 under raw/published). A drafts client
// now asks search for raw and overlays the twins itself, in rank order.
func TestSearchOnADraftsClientOverlaysTwinsFromRaw(t *testing.T) {
	var seen url.URL
	// Rank order as the server returns it under raw: a published-only hit, a
	// published row whose draft twin ranks lower, that twin, and a draft-only row.
	srv := captureGet(t, `{"documents":[
		{"_id":"pub-only","title":"Published only"},
		{"_id":"edited","title":"Edited (published)"},
		{"_id":"drafts.edited","title":"Edited (draft)"},
		{"_id":"drafts.new-draft","title":"Never published"}
	]}`, &seen)
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production", Perspective: "drafts"})

	docs, err := c.Search("x", 20)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if got := seen.Query().Get("perspective"); got != "raw" {
		t.Errorf("perspective = %q; a drafts client must ask search for raw (search's drafts is drafts-only)", got)
	}
	var ids []string
	for _, d := range docs {
		ids = append(ids, d.ID)
	}
	want := []string{"pub-only", "drafts.edited", "drafts.new-draft"}
	if len(ids) != len(want) {
		t.Fatalf("ids = %v, want %v (published hits kept, a draft replaces its published twin in place)", ids, want)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("ids = %v, want %v", ids, want)
		}
	}
}

func TestSearchOnAPublishedClientIsUnchanged(t *testing.T) {
	var seen url.URL
	srv := captureGet(t, `{"documents":[{"_id":"a"},{"_id":"b"}]}`, &seen)
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t", Workspace: "ws", Project: "proj", Dataset: "production", Perspective: "published"})
	docs, err := c.Search("x", 5)
	if err != nil || len(docs) != 2 || seen.Query().Get("perspective") != "published" {
		t.Fatalf("docs=%d err=%v perspective=%q; a published client must pass through untouched", len(docs), err, seen.Query().Get("perspective"))
	}
}
