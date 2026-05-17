# Plugin integration — lessons from the OnixEdit refactor

Retrospective from the ten-Goal arc that converted OnixEdit from a parallel-universe LiveView world into a thin plugin riding native Barkpark machinery.

## The headline lesson

**Plugins own schemas + business logic. The host owns all UI.** Every time a plugin tried to render its own UI, it ended up as a parallel universe that drifted from the host's chrome, accumulated dead code, and confused users. The host has a single coherent editor; plugins extend it through schema metadata, not through their own LiveViews.

## What the refactor moved

| Before (plugin-owned) | After (host-owned, schema-driven) |
|---|---|
| `BookView` LiveView with own sidebar (209 LOC) | StudioLive's native editor pane |
| `BookEditor` LiveView with own form (1 341 LOC) | StudioLive editor pane + native v2 field components |
| `ThemaTreePicker` LiveComponent (~640 LOC) | Native `TreeCodelistField` triggered when codelist has `parent_id` and > 100 leaves |
| `Export.StatusPill` helper module | Native `ExternalSyncPill` + `Barkpark.ExternalSync` registry; Bokbasen is one entry |
| Plugin-specific `{:bokbasen_status_update, ...}` PubSub | Generic topic `external_sync:<system>:<doc_id>` |
| Plugin LiveView event handlers (publish, export, sign-off) | Schema declares `actions: [{name, kind: "link"|"modal"|"event"}]`; StudioLive dispatches via a registry to thin `Plugins.OnixEdit.Actions` functions |
| Plugin route `/onixedit/book/:id` | 301 redirect to native `/studio/:dataset/book/:id` |

Total deletions across the arc: ~3 783 LOC of plugin UI. Total additions to native: 5 new SchemaDefinition columns + 2 native registries + ~6 new generic components.

## The schema-metadata contract

The host now reads these declarative fields off every SchemaDefinition and renders generically. **A plugin enables a feature by declaring metadata, not by shipping a LiveView.**

| Column | Type | What it drives |
|---|---|---|
| `groups` | `{:array, :map}` | Tab bar in editor pane. Each top-level field tagged with one `group`. |
| `desk_groups` | `{:array, :map}` | Filter chips on document-list pane. `{name, title, filter}` map. Bookmarkable via `?desk=...` URL. |
| `actions` | `{:array, :map}` | Action-bar buttons in editor header. Three kinds: `link` (`<a href>` with `:dataset` + `:id` interpolation), `modal` (opens generic `ConfirmModal` with dryrun/real stages), `event` (fires `schema_action` phx-event). |
| `initial_values` | `:map` | Deep-merged into new docs at `create_document/3` time. `$today.year` and similar tokens resolved. |
| `cross_validations` | `{:array, :map}` | Rules with `any`/`all` combinators reusing `Visibility.visible?` as the per-predicate evaluator. Errors surface in editor-header banner. |

Per-field declarations the host also reads:

| Field attribute | What it drives |
|---|---|
| `group` | which tab the field renders in |
| `visibleWhen` | conditional visibility; same predicate language as `cross_validations` |
| `onix.element` | small grey hint text under the label (`ONIX: <code>NotificationType</code>`) |
| `format` (future) | ISBN/DOI/GTIN-aware string input affordances (renderer support shipped; schema declarations TBD) |

## Best-practice patterns for future plugins

### A plugin SHOULD contribute

1. **Schema JSON** under `priv/plugins/<plugin>/schemas/<name>.json`, registered via `Plugins.Bootstrap.register_all_schemas/0` at app boot.
2. **Pure Elixir modules** for transformation: exporters, parsers, validators, formatters.
3. **HTTP clients** to external systems (Bokbasen, Vlie, etc.).
4. **Oban workers** for async work (export queues, status polling, retries).
5. **Codelist data** as a static JSON/XML file in `priv/codelists/<plugin>/`, parsed by `Barkpark.Codelists.EDItEUR.seed_*` and registered into the host's codelist registry.
6. **Action handlers** as plain functions (e.g. `Plugins.OnixEdit.Actions.publish_to_bokbasen/3`) — dispatched by name from StudioLive's `schema_action` event.
7. **Sub-schema modules** (e.g. `Contributor`, `TextContent`) — spliced into the main schema's composite/arrayOf shape at registration time (otherwise nested composite fields render empty).

### A plugin MUST NOT contribute

1. LiveViews. Period.
2. HEEx templates or function components.
3. Custom sidebars, modals, or panes.
4. Plugin-specific field renderers. If the four native v2 components (`CompositeField`, `ArrayField`, `CodelistField`, `LocalizedTextField`) can't render what the plugin needs, extend the native components for **all** plugins — not just yours.
5. CSS files. Add styles to the inline `<style>` in `root.html.heex` using existing `--bg`/`--fg`/`--border` variables.
6. Plugin-specific routes for document editing. Native `/studio/:dataset/<type>/<id>` is the only edit URL.

### When the plugin needs UI that doesn't exist yet

Two options:

1. **Add a native generic.** If the affordance is reusable (status pill, tree picker, combobox, action button), it's a native component driven by schema metadata. Every plugin gets it for free.
2. **Extend the schema-metadata contract.** Add a new SchemaDefinition column or per-field attribute. The host reads it; plugins declare it.

If neither works, you're trying to ship plugin-specific UI. Stop. The "best at X" framing means making X first-class in the host, not making X live in a corner.

## Anti-patterns we shipped initially

These were intentional v1 decisions that became liabilities:

- **Plugin-owned LiveView at a separate route** (the BookEditor at `/studio/:ds/onixedit/book/:id`). Created the "fake Structure" duplicate sidebar that triggered this entire arc.
- **Plugin-specific PubSub messages** (`{:bokbasen_status_update, ...}`). Tied the consumer to the plugin's vocabulary. Generic `external_sync:<system>:<doc_id>` works for any future plugin.
- **Plugin-namespaced helpers that mirror native concepts** (`Export.StatusPill`). If the host needs a pill, the host should have a pill. If only one plugin has status, that's a sign the host is missing a primitive.
- **Tightly-coupled inline event handlers** (`handle_event("publish_to_bokbasen", ...)` in the plugin LV). Should be schema-declared actions dispatched generically.

## Surprises caught during the arc

- **Plugin-name propagation bug** (`Adapter.resolve_plugin/2`) — defaulted nested codelists to `"core"`. Affected 13 codelist `<select>` elements. Fix: walk the field subtree for the first nested codelist's plugin prefix. Bug was invisible until codelist data was seeded.
- **Schema-data bug** (book.json's `onixedit:thema → onix.codelistId: 93`). ONIX list 93 is Supplier Role, not Thema — 93 is the **SubjectSchemeIdentifier value** meaning "the value is a Thema code", not a pointer into the ONIX codelist registry. Fix: allowlist in alias resolver + bundled Thema JSON.
- **Exporter non-determinism**. `Message.wrap` passed a map for `<ONIXMessage>` XML attributes; Erlang's small-map ordering depends on hash-seed state. Fix: keyword list. Caught by the round-trip byte-for-byte proof test.
- **Sub-schema splice** (B1/B2). `book.json` declared `contributors.of.fields: []` while the full Contributor sub-schema lived in `contributor.ex`. The registration path didn't splice them. Fix: `register_schemas/1` now folds sub-schema field lists into the parent at boot.

## Process learnings

- **"Be the best at X"** is the right framing. Don't ask "what does a generic CMS do?" — ask "what would the best X-specific tool do?" Then implement that as native + schema-declarative.
- **Schema bugs often hide behind UI bugs.** When users report missing/empty fields, check the schema (and the sub-schema splice) before the renderer.
- **Visual evidence is high-leverage.** The duplicate-sidebar bug was never caught by tests. Before/after captures via visual-investigator forced the discovery.
- **Parallel subagent dispatches** scale up to ~5 if file ownership is disjoint. Beyond that, file-collision risk dominates.
- **Round-trip byte-for-byte tests** are how you catch non-determinism in encoders. Worth the upfront cost of generating a proof artifact.

## What the host has gained (reusable by any future plugin)

| Native primitive | Lives at | Drives |
|---|---|---|
| Field groups (tabs) | `studio_components.studio_field_renderer` + `visible_fields/2` | Tab bar from schema `groups` |
| Live XML preview | `BarkparkWeb.Components.OnixPreview` | Renders `Export.to_string/2` debounced |
| visibleWhen evaluator | `Components.Fields.Visibility` | Conditional field rendering |
| Cross-validator | `Content.CrossValidator` (wraps Visibility) | `any`/`all` combinators of predicates |
| Tree-codelist picker | `Components.Fields.TreeCodelistField` | Hierarchical codelist with search |
| Datalist combobox | `CodelistField` dispatch | Browser-native typeahead for flat lists > 100 |
| External sync pill | `Components.ExternalSyncPill` + `Barkpark.ExternalSync` | Subscribes to `external_sync:<system>:<doc_id>` |
| Confirm modal | `Components.ConfirmModal` | Dryrun/real two-stage flow for `kind:"modal"` actions |
| Desk filter chips | `PaneBuilder` + `Content.list_documents` new operators | URL-driven document-list filter from schema `desk_groups` |
| Initial-values factory | `Content.create_document/3` + `apply_initial_values/3` | Deep-merge defaults from schema with `$today` resolution |
| Draft-vs-published diff | `Components.DraftDiff` | Top-level field-status table |
| Overflow menu | `bp-overflow-menu` Web Component | Priority+ pattern for action bar |
| Schema-action registry | StudioLive `schema_action` handler + `Plugins.<X>.Actions` modules | Plugin actions without plugin LiveViews |

Any future plugin (Vlie, Custom-X) gets all of this for free by declaring the right schema metadata.

## TL;DR

Plugins are **data + behaviour**, never **UI**. The host is the canvas. Schema metadata is the contract. When a plugin needs UI that doesn't exist, extend the host generically — not the plugin specifically.
