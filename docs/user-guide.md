# Barkpark — operator's guide

For people who edit content in Barkpark Studio (not for developers). If you are setting up Barkpark, see `README.md` and `docs/plugins/INSTALL.md`. If you are integrating Bokbasen, see `docs/ops/bokbasen-go-live.md`.

## What Barkpark is

A headless CMS for book metadata (ONIX 3.0 first-class) plus generic content (posts, pages, projects). Multi-pane Studio in the browser at `/studio/<dataset>` (default dataset: `production`).

Three things you should know before clicking around:

1. **Every document has a draft and (sometimes) a published version.** Drafts live at `doc_id = "drafts.X"`; published at `X`. Editing a published doc creates a draft alongside; publishing copies the draft to published and removes the draft. The status pill at the top of the editor tells you which you're looking at.
2. **Schemas declare structure; codelists declare allowed values.** A book schema has 47 fields organized into 8 tabs. A codelist (e.g. ContributorRole) has 124 allowed values like `A01 = Author by`, `B01 = Edited by`. The Studio renders both from the schema definition.
3. **Studio is opinionated.** ONIX-specific affordances (Thema picker, ONIX preview, cross-validation) show up only for `book` documents. Generic schemas (post, page) get the simpler shell.

## Navigation — the desk

```
+--------------+-----------------+-----------+---------------------------------+
|  Structure   |  All Post       |  p1       |  Editor pane: p1                |
|              |                 |           |                                 |
|  Book        |  drafts.book-…  |  book-…   |  [tabs] [violations]            |
|  Page        |  …              |  …        |  field 1                        |
|  Author      |                 |           |  field 2                        |
|  …           |                 |           |  …                              |
+--------------+-----------------+-----------+---------------------------------+
```

Click left-to-right to drill down. Each pane is its own URL segment — you can deep-link to a specific document or share a `?desk=...` filtered view.

### Desk filter chips (book only)

The book column has 5 filter chips at the top:

| Chip | Shows |
|---|---|
| Drafts | books that exist only as `drafts.X` (no published version yet) |
| Pending | books queued or in-flight to Bokbasen |
| Synced | books Bokbasen has accepted |
| Failed | books Bokbasen rejected or where the worker errored |
| All | every book regardless of state |

The active chip is reflected in the URL (`?desk=drafts`) — bookmarkable, shareable.

## The book editor

### Tabs

47 ONIX fields split into 8 tabs:

| Tab | What's there |
|---|---|
| **Core** | NotificationType, RecordSource*, ProductIdentifier(s), barcode |
| **Descriptive** | productForm, productMeasurements, titleDetails, religiousText, conference, edition info, productParts, productFormFeatures |
| **Contributors** | contributors (the full Contributor sub-schema), noContributor, contributorStatement |
| **Subjects** | languages, extents, subjects, themaSubjectCategory, audienceCodes, audienceRanges, complexity |
| **Marketing** | collateralDetail (textContents, supporting resources, prizes), contentDetail, relatedMaterial |
| **Publishing** | publishingDetail (publishers, dates, copyright, sales rights) |
| **Supply & Pricing** | productSupplies (markets, suppliers, prices, dates) |
| **Status** | bp_internal_note, bp_export_status, bp_last_exported_at |

Click a tab to filter the form to just those fields. The active tab persists across autosaves — you don't lose your place every time you type.

### Conditional fields

Some fields hide themselves until they're relevant:

- `audienceRanges` and `audienceDescription` — hidden until `audienceCodes` has at least one entry
- `thesis` — hidden unless `editionType` is set (RTL = revised, etc.)

This is `visibleWhen` on the schema. If you don't see a field you expect, check whether a sibling field gates it.

### ONIX hints

Most fields show a small grey line under the label:

```
Notification Type
ONIX: NotificationType
[selector]
```

That's the ONIX 3.0 XML element name. Useful when you're matching against ONIX docs or troubleshooting why Bokbasen rejected something.

### Numeric inputs

Fields like `pageRun`, `prizeYear`, `priceAmount`, `quantity` etc. render with monospace + right-aligned + `inputmode="numeric"` so mobile keyboards show digits. The ONIX standard types these as strings, but they're semantically numbers.

### Adding rows to arrays

Every `arrayOf` field has buttons:

| | |
|---|---|
| `+ Add` | append an empty row |
| `▲` `▼` | move row up/down (ordered arrays only — Contributors, TitleElements, etc.) |
| `×` | remove the row |

Works at any nesting depth — `titleDetail.titleElements`, `publishingDetail.publishers`, etc. — not just top-level arrays.

### Tree codelists (Thema)

The `themaSubjectCategory` field is special: Thema is ~9 000 hierarchical subject categories. The picker shows a search input + scrollable tree. Click a node to expand; click a leaf to select. Search filters the tree in real time.

### Large flat codelists (country, language, currency)

Country (~250), language (~6 800), currency (~180) render as text inputs bound to a `<datalist>`. Type to filter; pick a suggestion to fill the code. Note: you'll see the **code** in the field (e.g. `NO`), not the **label** (`Norway`) — labels appear only in the dropdown suggestions.

### Localized rich text

Two fields are localized rich text: `contributor.biographicalNote` and `textContent.text`. Each language gets its own rich-text editor (bold, italic, lists). The fallback chain is `["nob", "eng", "first-non-empty"]` — if Norwegian Bokmål is set, it wins; otherwise English; otherwise whatever's there.

## Editor header actions

Across the top of the editor pane (and folded into a ••• menu when the viewport narrows):

| Button | What |
|---|---|
| **History** | View past revisions; restore is not yet wired |
| **Delete** | Remove the document (asks for confirmation; checks for references) |
| **Publish / Unpublish** | Standard draft → published flow |
| **Hide XML / Show XML** | Toggle the right-hand ONIX 3.0 preview pane (book only) |
| **Diff** | Visible only on drafts that have a published twin. Swaps the form for a field-level diff table. Click again to edit. |
| **Duplicate** | Clone the current doc as a new draft titled "<original> (copy)". Lands you in the new doc. |
| **Open another** | Opens a picker to load a second document side-by-side (read-only). Useful for comparing fields between books. |
| **Export ONIX** (book only) | Direct link that downloads the current book's ONIX 3.0 XML. The same XML the live preview shows. |
| **Publish to Bokbasen** (book only) | Opens a two-stage modal: dry-run → real submission. Requires Bokbasen credentials (see `docs/ops/bokbasen-go-live.md`). |

## Violations banner

If the schema has cross-validation rules and any are failing, you'll see a banner above the editor:

```
⚠ 1 issue: At least one product identifier (ISBN, GTIN, DOI…) is required
```

Click to expand. The book schema has two rules today:
- `isbn_xor_gtin` (error) — at least one ProductIdentifier required
- `price_currency_required` (warning) — every price must have a currency code

Errors don't block save; they're warnings. Bokbasen will reject books with errors on submission.

## Live ONIX preview

For book documents, the right pane shows the generated ONIX 3.0 XML, regenerated within 500ms of every keystroke. Useful for:

- Verifying that a field you typed actually lands in the XML
- Copying the XML directly (select-all in the pane)
- Spotting export errors live ("export failed" badge if the document is structurally invalid)

Hide it with "Hide XML" if you want more horizontal space for the form.

## Bulk operations

On the document-list pane (e.g. `/studio/production/book`), each row has a checkbox. Tick one or more, and a floating action bar appears:

```
[ 3 selected ]  [Publish selected]  [Unpublish selected]
```

The bar shows progress: "Publishing 3 books…" → "Published 3 of 3". Failures are aggregated.

## Importing ONIX feeds

If a publisher sends you an ONIX 3.0 XML feed, you don't have to enter books by hand:

```bash
ssh root@89.167.28.206
cd /opt/barkpark/api
source /root/.asdf/asdf.sh
set -a; source ../.env; set +a

# Dry-run first — see what would be created
mix onix.import path/to/publisher-feed.xml --dry-run

# Real run — creates drafts
mix onix.import path/to/publisher-feed.xml
```

Each `<Product>` becomes a draft book document. The `doc_id` derives from the `<RecordReference>` (or first `<ProductIdentifier>` as fallback). The drafts show up in the book column under the "Drafts" desk filter, ready for review.

Round-trip is byte-stable: export → import → re-export produces identical XML (modulo `<SentDateTime>`).

## Common tasks

### "I want to create a new book"

1. Studio → Book → `+` button on the column
2. New book opens with sensible defaults: `notificationType=03`, `productForm=BB`, current year as `copyrightYear`, status `draft`
3. Fill in the title, identifier, and other required fields
4. The ONIX preview on the right confirms what the export will look like
5. Click Publish when ready

### "I want to fix a typo in a published book"

1. Open the published book in Studio (search by ID or scroll the column)
2. Edit any field — Studio automatically creates a draft alongside the published version
3. The status pill changes to "draft" (with a faded "published" indicator)
4. Click **Diff** to see what changed
5. Click **Publish** to push the draft to published; the draft disappears

### "I want to bulk-update 50 books"

Not yet a thing. You can bulk-publish/unpublish, but bulk-edit-a-field is not exposed in the UI. Options:
- Edit each book manually
- Write a one-off `mix run -e '...'` script using `Barkpark.Content.update_document/3`
- Ask the dev team to add a bulk-edit affordance to the schema-action registry

### "A field is showing as disabled with '(no codelist registered)'"

This means the schema declares a codelist that hasn't been seeded. On the dev box, refresh the codelist seed:

```bash
mix run -e 'Barkpark.Codelists.EDItEUR.seed_bundled()'
```

On prod, restart the service (`systemctl restart barkpark`) — the post-boot Task re-seeds. If the codelist still doesn't appear, it's either:
- A Bokbasen-internal codelist that isn't part of EDItEUR's standard set (needs to be seeded separately)
- A misconfigured schema (the `codelistId` value points at a non-existent list)

### "Bokbasen rejected my book — what now?"

1. Check the violations banner — fix any cross-validation errors first
2. Re-run the dry-run from the Publish to Bokbasen modal; the result includes Bokbasen's validation messages
3. Fix the fields the dry-run flagged
4. Re-run the dry-run until clean
5. Then click Confirm to submit for real

The status pill walks `draft → queued → staging → staged → polling → accepted`. If it goes `→ rejected` or `→ failed`, the `bp_export_status.last_error` field has Bokbasen's error message.

## Keyboard shortcuts

None custom yet. Browser defaults work (Cmd/Ctrl+S triggers form submit which is wired to "Save" → autosave anyway).

## Where to find things in the URL

```
/studio                                  → redirects to /studio/production
/studio/production                       → desk root (schema list)
/studio/production/book                  → book column (all books)
/studio/production/book?desk=drafts      → only drafts
/studio/production/book/<doc-id>         → editor for one book
/studio/production/post/post-all/<id>    → editor for one post (3-deep path)
/studio/production/onixedit/staleness    → admin: book sync status overview
```

## Getting help

- **Stuck in the editor**: every input/widget has tests; the test names describe the expected behavior. Grep `api/test/barkpark_web/components/fields/` for the field type you're confused about.
- **Schema questions**: `docs/plugins/SCHEMA_V2.md` for the v2 type system reference, `docs/plugins/INSTALL.md` for plugin install.
- **Plugin author questions**: `docs/plugins/INTEGRATION_LESSONS.md` for the "what's a plugin's job vs the host's job" retrospective.
- **Bokbasen specifically**: `docs/ops/bokbasen-go-live.md`.
