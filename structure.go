package main

import (
	"fmt"
	"strings"
	"time"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  STRUCTURE BUILDER                                                      ║
// ║                                                                         ║
// ║  Chainable API that mirrors Sanity's StructureBuilder:                  ║
// ║    S.list()              →  List()                                      ║
// ║    S.listItem()          →  ListItem()                                  ║
// ║    S.documentTypeList()  →  DocumentTypeList()                          ║
// ║    S.documentTypeListItem() → DocumentTypeListItem()                    ║
// ║    S.document()          →  Document()                                  ║
// ║    S.divider()           →  Divider()                                   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// NodeType identifies what kind of pane a StructureNode resolves to.
type NodeType int

const (
	NodeList             NodeType = iota // A static list of items (renders as a list pane)
	NodeListItem                        // A single navigable entry inside a list
	NodeDocumentTypeList                // A real-time list of documents filtered by type
	NodeDocument                        // A singleton document (opens editor directly)
	NodeDivider                         // Visual separator in a list
)

// StructureNode is the universal tree node the TUI resolves into panes.
type StructureNode struct {
	Type     NodeType
	ID       string
	Title    string
	Icon     string
	TypeName string           // schema type name (for doc lists / singletons)
	Filter   string           // simple "field=value" filter
	DocID    string           // document ID for singletons
	Items    []*StructureNode // children (for lists)
	Child    *StructureNode   // what opens when this item is selected
}

// ── List builder ─────────────────────────────────────────────────────────────

type ListBuilder struct{ node *StructureNode }

func List() *ListBuilder {
	return &ListBuilder{node: &StructureNode{Type: NodeList, ID: "root", Title: "Content"}}
}

func (b *ListBuilder) ID(id string) *ListBuilder  { b.node.ID = id; return b }
func (b *ListBuilder) Title(t string) *ListBuilder { b.node.Title = t; return b }

func (b *ListBuilder) Items(items ...*StructureNode) *ListBuilder {
	b.node.Items = items
	return b
}

func (b *ListBuilder) Build() *StructureNode { return b.node }

// ── ListItem builder ─────────────────────────────────────────────────────────

type ListItemBuilder struct{ node *StructureNode }

func ListItem() *ListItemBuilder {
	return &ListItemBuilder{node: &StructureNode{Type: NodeListItem, Icon: "📄"}}
}

func (b *ListItemBuilder) ID(id string) *ListItemBuilder  { b.node.ID = id; return b }
func (b *ListItemBuilder) Title(t string) *ListItemBuilder { b.node.Title = t; return b }
func (b *ListItemBuilder) Icon(i string) *ListItemBuilder  { b.node.Icon = i; return b }

func (b *ListItemBuilder) Child(c *StructureNode) *ListItemBuilder {
	b.node.Child = c
	return b
}

func (b *ListItemBuilder) Build() *StructureNode {
	if b.node.ID == "" {
		b.node.ID = strings.ToLower(strings.ReplaceAll(b.node.Title, " ", "-"))
	}
	return b.node
}

// ── DocumentTypeList builder ─────────────────────────────────────────────────

type DocTypeListBuilder struct{ node *StructureNode }

func DocumentTypeList(typeName string) *DocTypeListBuilder {
	s := findSchema(typeName)
	title, icon := typeName, "📄"
	if s != nil {
		title = s.Title
		icon = s.Icon
	}
	return &DocTypeListBuilder{node: &StructureNode{
		Type: NodeDocumentTypeList, ID: typeName, Title: title, Icon: icon, TypeName: typeName,
	}}
}

func (b *DocTypeListBuilder) ID(id string) *DocTypeListBuilder   { b.node.ID = id; return b }
func (b *DocTypeListBuilder) Title(t string) *DocTypeListBuilder  { b.node.Title = t; return b }
func (b *DocTypeListBuilder) Filter(f string) *DocTypeListBuilder { b.node.Filter = f; return b }
func (b *DocTypeListBuilder) Build() *StructureNode               { return b.node }

// ── Convenience: DocumentTypeListItem ────────────────────────────────────────
// Creates a ListItem that opens a DocumentTypeList for the given schema type.

func DocumentTypeListItem(typeName string) *StructureNode {
	s := findSchema(typeName)
	if s == nil {
		return ListItem().ID(typeName).Title(typeName).Build()
	}
	return ListItem().
		ID(typeName).
		Title(s.Title).
		Icon(s.Icon).
		Child(DocumentTypeList(typeName).Build()).
		Build()
}

// ── Document builder (singletons) ────────────────────────────────────────────

type DocumentBuilder struct{ node *StructureNode }

func Document() *DocumentBuilder {
	return &DocumentBuilder{node: &StructureNode{Type: NodeDocument}}
}

func (b *DocumentBuilder) SchemaType(t string) *DocumentBuilder  { b.node.TypeName = t; return b }
func (b *DocumentBuilder) DocumentID(id string) *DocumentBuilder { b.node.DocID = id; return b }

func (b *DocumentBuilder) Build() *StructureNode {
	if s := findSchema(b.node.TypeName); s != nil {
		b.node.Title = s.Title
		b.node.Icon = s.Icon
		b.node.ID = b.node.DocID
	}
	return b.node
}

// ── Divider ──────────────────────────────────────────────────────────────────

func Divider() *StructureNode {
	return &StructureNode{
		Type: NodeDivider,
		ID:   fmt.Sprintf("div-%d", time.Now().UnixNano()),
	}
}

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  STRUCTURE CONFIGURATION                                                ║
// ║                                                                         ║
// ║  Edit this to change the entire studio layout.                          ║
// ║  This is the equivalent of sanity's structure.ts / deskStructure.ts.    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

var rootStructure *StructureNode

func initRootStructure() {
	rootStructure = List().ID("root").Title("Structure").Items(

	// ── Editorial group ─────────────────────────────────────────────────
	ListItem().Title("Editorial").Icon("📚").Child(
		List().ID("editorial").Title("Editorial").Items(

			// All posts
			DocumentTypeListItem("post"),

			// Posts filtered by status
			ListItem().Title("Posts by Status").Icon("🔽").Child(
				List().ID("by-status").Title("By Status").Items(
					ListItem().Title("Published").Icon("✅").Child(
						DocumentTypeList("post").
							ID("posts-pub").
							Title("Published Posts").
							Filter("status=published").
							Build(),
					).Build(),
					ListItem().Title("Drafts").Icon("📝").Child(
						DocumentTypeList("post").
							ID("posts-draft").
							Title("Draft Posts").
							Filter("status=draft").
							Build(),
					).Build(),
				).Build(),
			).Build(),

			// Posts filtered by category
			ListItem().Title("Posts by Category").Icon("🏷").Child(
				List().ID("by-cat").Title("By Category").Items(
					ListItem().Title("Technology").Icon("#").Child(
						DocumentTypeList("post").ID("posts-tech").Title("Technology").Filter("category=Technology").Build(),
					).Build(),
					ListItem().Title("Design").Icon("#").Child(
						DocumentTypeList("post").ID("posts-design").Title("Design").Filter("category=Design").Build(),
					).Build(),
					ListItem().Title("Engineering").Icon("#").Child(
						DocumentTypeList("post").ID("posts-eng").Title("Engineering").Filter("category=Engineering").Build(),
					).Build(),
				).Build(),
			).Build(),

			Divider(),

			// All pages
			DocumentTypeListItem("page"),
		).Build(),
	).Build(),

	// ── Projects ────────────────────────────────────────────────────────
	DocumentTypeListItem("project"),

	// ── Taxonomy group ──────────────────────────────────────────────────
	ListItem().Title("Taxonomy").Icon("🏷").Child(
		List().ID("taxonomy").Title("Taxonomy").Items(
			DocumentTypeListItem("category"),
			DocumentTypeListItem("author"),
		).Build(),
	).Build(),

	Divider(),

	// ── Settings (singletons) ───────────────────────────────────────────
	ListItem().Title("Settings").Icon("⚙").Child(
		List().ID("settings").Title("Settings").Items(
			ListItem().Title("Site Settings").Icon("⚙").Child(
				Document().SchemaType("siteSettings").DocumentID("siteSettings").Build(),
			).Build(),
			ListItem().Title("Navigation").Icon("🧭").Child(
				Document().SchemaType("navigation").DocumentID("navigation").Build(),
			).Build(),
			ListItem().Title("Brand Colors").Icon("🎨").Child(
				Document().SchemaType("colors").DocumentID("colors").Build(),
			).Build(),
		).Build(),
	).Build(),
).Build()
}
