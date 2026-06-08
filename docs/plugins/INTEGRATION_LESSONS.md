# Plugin integration — lessons from the OnixEdit refactor

Retrospective from the ten-Goal arc that converted OnixEdit from a parallel-universe LiveView world into a thin plugin riding native Barkpark machinery.

## The headline lesson

**Plugins contribute ONLY through the documented highway. They never bypass the host.** Every time a plugin reached around the host to wire up its own parallel universe — a route mounted by hand, a LiveView that smuggled in its own chrome, a PubSub vocabulary only it understood — it drifted from the host, accumulated dead code, and confused users. The fix was never "plugins can't have UI"; it was "every plugin capability flows through a sanctioned bucket or callback that the host owns."

The host's editor desk stays the canonical document-editing surface, and plugins extend *that* through schema metadata rather than re-implementing it. But plugins legitimately ship their own surfaces — admin/ops consoles, public reader pages — by mounting them on the host's route highway. OnixEdit today ships three admin/ops LiveViews (`PingLive`, `BokbasenLive`, `StalenessLive`) through its `register_routes/1` callback; Bulldocs ships a full public reader (`/papers/:slug`). Both are first-class precisely because they ride documented buckets instead of bypassing the router.

**The real principle: when a plugin needs a capability the highway doesn't expose yet — a new LiveView tier, a route family, a cron, a CLI verb — the answer is to add a sanctioned bucket or callback in CORE, not to route around the host.** The system already grew exactly this way (see "How the highway grew" below).

## What the refactor moved

| Before (plugin-owned) | After (host-owned, schema-driven) |
|---|---|
| `BookView` LiveView with own sidebar (209 LOC) | StudioLive's native editor pane |
| `BookEditor` LiveView with own form (1 341 LOC) | StudioLive editor pane + native v2 field components |
| `ThemaTreePicker` LiveComponent (~640 LOC) | Native `TreeCodelistField` triggered when codelist has `parent_id` and > 100 leaves |
| Per-LiveView duplicated pill palettes | Native `ExternalSyncPill` + `Barkpark.ExternalSync` registry (the host-rendered, schema-driven pill); Bokbasen is one entry. The plugin's `Export.StatusPill` survives as a single internal palette helper for OnixEdit's own ops consoles — the duplication, not the module, is what got removed. |
| Plugin-specific `{:bokbasen_status_update, ...}` PubSub | Generic topic `external_sync:<system>:<doc_id>` |
| Plugin LiveView event handlers (publish, export, sign-off) | Schema declares `actions: [{name, kind: "link"|"modal"|"event"}]`; StudioLive dispatches via a registry to thin `Plugins.OnixEdit.Actions` functions |
| Plugin route `/onixedit/book/:id` | 301 redirect to native `/studio/:dataset/book/:id` |

Total deletions across the arc: ~3 783 LOC of plugin UI. Total additions to native: 5 new SchemaDefinition columns + 2 native registries + ~6 new generic components.

## The schema-metadata contract

The host now reads these declarative fields off every SchemaDefinition and renders generically. **A plugin enables an editor-desk feature by declaring metadata, not by cloning the desk.** (Separately, a plugin can still ship its *own* surfaces — admin/ops consoles, reader pages — on the route highway; see the buckets below. The contract here is specifically about extending the canonical document editor.)

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

### A plugin MUST NOT contribute (by bypassing the highway)

The rule is about *how*, not *whether*. Each item below is forbidden as a **host-bypassing** move; the sanctioned highway path is named alongside it.

1. **A document editor that competes with the desk.** The studio desk is the canonical document-editing surface; don't ship a parallel `/studio/:ds/<plugin>/<type>/:id` editor. Extend the desk through schema metadata (`groups`, `actions`, `visibleWhen`, …) instead. (This is the one that triggered the whole arc — see anti-patterns.)
2. **Hand-mounted routes.** Don't reach into the router or stand up your own endpoint. Declare routes from `register_routes/1` and tag each with a highway bucket (`auth: :admin | :ops | :public | :public_root | :api | :token | :token_root | :ingest`). The host's `plugin_routes/1` macro mounts them under the right pipeline + `live_session`.
3. **Chrome that drifts from the host.** A plugin LiveView mounted on an `:admin`/`:ops`/`:public`/`:public_root` bucket inherits the host's layout and on-mount auth; a hand-rolled sidebar/shell that reimplements that chrome is the anti-pattern, not the LiveView itself.
4. **Plugin-specific field renderers.** If the four native v2 components (`CompositeField`, `ArrayField`, `CodelistField`, `LocalizedTextField`) can't render what the plugin needs, extend the native components for **all** plugins — not just yours.
5. **CSS files.** Add styles to the inline `<style>` in `root.html.heex` using existing `--bg`/`--fg`/`--border` variables.
6. **Plugin-specific PubSub / external-system vocabularies.** Use the generic primitives (`external_sync:<system>:<doc_id>`, the `Barkpark.ExternalSync` registry) so a host-rendered pill works for every plugin, rather than a topic only your consumer understands.

What a plugin legitimately *does* ship: admin/ops consoles and public reader pages **mounted on a highway bucket** (OnixEdit's `BokbasenLive`/`StalenessLive` on `:ops`, its `PingLive` on `:admin`; Bulldocs' reader on `:public_root`), token/ingest API controllers (`:api`/`:token`/`:token_root`/`:ingest`), Oban workers (`register_workers/1`, `oban_crontab/0`), and CLI verbs (`cli_commands/0`).

### When the plugin needs a capability that doesn't exist yet

You have three sanctioned moves, in rough order of preference. Notice that all three add to **core** — none of them route around the host.

1. **Add a native generic.** If the affordance is reusable (status pill, tree picker, combobox, action button), make it a native component driven by schema metadata. Every plugin gets it for free.
2. **Extend the schema-metadata contract.** Add a new SchemaDefinition column or per-field attribute. The host reads it; plugins declare it.
3. **Add a new highway bucket or callback to core.** If the plugin needs a kind of *surface* or *hook* the highway doesn't expose — a public reader layout, an ingest pipeline, a root-mounted token API, a cron — add a sanctioned bucket to `BarkparkWeb.Router.Plugins` (or a callback to `Barkpark.Plugin`). The host owns the new bucket; every plugin can then use it. This is how `:ops`, `:public_root`, `:ingest`, and `:token_root` came to exist (below).

If none of these fit, you're trying to smuggle plugin-specific behaviour around the host. Stop. The "best at X" framing means making X first-class in the host — a generic component, a metadata field, or a new highway bucket — not making X live in a corner the host doesn't know about.

## How the highway grew (evidence the principle is real)

The route highway in `BarkparkWeb.Router.Plugins` did not arrive fully formed. Each bucket was added to **core** the moment a plugin had a legitimate need the existing buckets couldn't serve — which is exactly the principle above, applied repeatedly:

| Bucket | Pipeline / wrapper | Added because a plugin needed… |
|---|---|---|
| `:admin` | `:browser` + `live_session on_mount: …:admin` | the original admin LiveView tier (OnixEdit `PingLive`). |
| `:ops` | `:browser` + `live_session on_mount: …:ops` | a looser publish-ops role for operator consoles (OnixEdit `BokbasenLive`, `StalenessLive`). |
| `:public` | `:browser` + `live_session` (no on_mount) | an unauthenticated in-studio LiveView (e.g. a callback page). |
| `:public_root` | `:browser`; per-route `live_session` with the spec's own `root_layout:` | a full-document **public reader** at the host top-level scope with no studio chrome (Bulldocs paper reader, `/papers/:slug`). |
| `:api` | `[:api, :require_admin]` (controller routes) | a token-gated controller endpoint under `/v1/plugins` (OnixEdit ONIX export). |
| `:token` | `[:api, :require_token]` (controller routes) | a bearer-token controller endpoint under `/v1/plugins`. |
| `:token_root` | `[:api, :require_token]`, mounted at host `/v1` | a token API at the **root** `/v1` scope, not under `/v1/plugins` (Tasks plugin `/v1/tasks`). |
| `:ingest` | `:ingest` (`RequireIngestToken`; controller routes) | a shared-secret ingest API distinct from `api_tokens` bearers (Bulldocs paper ingest, `/v1/plugins/bulldocs/*`). |

The companion `Barkpark.Plugin` callbacks grew the same way: `register_schemas/1`, `register_routes/1`, `register_workers/1`, `oban_crontab/0`, and `cli_commands/0` are each a sanctioned seam a plugin contributes through. When OnixEdit needed an ONIX-export CLI verb, the answer was a `cli_commands/0` entry the host's command registry collects — not a bespoke binary. Same principle, different seam.

## Anti-patterns we shipped initially

These were intentional v1 decisions that became liabilities:

- **A plugin LiveView that duplicated the editor desk** (the BookEditor at `/studio/:ds/onixedit/book/:id`). Created the "fake Structure" duplicate sidebar that triggered this entire arc. Note the anti-pattern was *re-implementing the document desk*, not *having a LiveView* — OnixEdit still ships admin/ops LiveViews (`BokbasenLive`, `StalenessLive`) on the `:ops` bucket, which is fine because they don't compete with the desk and inherit host chrome + auth.
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

Plugins contribute **only through the documented highway** — schemas, behaviour callbacks (`register_routes`/`register_workers`/`oban_crontab`/`cli_commands`), and route buckets (`:admin`/`:ops`/`:public`/`:public_root`/`:api`/`:token`/`:token_root`/`:ingest`). The studio desk is the canonical document editor; extend it through schema metadata rather than cloning it. A plugin may absolutely ship its own admin/ops consoles and public reader pages — as long as they ride a sanctioned bucket and inherit the host's chrome + auth. When a plugin needs a capability that doesn't exist yet, add a native generic, a metadata field, or a new highway bucket **in core** — never route around the host.
