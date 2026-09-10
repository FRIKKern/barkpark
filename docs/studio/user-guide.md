<!-- doc-tier: human | canonical-for: studio-user-guide | budget: 1200tok -->
# Barkpark — operator's guide

For people who edit content in Barkpark Studio (not for developers).

## What Barkpark is

A headless CMS. You edit documents of whatever types your team modelled — `post`, `page`, `product` — in the multi-pane Studio at `/w/<ws>/p/<proj>/d/<dataset>/studio`; `/studio/<dataset>` redirects there for your session. Plugins add specialised editors on top; the ONIX book editor below is one.

Content hierarchy: **Workspace → Project → Dataset → Documents**. Most teams have one workspace. Legacy content moved to a Default workspace and project automatically; old links still work.

## Navigation — the desk

```
+--------------+-----------------+-----------+---------------------------------+
|  Structure   |  All Post       |  p1       |  Editor pane: p1                |
|  Content     |  drafts.post-…  |  post-…   |  [tabs] [violations]            |
|  …           |                 |           |  fields…                        |
+--------------+-----------------+-----------+---------------------------------+
```

Click left-to-right to drill. Each pane is its own URL segment, so a Studio URL reopens the same document for anyone you share it with.

**Tab not in URL:** the active editor tab lives in the LiveView socket, NOT the URL. A shared link always lands on the default tab. Desk filter chips (`?desk=drafts`) DO live in the URL and are shareable.

## Editing any content type

Your own types appear in the Structure pane under **Content**, the group for every type no curated group or plugin claims; a type with no documents yet still shows. Click it for its document list, then a document to open the editor.

**Create:** Structure → your type → `+` → fill the fields → Publish when ready.

**Fix a typo in a published document:** open it → edit any field (Studio auto-creates a draft) → click Diff for the field-level changes → click Publish.

**Bulk publish/unpublish:** check rows in the document list → floating action bar appears.

## Book editor — ONIX plugin only

Everything in this section needs the OnixEdit plugin enabled.

47 ONIX fields in 8 tabs: Core · Descriptive · Contributors · Subjects · Marketing · Publishing · Supply & Pricing · Status. The ONIX 3.0 XML preview updates live beside them.

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

Each `<Product>` becomes a draft book; `doc_id` derives from `<RecordReference>` (host prefix stripped), else the first `<IDValue>`, else a random `imported-<n>`. Round-trip is byte-stable: export → import → re-export produces identical XML (modulo `<SentDateTime>`).

### Bokbasen submission

**Publish to Bokbasen** button (book only): two-stage modal (dry-run → real). Fix violations first: the `isbn_xor_gtin` cross-validation is an **error** (blocks submission); `price_currency_required` is a **warning**. Status pill: `draft → pending → staging → staged → polling → accepted`. On rejection: `bp_export_status.last_error` has Bokbasen's message.

### Thema picker

`themaSubjectCategory`: ~9,000 hierarchical subject categories. Search input + scrollable tree; click a node to expand, a leaf to select.

### "(no codelist registered)" field

```bash
# dev box
mix run -e 'Barkpark.Codelists.EDItEUR.seed_bundled()'

# prod — restart restores it via post-boot seeder
systemctl restart barkpark
```

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

## URL reference

`P` stands for `/w/<ws>/p/<proj>/d/<dataset>`:

```
P/studio                    → the canonical Studio URL
P/studio/<type>             → all documents of a type
P/studio/<type>?desk=drafts → only drafts
P/studio/<type>/<doc-id>    → editor
/studio[/<dataset>/...]     → 302 to your scoped Studio
/admin/onixedit/staleness   → book sync status (ONIX)
```

## Getting help

- **Schema questions:** `docs/contracts/schema-v2.md`
- **Plugin setup:** `docs/cards/plugins.md`
- **Bokbasen:** `docs/ops/bokbasen-go-live.md`
- **Field tests:** grep `api/test/barkpark_web/components/fields/` for the field type
