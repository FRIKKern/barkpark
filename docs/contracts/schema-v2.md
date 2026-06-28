<!-- doc-tier: agent | canonical-for: schema-v2-field-types | budget: 1800tok -->
# Schema Definition v2 — contract

Source: `api/lib/barkpark/content/schema_definition.ex` (the canonical reference — the former SCHEMA_V2.md doc was removed; recover from git history). TUI constraint (D12): `CLAUDE.md` "Plugin schemas" section.

## Four v2 field types

All four types appear only in plugin-authored schemas. The eight legacy seed schemas (post, page, author, category, project, siteSettings, navigation, colors) use only v1 primitives and round-trip unchanged via the permanent `flat_mode` branch.

### `composite` — nested object with named subfields

Composites recurse arbitrarily deep. The recursive validator (`Barkpark.Content.Validation`) walks composites with paths shaped `/<parent>/<child>` and folds path information into the v1-shaped error envelope so existing clients keep working.

### `arrayOf` — homogeneous array with `ordered` flag

`ordered: true` → up/down reorder buttons in the LiveView field component. `ordered: false` → unordered set. Drag reorder (Sortable.js + LiveView JS hook) deferred to Phase 1+.

### `codelist` — registry-backed enum pinned to an issue

`codelistId` follows `<plugin>:<name>` convention (Decision 20). Registry: `Barkpark.Content.Codelists`. Issue column is `:string` — supports ONIX integers (`"73"`) and semantic versions (`"2024-q1"`). Uniqueness key: `(plugin_name, list_id, issue)` — two plugins may register a list named `language` without collision.

### `localizedText` — multi-language string with fallback chain

`format` is `"plain"` or `"rich"`. Resolver: `Barkpark.Content.LocalizedText.resolve/2`. Default `fallbackChain`: `["nob", "eng", "first-non-empty"]`. `"first-non-empty"` walks remaining language slots in iteration order; `"any"` is an accepted alias. ONIX export (Phase 6) and Studio (Phase 5) use the same resolver — single source of truth.

## Decisions (locked)

- **Decision 7 — no `Code.eval`:** `parse/2` is data-only. Rule values in the `validations:` slot are inert data the evaluator interprets at runtime. No dynamic compilation.
- **Decision 20 — `codelistId` discriminator:** `<plugin>:<name>` convention; `plugin_name` column prevents cross-plugin collisions.
- **Decision 21 — BYO codelist snapshot:** plugin ships no EDItEUR codelist XML; publisher supplies via `BARKPARK_ONIX_CODELIST_PATH` or DB (`plugin_settings`). Core seeds bundled EDItEUR + Thema via `Barkpark.Plugins.OnixEdit.CodelistSeeders` (`api/lib/barkpark/plugins/onixedit/codelist_seeders.ex`).

## `flat_mode` is permanent

`Barkpark.Content.Validation.validate/3` dispatches on `SchemaDefinition.flat?/1`:

- **`flat_mode` branch** — `flat?/1` returns `true`: original v1 validator, byte-for-byte. Legacy schemas stay here forever.
- **v2 branch** — `flat?/1` returns `false`: schema declares any of `composite | arrayOf | codelist | localizedText` OR any non-empty `validations: [...]`.

`flat_mode` is NOT a deprecation gate; there is NO migration timetable forcing legacy schemas onto v2.

## Phase 0 / Phase 1+ boundary

**Phase 0 ships:**
- Four v2 field types in `SchemaDefinition` + `parse/2` + `flat?/1`
- Recursive validator with permanent `flat_mode` branch
- Codelist registry tables + `Barkpark.Content.Codelists`
- LiveView HEEx field components for all four v2 types
- `LocalizedText.resolve/2`
- Cross-field rule evaluator (`Barkpark.Content.Validation.Rules`) — live
- Bundled EDItEUR + Thema codelists seeded on setup

**Phase 1+ (deferred — see `docs/decisions/deferred.md`):**
- Oban + cloak_ecto wiring
- Error envelope v2 (`Accept-Version: 2`)
- Thema tree picker (modal browser)
- Simplified/Advanced toggle
- Drag reorder (Sortable.js hook)

## `bp_*` prefix lock and reserved namespace

`bp_*` — plugin custom-field prefix, LOCKED (zero collisions confirmed on 2026-04-25). `SchemaDefinition.plugin_custom_prefix/0` returns `"bp_"`.

`plugin:<name>:<field>` — reserved for plugin-private fields. `parse/2` rejects these names by default; a plugin module load passes its own name as `:plugin` to opt in. `SchemaDefinition.plugin_reserved_prefix/0` returns `"plugin:"`.

## TUI constraint (D12)

Go TUI is **read-only** for plugin schemas in v1. Documents whose schema declares any v2 type render as JSON dumps in the TUI. TUI editor menus skip `composite / arrayOf / codelist / localizedText` fields entirely — no inline form. Studio (`/studio`) is the editing surface for v2 schemas.

## Code anchors

- `api/lib/barkpark/content/schema_definition.ex` — `parse/2`, `flat?/1`, `plugin_custom_prefix/0`, `plugin_reserved_prefix/0`
- `api/lib/barkpark/content/validation.ex` — `validate/3`, flat_mode dispatch
- `api/lib/barkpark/content/validation/rules.ex` — `Rules.compile/1`
- `api/lib/barkpark/content/codelists.ex` — `register/3`, `get/2`, `lookup/3`, `tree/2`
- `api/lib/barkpark/content/localized_text.ex` — `LocalizedText.resolve/2`
- `api/priv/repo/seeds.exs` — lines 609–654 (bundled codelist seeds)
- `api/lib/barkpark_web/components/fields/` — `composite_field`, `array_field`, `codelist_field`, `localized_text_field`
