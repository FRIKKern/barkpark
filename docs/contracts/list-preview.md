<!-- doc-tier: agent | canonical-for: schema-list-preview | budget: 700tok -->
# List preview

`list_preview` sets what a desk row and a reference picker hit show (`Content.PreviewText`). `title` names the field that fills a titleless type's title column. A `title` that is a text spec instead (a list of parts, a template or `parts`) sets the row title, and the stored title shows only when the spec shows nothing: `["displayTitle", "title", {"text": "No title"}]` or `["{title} ({code})", "title"]`. `subtitle` and `description` are the two lines under the title; `media` is the thumbnail.

```json
"list_preview": {
  "subtitle": {"parts": ["isbn", "onix.productFormatTitle"], "join": " · ", "empty": "Ingen ISBN"},
  "description": {"each": "onix.contributors", "show": ["{contributor.title} ({role.title|lower})", "contributor.title"], "max": 2, "join": ", ", "more": " med flere"},
  "media": ["onix.thumbnail", "onix.coverImage"]
}
```

A path is dotted (`onix.formats.0.code`; a number picks a list item) and follows up to five references, each a `{_ref}` or a bare id, so `parent.parent.title` reads a grandparent. A page of rows loads its references in one read per depth. A text spec is a part or `{parts, join, empty}`. A part is a path with optional `|date` (`dd.mm.yyyy`), `|lower` or `|upper`; a template with `{path}` slots, shown only when every slot has a value; a list of parts, the first with a value; or `{each, show, max, join, more}`, which joins `show` read from each item of a list (an item that is a reference reads its target). `media` is a path or a list of alternatives: the first path holding a URL or an image with `url`, or an icon picked by a stored value:

```json
"media": ["image.url", {"icon": {"path": ["a.code", "code"], "map": {"A1": "book", "B2": null}, "else": "home"}}]
```

`path` takes the first path with a value; `map` names its icon, `else` an unnamed value's, `empty` no value's. `null` or a missing `else`/`empty` picks nothing, and the next alternative is tried. It replaces the type icon, unless the Studio cannot draw it.

`|date` shows a date-time's day in the workspace time zone (`PATCH /v1/workspace/time-zone`), else the browser's. LiveView sends a `<time>` the browser shifts (`BarkparkWeb.PreviewDay`); search `_preview` keeps UTC.

A search with `preview=1` returns the same text on each hit as `_preview`, `icon` for an icon pick ([search-query.md](search-query.md)).

A part's path can end in `|count`, the number of items in the list there, or `0` when the path holds nothing: `"{questions|count} questions"`.

## Code anchors

- `api/lib/barkpark/content/preview_text.ex`
- `api/lib/barkpark/search/hit_preview.ex`
- `api/lib/barkpark_web/studio/pane_builder.ex`
- `api/lib/barkpark_web/components/preview_day.ex`
