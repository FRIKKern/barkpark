<!-- doc-tier: human | canonical-for: plugin-catalog | budget: 1200tok -->
# Plugin catalog — the blessed default for each job

Barkpark ships first-party plugins on the `Barkpark.Plugin` highway. For each job there is
**one blessed way** — use it rather than rolling your own. With every plugin off, Barkpark
still works; turning one on is how you get tasks, papers, sheets, ONIX, or media. To build
or modify a plugin, see [../cards/plugins.md](../cards/plugins.md).

| Plugin | What it does | When to use |
|---|---|---|
| **Tasks** | Claimable, dependency-aware work queue. Tasks are documents (a goal is a root task, a phase is a task with children) driven by the `bp task` CLI over `/v1/tasks`. | All task / work tracking. This is the **only** blessed tracker — do not use TodoWrite or markdown TODO lists. |
| **Bulldocs** | The live, no-reload paper surface. Producers POST block-structured papers to the ingest API; they store as `type:"paper"` documents and render at `/papers/:slug` with per-block streaming. | Publishing live documents / "papers" that update without a reload. |
| **Sheets** | Collaborative spreadsheet. Multi-tab `type:"sheet"` documents with Excel-compatible formulas; public reader at `/sheets/:slug`; import (`xlsx · csv · tsv`) and export (`xlsx · csv · tsv · md · html`). | Spreadsheet content and tabular import/export. |
| **OnixEdit** | ONIX 3.0 book-metadata editor + export. A ~200-field `book` schema in Schema v2; editing happens in Studio. Deep dive: [../cards/onix-bokbasen.md](../cards/onix-bokbasen.md). | Book/publishing metadata and ONIX export. |
| **Media** | Native media library — one `mediaAsset` document per uploaded file. Binary bytes live in `media_files`; alt text / collections / rights / tags are queryable plugin documents. | Uploading and managing images and files. |

## Search is a capability, not a registry plugin

**Indx** is the blessed search retriever — but it is **deliberately not** a `Barkpark.Plugin`.
Search rides the retriever seam (`QueryPipeline.search/4`); the Indx engine plugs in via
`engine=indx` and is intentionally absent from the plugin registry. Treat it as the blessed
**search capability**, configured through the search layer, not toggled like the plugins
above. Architecture: [../cards/search-media.md](../cards/search-media.md).

---

<sup>Eleven modules carry `use Barkpark.Plugin`; this table curates five. Not listed, and why:
**frt** (Frickin Real Time) is an author-first production content model mirroring a real Godot
game's data structures, not a first-party tool. **github**, **pulse**, **quiz**, **scaffy** and
**tickets** are registered first-party plugins that landed after this table was written and have
no curated row yet. Re-derive the roster rather than trusting this list:
`grep -l 'use Barkpark.Plugin' api/lib/barkpark/plugins/*.ex`.</sup>
