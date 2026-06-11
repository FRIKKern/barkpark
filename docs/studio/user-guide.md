<!-- doc-tier: human | canonical-for: studio-user-guide | budget: 1200tok -->
# Barkpark — operator's guide

For people who edit content in Barkpark Studio (not for developers).

## What Barkpark is

A headless CMS: book metadata (ONIX 3.0 first-class) plus generic content (posts, pages). Multi-pane Studio at `/studio/<dataset>` (default: `production`).

Content hierarchy: **Workspace → Project → Dataset → Documents**. Most teams have one workspace. Old content was moved to a Default workspace and project automatically — nothing lost, old links still work.

## Navigation — the desk

```
+--------------+-----------------+-----------+---------------------------------+
|  Structure   |  All Post       |  p1       |  Editor pane: p1                |
|  Book        |  drafts.book-…  |  book-…   |  [tabs] [violations]            |
|  …           |                 |           |  fields…                        |
+--------------+-----------------+-----------+---------------------------------+
```

Click left-to-right to drill. Each pane is its own URL segment — deep-linkable.

**Tab not in URL:** the active editor tab lives in the LiveView socket, NOT the URL. Sharing a book link always lands on the default (Core) tab. Desk filter chips (`?desk=drafts`) DO live in the URL and are shareable.

## Book editor

47 ONIX fields split into 8 tabs: Core · Descriptive · Contributors · Subjects · Marketing · Publishing · Supply & Pricing · Status.

### Common tasks

**Create a book:** Studio → Book → `+` → fill title + identifier → ONIX preview updates live → Publish when ready.

**Fix a typo in a published book:** Open the book → edit any field (Studio auto-creates a draft) → click Diff → click Publish.

**Bulk publish/unpublish:** check rows in the document list → floating action bar appears.

### Importing an ONIX feed

SSH procedure:

```bash
ssh root@89.167.28.206
cd /opt/barkpark/api
source /root/.asdf/asdf.sh
set -a; source ../.env; set +a

mix onix.import path/to/feed.xml --dry-run   # preview first
mix onix.import path/to/feed.xml             # creates drafts
```

Each `<Product>` becomes a draft book. `doc_id` derives from `<RecordReference>` (fallback: first `<ProductIdentifier>`). Round-trip is byte-stable: export → import → re-export produces identical XML (modulo `<SentDateTime>`).

### Bokbasen submission

**Publish to Bokbasen** button (book only): two-stage modal (dry-run → real). Fix violations banner errors first (cross-validation: `isbn_xor_gtin`, `price_currency_required`). Status pill: `draft → pending → staging → staged → polling → accepted`. On rejection: `bp_export_status.last_error` has Bokbasen's message. Full ops procedure: `docs/ops/bokbasen-go-live.md`.

## Editor header actions

| Button | What |
|---|---|
| History | Past revisions; restore via `POST /v1/data/revision/:dataset/:id/restore` |
| Delete | Remove doc (confirm; checks references) |
| Publish / Unpublish | Standard draft flow |
| Hide/Show XML | Toggle ONIX 3.0 preview pane (book only) |
| Diff | Field-level diff table (drafts with a published twin only) |
| Duplicate | Clone as new draft titled "<original> (copy)" |
| Open another | Load a second doc side-by-side (read-only) |
| Export ONIX | Download ONIX 3.0 XML (book only) |

## Thema picker

`themaSubjectCategory`: ~9,000 hierarchical subject categories. Search input + scrollable tree; click a node to expand, a leaf to select.

## "(no codelist registered)" field

```bash
# dev box
mix run -e 'Barkpark.Codelists.EDItEUR.seed_bundled()'

# prod — restart restores it via post-boot seeder
systemctl restart barkpark
```

## URL reference

```
/w/<ws>/p/<proj>/d/<dataset>/studio                  → the canonical Studio URL (workspace + project + dataset live in the path)
/w/<ws>/p/<proj>/d/<dataset>/studio/book             → all books
/w/<ws>/p/<proj>/d/<dataset>/studio/book?desk=drafts → only drafts
/w/<ws>/p/<proj>/d/<dataset>/studio/book/<doc-id>    → editor
/studio[/<dataset>/...]                              → 302 to your scoped Studio (path + query preserved)
/admin/onixedit/staleness                            → book sync status overview
```

Links are addresses now: a Studio URL opens the same workspace/project/dataset/document for whoever you share it with (membership permitting) — switching workspace changes the URL, and reload reproduces your exact location.

## Getting help

- **Schema questions:** `docs/contracts/schema-v2.md`
- **Plugin setup:** `docs/cards/plugins.md`
- **Bokbasen:** `docs/ops/bokbasen-go-live.md`
- **Field tests:** grep `api/test/barkpark_web/components/fields/` for the field type
