package main

import "testing"

// Desk safety net for the clean-profile world (premium-setup A4): a fresh
// `bp setup` install registers ONLY paper + mediaAsset + mediaCollection.
// Pins that initRootStructure renders that world without panicking: paper as
// a flat doc-type list (public, no status field), and the private media pair
// under Settings — the latter is EXISTING private-schema behaviour pinned as
// a known v1 wart, not fixed here.

func withSchemas(t *testing.T, set []Schema) {
	t.Helper()
	origSchemas, origRoot := schemas, rootStructure
	t.Cleanup(func() {
		schemas, rootStructure = origSchemas, origRoot
	})
	schemas = set
	initRootStructure()
}

func cleanProfileSchemas() []Schema {
	return []Schema{
		{
			Name: "paper", Title: "Papers", Icon: "📰", Visibility: "public",
			Fields: []Field{{Name: "title", Title: "Title", Type: FieldString}},
		},
		{Name: "mediaAsset", Title: "Media Asset", Icon: "🖼", Visibility: "private"},
		{Name: "mediaCollection", Title: "Media Collection", Icon: "📁", Visibility: "private"},
	}
}

func findItemByID(items []*StructureNode, id string) *StructureNode {
	for _, it := range items {
		if it.ID == id {
			return it
		}
	}
	return nil
}

func findItemByTitle(items []*StructureNode, title string) *StructureNode {
	for _, it := range items {
		if it.Title == title {
			return it
		}
	}
	return nil
}

func TestInitRootStructureCleanProfile(t *testing.T) {
	withSchemas(t, cleanProfileSchemas())

	if rootStructure == nil {
		t.Fatal("rootStructure is nil after initRootStructure")
	}

	// paper: public, no status field -> a flat doc-type list item.
	paper := findItemByID(rootStructure.Items, "paper")
	if paper == nil {
		t.Fatalf("paper item missing from root structure: %+v", rootStructure.Items)
	}
	if paper.Child == nil || paper.Child.Type != NodeDocumentTypeList {
		t.Errorf("paper must open a NodeDocumentTypeList child, got %+v", paper.Child)
	}

	// Pinned existing wart (v1, accepted): private schemas — including the
	// media pair — land under Settings as singleton Document nodes.
	settings := findItemByTitle(rootStructure.Items, "Settings")
	if settings == nil {
		t.Fatalf("Settings group missing: %+v", rootStructure.Items)
	}
	if settings.Child == nil {
		t.Fatal("Settings item has no child list")
	}
	for _, name := range []string{"Media Asset", "Media Collection"} {
		entry := findItemByTitle(settings.Child.Items, name)
		if entry == nil {
			t.Errorf("%s missing under Settings: %+v", name, settings.Child.Items)
			continue
		}
		if entry.Child == nil || entry.Child.Type != NodeDocument {
			t.Errorf("%s under Settings must open a NodeDocument singleton, got %+v", name, entry.Child)
		}
	}

	// No demo-world items.
	for _, id := range []string{"post", "page", "project", "author", "category"} {
		if findItemByID(rootStructure.Items, id) != nil {
			t.Errorf("unexpected %s item in a paper+media-only desk", id)
		}
	}
}

func TestInitRootStructureZeroSchemas(t *testing.T) {
	withSchemas(t, nil) // must not panic

	if rootStructure == nil {
		t.Fatal("rootStructure is nil after initRootStructure with zero schemas")
	}
	if len(rootStructure.Items) != 0 {
		t.Errorf("expected an empty root item list with zero schemas, got %+v", rootStructure.Items)
	}
}
