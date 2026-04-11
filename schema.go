package main

// FieldType enumerates the supported form field types.
// The editor pane auto-renders each type with the appropriate widget.
type FieldType int

const (
	FieldString    FieldType = iota // Single-line text input
	FieldSlug                      // Auto-generated slug with [Generate] button
	FieldText                      // Multi-line textarea
	FieldRichText                  // Block editor with formatting toolbar
	FieldImage                     // Image upload drop zone
	FieldSelect                    // Dropdown / inline option selector
	FieldBoolean                   // Toggle switch
	FieldDatetime                  // Date + time picker
	FieldColor                     // Color swatch + hex input
	FieldReference                 // Link to another document type
	FieldArray                     // Repeatable list of items
)

// Field defines a single form field inside a document schema.
type Field struct {
	Name    string    // Machine name (e.g. "title", "slug")
	Title   string    // Human label shown in the editor
	Type    FieldType // Determines which widget renders
	Options []string  // Valid values for FieldSelect
	RefType string    // Target document type for FieldReference
	Rows    int       // Visible rows for FieldText (default 3)
}

// Schema defines a document type — its name, icon, and ordered list of fields.
// Add new schemas to the `schemas` slice below and they'll appear in the
// structure builder's DocumentTypeListItem() helper automatically.
type Schema struct {
	Name   string  // Machine name, must be unique (e.g. "post")
	Title  string  // Human label (e.g. "Post")
	Icon   string  // Emoji shown in pane headers and lists
	Fields []Field // Ordered fields rendered in the editor
}

// ─── Schema definitions ─────────────────────────────────────────────────────
// Edit these to change what document types exist and what fields they have.
// The editor form, structure builder helpers, and doc store all read from here.

var schemas = []Schema{
	{
		Name: "post", Title: "Post", Icon: "📄",
		Fields: []Field{
			{Name: "title", Title: "Title", Type: FieldString},
			{Name: "slug", Title: "Slug", Type: FieldSlug},
			{Name: "status", Title: "Status", Type: FieldSelect, Options: []string{"draft", "published", "archived"}},
			{Name: "publishedAt", Title: "Published At", Type: FieldDatetime},
			{Name: "excerpt", Title: "Excerpt", Type: FieldText, Rows: 3},
			{Name: "body", Title: "Body", Type: FieldRichText},
			{Name: "featuredImage", Title: "Featured Image", Type: FieldImage},
			{Name: "author", Title: "Author", Type: FieldReference, RefType: "author"},
			{Name: "featured", Title: "Featured Post", Type: FieldBoolean},
		},
	},
	{
		Name: "page", Title: "Page", Icon: "📑",
		Fields: []Field{
			{Name: "title", Title: "Title", Type: FieldString},
			{Name: "slug", Title: "Slug", Type: FieldSlug},
			{Name: "body", Title: "Page Content", Type: FieldRichText},
			{Name: "seoTitle", Title: "SEO Title", Type: FieldString},
			{Name: "seoDescription", Title: "SEO Description", Type: FieldText, Rows: 2},
			{Name: "heroImage", Title: "Hero Image", Type: FieldImage},
		},
	},
	{
		Name: "author", Title: "Author", Icon: "👤",
		Fields: []Field{
			{Name: "name", Title: "Name", Type: FieldString},
			{Name: "slug", Title: "Slug", Type: FieldSlug},
			{Name: "bio", Title: "Bio", Type: FieldText, Rows: 4},
			{Name: "avatar", Title: "Avatar", Type: FieldImage},
			{Name: "email", Title: "Email", Type: FieldString},
			{Name: "role", Title: "Role", Type: FieldSelect, Options: []string{"editor", "writer", "contributor", "admin"}},
		},
	},
	{
		Name: "category", Title: "Category", Icon: "🏷",
		Fields: []Field{
			{Name: "title", Title: "Title", Type: FieldString},
			{Name: "slug", Title: "Slug", Type: FieldSlug},
			{Name: "description", Title: "Description", Type: FieldText, Rows: 2},
			{Name: "color", Title: "Color", Type: FieldColor},
		},
	},
	{
		Name: "project", Title: "Project", Icon: "💼",
		Fields: []Field{
			{Name: "title", Title: "Title", Type: FieldString},
			{Name: "slug", Title: "Slug", Type: FieldSlug},
			{Name: "client", Title: "Client", Type: FieldString},
			{Name: "status", Title: "Status", Type: FieldSelect, Options: []string{"planning", "active", "completed", "archived"}},
			{Name: "description", Title: "Description", Type: FieldRichText},
			{Name: "coverImage", Title: "Cover Image", Type: FieldImage},
			{Name: "startDate", Title: "Start Date", Type: FieldDatetime},
			{Name: "featured", Title: "Featured", Type: FieldBoolean},
		},
	},
	{
		Name: "siteSettings", Title: "Site Settings", Icon: "⚙",
		Fields: []Field{
			{Name: "title", Title: "Site Title", Type: FieldString},
			{Name: "description", Title: "Site Description", Type: FieldText, Rows: 2},
			{Name: "logo", Title: "Logo", Type: FieldImage},
			{Name: "analyticsId", Title: "Analytics ID", Type: FieldString},
		},
	},
	{
		Name: "navigation", Title: "Navigation", Icon: "🧭",
		Fields: []Field{
			{Name: "title", Title: "Menu Title", Type: FieldString},
		},
	},
	{
		Name: "colors", Title: "Brand Colors", Icon: "🎨",
		Fields: []Field{
			{Name: "primary", Title: "Primary", Type: FieldColor},
			{Name: "secondary", Title: "Secondary", Type: FieldColor},
			{Name: "accent", Title: "Accent", Type: FieldColor},
		},
	},
}

// findSchema looks up a schema by its machine name.
func findSchema(name string) *Schema {
	for i := range schemas {
		if schemas[i].Name == name {
			return &schemas[i]
		}
	}
	return nil
}
