package main

import (
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
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
	NodeListItem                         // A single navigable entry inside a list
	NodeDocumentTypeList                 // A real-time list of documents filtered by type
	NodeDocument                         // A singleton document (opens editor directly)
	NodeDivider                          // Visual separator in a list
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

func (b *ListBuilder) ID(id string) *ListBuilder   { b.node.ID = id; return b }
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

func (b *ListItemBuilder) ID(id string) *ListItemBuilder   { b.node.ID = id; return b }
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

func (b *DocTypeListBuilder) ID(id string) *DocTypeListBuilder    { b.node.ID = id; return b }
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
// ║  DESK STRUCTURE                                                         ║
// ║                                                                         ║
// ║  This is the equivalent of Sanity's deskStructure export.               ║
// ║  Auto-generated from schemas, with:                                     ║
// ║   - Content types with status filter sub-views                          ║
// ║   - Taxonomy types as simple lists                                      ║
// ║   - Private types as singletons under Settings                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

var rootStructure *StructureNode

// buildDesk sets rootStructure from the SERVER's canonical desk when the
// endpoint exists (TUI desk == Studio desk, plugin groups included), falling
// back to the schema-derived client-side desk on old servers or fetch
// failure. Returns true when the server tree was used.
func buildDesk(ds *DataStore) bool {
	tree, err := ds.LoadStructure()
	if err != nil || tree == nil {
		initRootStructure()
		return false
	}
	converted := fromDeskNode(*tree)
	if converted == nil || len(converted.Items) == 0 {
		initRootStructure()
		return false
	}
	rootStructure = converted
	return true
}

// terminalIcon keeps an icon only when the terminal can draw it: emoji and
// other non-ASCII glyphs pass, Lucide icon NAMES ("book", "history") — which
// Studio resolves to SVGs — would render as stray words, so they drop.
func terminalIcon(icon string) string {
	for _, r := range icon {
		if r > 127 {
			return icon
		}
	}
	return ""
}

// fromDeskNode converts one server desk node into the TUI's pane tree.
// Browser-only node types (link/plugin_link) are skipped — a terminal has
// nowhere to send them; unknown future types degrade the same way instead
// of crashing the desk.
func fromDeskNode(n apiclientDeskNode) *StructureNode {
	var t NodeType
	switch n.Type {
	case "list", "nested":
		t = NodeList
	case "list_item":
		t = NodeListItem
	case "document_type_list", "document_list", "plugin_document_list":
		t = NodeDocumentTypeList
	case "document":
		t = NodeDocument
	case "divider":
		t = NodeDivider
	default:
		return nil
	}

	node := &StructureNode{
		Type:     t,
		ID:       n.ID,
		Title:    n.Title,
		Icon:     terminalIcon(n.Icon),
		TypeName: n.TypeName,
		Filter:   n.FilterString(),
	}
	if t == NodeDocument {
		// Singletons open the doc named after the type (the settings
		// convention the client-side desk used too).
		node.DocID = n.TypeName
	}
	for _, it := range n.Items {
		if c := fromDeskNode(it); c != nil {
			node.Items = append(node.Items, c)
		}
	}
	if n.Child != nil {
		node.Child = fromDeskNode(*n.Child)
	}
	// A list/list_item that lost ALL its content to skipped link nodes is
	// itself dropped — no dead rows.
	if (t == NodeList || t == NodeListItem) && len(node.Items) == 0 && node.Child == nil && node.TypeName == "" {
		return nil
	}
	return node
}

// initRootStructure builds the desk structure from the loaded schemas.
func initRootStructure() {
	var contentItems []*StructureNode
	var taxonomyItems []*StructureNode
	var settingsItems []*StructureNode

	// Categorize schemas by their role in the desk structure
	for _, s := range schemas {
		if s.Visibility == "private" {
			settingsItems = append(settingsItems,
				ListItem().Title(s.Title).Icon(s.Icon).Child(
					Document().SchemaType(s.Name).DocumentID(s.Name).Build(),
				).Build(),
			)
			continue
		}

		// Types with a status field get filtered sub-views (like Sanity)
		if hasStatusField(s) {
			contentItems = append(contentItems, docTypeWithFilters(s))
		} else {
			taxonomyItems = append(taxonomyItems, DocumentTypeListItem(s.Name))
		}
	}

	var items []*StructureNode
	items = append(items, contentItems...)

	if len(taxonomyItems) > 0 {
		items = append(items, Divider())
		items = append(items, taxonomyItems...)
	}

	if len(settingsItems) > 0 {
		items = append(items, Divider())
		items = append(items,
			ListItem().Title("Settings").Icon("⚙").Child(
				List().ID("settings").Title("Settings").Items(settingsItems...).Build(),
			).Build(),
		)
	}

	rootStructure = List().ID("root").Title("Structure").Items(items...).Build()
}

// docTypeWithFilters creates a list item that opens a sub-list with
// "All {Type}" plus filtered views for each status option.
// This mirrors Sanity's pattern of having filtered document lists.
func docTypeWithFilters(s Schema) *StructureNode {
	field := findStatusField(s)
	if field == nil {
		return DocumentTypeListItem(s.Name)
	}

	var subItems []*StructureNode

	// "All {Type}" — unfiltered
	subItems = append(subItems, &StructureNode{
		Type:     NodeDocumentTypeList,
		ID:       s.Name + "-all",
		Title:    "All " + s.Title,
		Icon:     s.Icon,
		TypeName: s.Name,
	})

	subItems = append(subItems, Divider())

	// One filtered view per status option
	for _, opt := range field.Options {
		subItems = append(subItems, &StructureNode{
			Type:     NodeDocumentTypeList,
			ID:       s.Name + "-" + opt,
			Title:    capitalize(opt),
			Icon:     statusIcon(opt),
			TypeName: s.Name,
			Filter:   "status=" + opt,
		})
	}

	return ListItem().
		ID(s.Name).
		Title(s.Title).
		Icon(s.Icon).
		Child(
			List().ID(s.Name).Title(s.Title).Items(subItems...).Build(),
		).
		Build()
}

func hasStatusField(s Schema) bool {
	return findStatusField(s) != nil
}

func findStatusField(s Schema) *Field {
	for i, f := range s.Fields {
		if f.Name == "status" && f.Type == FieldSelect && len(f.Options) > 0 {
			return &s.Fields[i]
		}
	}
	return nil
}

func capitalize(s string) string {
	if s == "" {
		return s
	}
	r, size := utf8.DecodeRuneInString(s)
	if r == utf8.RuneError && size <= 1 {
		return s
	}
	return string(unicode.ToUpper(r)) + s[size:]
}
