package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Server-desk consumption pins (2026-06-12): the TUI renders the SAME tree
// Studio does (GET /v1/structure/:dataset — plugin groups included). Browser-
// only nodes (links) are skipped without leaving dead rows; unknown future
// types degrade the same way; old servers fall back to the schema-built desk.

const deskJSON = `{"structure":{
  "id":"root","title":"Structure","type":"list","items":[
    {"id":"post-group","title":"Post","icon":"📄","type":"list_item","child":{
      "id":"post-sub","title":"Post","type":"list","items":[
        {"id":"post-all","title":"All Post","type":"document_type_list","typeName":"post","filter":"kind=task"},
        {"type":"divider"},
        {"id":"post-draft","title":"Drafts","type":"document_type_list","typeName":"post","filter":{"status":"draft"}}
      ]}},
    {"id":"sheets","title":"Sheets","icon":"🧮","type":"document_type_list","typeName":"sheet"},
    {"id":"frt","title":"① Frame & Time","type":"nested","items":[
      {"id":"clock","title":"Game Clock","type":"document","typeName":"gameClock"}
    ]},
    {"id":"docs-link","title":"Docs","type":"plugin_link"},
    {"id":"dead-list","title":"Only Links","type":"list_item","child":null,"items":[
      {"id":"l1","title":"L1","type":"link"}
    ]},
    {"type":"divider"},
    {"id":"settings","title":"Settings","icon":"⚙","type":"list_item","child":{
      "id":"settings-sub","title":"Settings","type":"list","items":[
        {"id":"site","title":"Site Settings","type":"document","typeName":"siteSettings"}
      ]}}
  ]}}`

func TestFromDeskNodeConversion(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(deskJSON))
	}))
	defer srv.Close()

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	tree, err := c.LoadStructure()
	if err != nil {
		t.Fatalf("LoadStructure: %v", err)
	}
	root := fromDeskNode(*tree)
	if root == nil || root.Type != NodeList {
		t.Fatalf("root conversion wrong: %+v", root)
	}

	titles := func(nodes []*StructureNode) []string {
		var out []string
		for _, n := range nodes {
			out = append(out, n.Title)
		}
		return out
	}

	got := titles(root.Items)
	want := []string{"Post", "Sheets", "① Frame & Time", "", "Settings"}
	if len(got) != len(want) {
		t.Fatalf("root items = %v, want shape of %v (links + dead lists skipped)", got, want)
	}

	// Sheets is a plain doc-type list with its type name carried.
	sheets := root.Items[1]
	if sheets.Type != NodeDocumentTypeList || sheets.TypeName != "sheet" {
		t.Errorf("sheets node wrong: %+v", sheets)
	}

	// The nested frt group became a list with a singleton inside, DocID set.
	frt := root.Items[2]
	if frt.Type != NodeList || len(frt.Items) != 1 {
		t.Fatalf("frt group wrong: %+v", frt)
	}
	if frt.Items[0].Type != NodeDocument || frt.Items[0].DocID != "gameClock" {
		t.Errorf("singleton conversion wrong: %+v", frt.Items[0])
	}

	// The filtered sub-view kept its filter.
	post := root.Items[0]
	if post.Child == nil || len(post.Child.Items) != 3 {
		t.Fatalf("post sub-list wrong: %+v", post.Child)
	}
	if post.Child.Items[0].Filter != "kind=task" {
		t.Errorf("string filter should pass through: %+v", post.Child.Items[0])
	}
	if post.Child.Items[2].Filter != "status=draft" {
		t.Errorf("map filter should normalize to field=value: %+v", post.Child.Items[2])
	}

	// Both link nodes AND the list_item that contained only links are gone.
	for _, n := range root.Items {
		if n.Title == "Docs" || n.Title == "Only Links" {
			t.Errorf("browser-only node leaked into the desk: %+v", n)
		}
	}
}

// Tiered desk (studio-structure-polish): the server tiers the tree with a
// nested "plugins" :list node and a trailing "rest" :list node, using ONLY
// existing node types so THIS (old-shape) fromDeskNode switch renders every
// tier — a new node `type` would hit the default→nil arm and drop the whole
// subtree. This pins that Plugins/…Rest arrive as drillable list groups and no
// subtree is lost.
const tieredDeskJSON = `{"structure":{
  "id":"root","title":"Structure","type":"list","items":[
    {"id":"post","title":"Post","icon":"📄","type":"document_type_list","typeName":"post"},
    {"id":"paper","title":"Papers","type":"document_type_list","typeName":"paper"},
    {"type":"divider"},
    {"id":"plugins","title":"Plugins","icon":"🧩","type":"list","items":[
      {"id":"plugin-grp-onixedit","title":"Onix","type":"list","items":[
        {"id":"book","title":"Books","type":"document_type_list","typeName":"book"}
      ]}
    ]},
    {"type":"divider"},
    {"id":"rest","title":"…Rest","icon":"🗂","type":"list","items":[
      {"id":"rest-ticket","title":"ticket (4)","type":"document_type_list","typeName":"ticket"},
      {"id":"rest-ghostType","title":"ghostType (5)","type":"document","typeName":"ghostType"}
    ]}
  ]}}`

func TestTieredDeskSurvivesOldBinaries(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(tieredDeskJSON))
	}))
	defer srv.Close()

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	tree, err := c.LoadStructure()
	if err != nil {
		t.Fatalf("LoadStructure: %v", err)
	}
	root := fromDeskNode(*tree)
	if root == nil || root.Type != NodeList {
		t.Fatalf("root conversion wrong: %+v", root)
	}

	find := func(nodes []*StructureNode, id string) *StructureNode {
		for _, n := range nodes {
			if n.ID == id {
				return n
			}
		}
		return nil
	}

	// The Plugins tier survives as a drillable list group holding a per-plugin
	// sub-group that itself holds a drillable doc-type list — no subtree lost.
	plugins := find(root.Items, "plugins")
	if plugins == nil || plugins.Type != NodeList {
		t.Fatalf("Plugins node missing or not a list: %+v", plugins)
	}
	onix := find(plugins.Items, "plugin-grp-onixedit")
	if onix == nil || onix.Type != NodeList || len(onix.Items) != 1 {
		t.Fatalf("per-plugin group missing/empty: %+v", onix)
	}
	if onix.Items[0].Type != NodeDocumentTypeList || onix.Items[0].TypeName != "book" {
		t.Errorf("book list under Plugins wrong: %+v", onix.Items[0])
	}

	// The …Rest tier survives with BOTH kinds of child: a drillable
	// document_type_list (schema in scope) and a plain document leaf (orphaned
	// type). Neither is dropped — the truth invariant holds on old binaries too.
	rest := find(root.Items, "rest")
	if rest == nil || rest.Type != NodeList || len(rest.Items) != 2 {
		t.Fatalf("…Rest node missing/wrong arity: %+v", rest)
	}
	ticket := find(rest.Items, "rest-ticket")
	if ticket == nil || ticket.Type != NodeDocumentTypeList || ticket.TypeName != "ticket" {
		t.Errorf("drillable …Rest child wrong: %+v", ticket)
	}
	ghost := find(rest.Items, "rest-ghostType")
	if ghost == nil || ghost.Type != NodeDocument || ghost.DocID != "ghostType" {
		t.Errorf("orphaned …Rest child must survive as a document leaf: %+v", ghost)
	}
}

func TestBuildDeskFallsBackOnOldServers(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	prevSchemas, prevRoot := schemas, rootStructure
	t.Cleanup(func() { schemas, rootStructure = prevSchemas, prevRoot })
	schemas = []Schema{{Name: "post", Title: "Posts", Icon: "📄"}}

	ds := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})
	if buildDesk(ds) {
		t.Fatal("404 endpoint must report fallback")
	}
	if rootStructure == nil || len(rootStructure.Items) == 0 {
		t.Fatal("fallback desk should have been built from schemas")
	}
}
