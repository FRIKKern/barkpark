# sanity-tui

A terminal recreation of the [Sanity Studio](https://www.sanity.io/studio) Structure experience — multi-pane, schema-driven, expanding-right navigation in your terminal.

Built with [Bubble Tea](https://github.com/charmbracelet/bubbletea) + [Lip Gloss](https://github.com/charmbracelet/lipgloss).

```
▣ Studio  [Structure] Vision  Structure › Editorial › By Category › Technology › Getting Started…   ⌘K Search
╭──────────────────────────┤╭──────────────────────────┤╭──────────────────────────┤╭──────────────────────────┤╭─────────────────────────────
│ 📚 Structure             ││ 📚 Editorial             ││ 🏷 By Category           ││ Technology            3  ││ ● Getting Started… [published]
│──────────────────────────││──────────────────────────││──────────────────────────││──────────────────────────││──────────────────────────────
│ 📚 Editorial           › ││ 📄 Post                › ││ # Technology           › ││ ● Getting Started…      ││ ⚙ Post · 9 fields
│ 💼 Project              › ││ 🔽 Posts by Status     › ││ # Design               › ││   2h ago                ││
│ 🏷 Taxonomy             › ││ 🏷 Posts by Category   › ││ # Engineering          › ││ ● Why Headless CMS…     ││  TITLE
│ ──────────────────────── ││ ──────────────────────── ││                          ││   26h ago               ││ ╭──────────────────────────╮
│ ⚙ Settings              › ││ 📑 Page                › ││                          ││ ○ GROQ vs GraphQL…      ││ │Getting Started with…    │
│                          ││                          ││                          ││   122h ago              ││ ╰──────────────────────────╯
```

## Quick Start

```bash
git clone https://github.com/YOUR_USER/sanity-tui.git
cd sanity-tui
go mod tidy
go run .
```

Or build a binary:

```bash
make build
./sanity-tui
```

## Controls

| Key                    | Action                     |
|------------------------|----------------------------|
| `↑` / `k`             | Move up in current pane    |
| `↓` / `j`             | Move down / scroll editor  |
| `→` / `l` / `Tab`     | Switch to next pane        |
| `←` / `h` / `Shift+Tab` | Switch to previous pane  |
| `Enter`               | Drill into / select        |
| `Esc` / `Backspace`   | Go back one level          |
| `q` / `Ctrl+C`        | Quit                       |

## Project Structure

```
sanity-tui/
├── main.go          # Entry point
├── schema.go        # Document type & field definitions
├── structure.go     # Structure builder API + configuration
├── store.go         # Document store / seed data
├── tui.go           # Bubble Tea model, update, view
├── styles.go        # Lip Gloss style definitions
├── go.mod
├── Makefile
└── README.md
```

## Architecture

The code mirrors Sanity Studio's real three-layer architecture:

### 1. Schemas → `schema.go`

Define document types with typed fields. The editor auto-renders the right widget for each field type.

```go
var schemas = []Schema{
    {
        Name: "post", Title: "Post", Icon: "📄",
        Fields: []Field{
            {Name: "title", Title: "Title", Type: FieldString},
            {Name: "slug",  Title: "Slug",  Type: FieldSlug},
            {Name: "body",  Title: "Body",  Type: FieldRichText},
            {Name: "author", Title: "Author", Type: FieldReference, RefType: "author"},
            // ...
        },
    },
}
```

**Supported field types:** `FieldString`, `FieldSlug`, `FieldText`, `FieldRichText`, `FieldImage`, `FieldSelect`, `FieldBoolean`, `FieldDatetime`, `FieldColor`, `FieldReference`, `FieldArray`

### 2. Structure → `structure.go`

Chainable builder API — identical pattern to Sanity's `S.list()` / `S.listItem()`:

```go
var rootStructure = List().ID("root").Title("Structure").Items(

    ListItem().Title("Editorial").Icon("📚").Child(
        List().ID("editorial").Title("Editorial").Items(
            DocumentTypeListItem("post"),
            DocumentTypeListItem("page"),
        ).Build(),
    ).Build(),

    Divider(),

    ListItem().Title("Settings").Icon("⚙").Child(
        List().ID("settings").Title("Settings").Items(
            ListItem().Title("Site Settings").Icon("⚙").Child(
                Document().SchemaType("siteSettings").DocumentID("siteSettings").Build(),
            ).Build(),
        ).Build(),
    ).Build(),

).Build()
```

**Builder methods:**

| Sanity JS              | Go equivalent                |
|-------------------------|------------------------------|
| `S.list()`             | `List()`                     |
| `S.listItem()`         | `ListItem()`                 |
| `S.documentTypeList()` | `DocumentTypeList()`         |
| `S.documentTypeListItem()` | `DocumentTypeListItem()` |
| `S.document()`         | `Document()`                 |
| `S.divider()`          | `Divider()`                  |

### 3. Store → `store.go`

In-memory seed data with a simple query function. Replace with your own data source.

```go
queryDocs("post", "status=published")  // filter by status
queryDocs("post", "category=Design")   // filter by field
queryDocs("post", "")                  // all docs of type
```

## Try the deep navigation

Drill into this path to see 5 panes + editor:

**Structure → Editorial → Posts by Category → Technology → [pick a post]**

## Customizing

### Add a new document type

1. Add a `Schema{}` to `schemas` in `schema.go`
2. Add seed data to `store` in `store.go`
3. Add `DocumentTypeListItem("yourType")` to the structure in `structure.go`

### Add a nested group

```go
ListItem().Title("My Group").Icon("📁").Child(
    List().ID("my-group").Title("My Group").Items(
        DocumentTypeListItem("post"),
        DocumentTypeListItem("page"),
    ).Build(),
).Build()
```

### Add a filtered list

```go
ListItem().Title("Published Only").Icon("✅").Child(
    DocumentTypeList("post").
        ID("published-posts").
        Title("Published Posts").
        Filter("status=published").
        Build(),
).Build()
```

### Add a singleton

```go
ListItem().Title("Site Config").Icon("⚙").Child(
    Document().SchemaType("siteSettings").DocumentID("siteSettings").Build(),
).Build()
```

## Requirements

- Go 1.22+
- A terminal with unicode support

## License

MIT
