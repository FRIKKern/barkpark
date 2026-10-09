<!-- doc-tier: agent | canonical-for: schema-v2-field-types | budget: 1800tok -->
# Schema Definition v2 — contract

Source: `api/lib/barkpark/content/schema_definition.ex` (canonical). TUI constraint (D12): `CLAUDE.md` "Plugin schemas" section.

## Four v2 field types

All four appear only in plugin-authored schemas. The eight legacy seed schemas (post, page, author, category, project, siteSettings, navigation, colors) use only v1 primitives and round-trip unchanged via the permanent `flat_mode` branch.

### `composite` — nested object with named subfields

Composites nest to any depth. `Barkpark.Content.Validation` walks them with paths `/<parent>/<child>`, folded into the v1-shaped error envelope.

### `arrayOf` — homogeneous array with `ordered` flag

Members are typed by a single `of` **shape descriptor** (missing/non-object ⇒ `array_missing_of`), or `of: [{name, ...}, ...]` — several NAMED types, each item discriminated by its own `_type` key (task-b3ebbd3ab1575e2a; `Field.of_types`, excl. `of`; unnamed/duplicate ⇒ `array_of_type_missing_name` / `_names_not_unique`). `ordered: true` → up/down reorder in the LiveView field component (single-shape only); `ordered: false` → unordered set.

**Empty rows do not publish** (ruling #47): a scalar or reference list holding `null`, a blank string or a ref without `_ref` refuses publish: 422 `validation_failed`, `details.<field>` names the row. Drafts keep it.

### `codelist` — registry-backed enum pinned to an issue

`codelistId` is `<plugin>:<name>` (Decision 20); registry `Barkpark.Content.Codelists`. Issue is `:string` (ONIX ints like `"73"` or semver `"2024-q1"`); key `(plugin_name, list_id, issue)` lets two plugins share a `language` list name.

### `localizedText` — multi-language string with fallback chain

The field declares its language slots via `languages` (e.g. `["nob", "eng"]`; validated — an unknown/empty set is rejected). `format` is `"plain"` or `"rich"`. Resolver: `Barkpark.Content.LocalizedText.resolve/2`. `fallbackChain` defaults to `[]` when undeclared; callers (e.g. the ONIX export and Studio renderer) supply their own chain, typically `["nob", "eng", "first-non-empty"]`. `"first-non-empty"` walks remaining language slots in iteration order.

## Decisions (locked)

- **Decision 7 — no `Code.eval`:** `parse/2` is data-only. Rule values in the `validations:` slot are inert data the evaluator interprets at runtime. No dynamic compilation.
- **Decision 20 — `codelistId` discriminator:** `<plugin>:<name>` convention; `plugin_name` column prevents cross-plugin collisions.
- **Decision 21 — BYO codelist snapshot:** no bundled EDItEUR XML; publisher supplies via `BARKPARK_ONIX_CODELIST_PATH` or DB (`plugin_settings`); core seeds EDItEUR + Thema via `CodelistSeeders`.

## `flat_mode` is permanent

`Barkpark.Content.Validation.validate/3` dispatches on `SchemaDefinition.flat?/1`:

- **`flat_mode` branch** — `flat?/1` returns `true`: original v1 validator, byte-for-byte. Legacy schemas stay here forever.
- **v2 branch** — `flat?/1` returns `false`: schema declares any of `composite | arrayOf | codelist | localizedText`, an `image` with `fields` or `options.hotspot`, OR any non-empty `validations: [...]`.

`flat_mode` is NOT a deprecation gate; legacy schemas are never forced onto v2.

## Phase 0 / Phase 1+ boundary

Phase 0 shipped the four v2 types, the recursive validator, the codelist registry, the LiveView field components and the rule evaluator (`Barkpark.Content.Validation.Rules`, `Evaluator`); the `validations:` slot stays inert until Phase 3 (pinned by `validates_validations_slot_is_inert_in_phase_0`).

**Phase 1+ (deferred — `docs/decisions/deferred.md`):** Oban + cloak_ecto wiring, error envelope v2 (`Accept-Version: 2`), Thema tree picker, Simplified/Advanced toggle, drag reorder.

## Stored value shapes

References are stored as `{"_ref": id, "_type": "reference"}` (ruling #42), slugs as `{"_type": "slug", "current": text}` (#43), plain `richText` as Portable Text blocks (#44). With flag `canonical_shape_writes` on (default off), Studio writes these, except for plugin-owned types, and converts old values on their next save; readers accept both. `mix barkpark.shape.{bare_references,string_slugs,html_rich_text}` counts the rest; `--apply` converts.

An `image` is a URL or `{asset: {_ref}, hotspot: {x,y,height,width}, crop: {top,bottom,left,right}}`, sides 0–1 (legacy `url`/`assetId` read). It may declare `fields` (e.g. `alt`), kept on the image and checked like a composite's.

A block-editor `richText` declares its vocabulary under `blocks` (`FieldVocabulary`); a `blocks.of` entry `{name, fields}` is a custom object block whose fields are checked the same way.

## `required` lives under `validation`

Write `validation: {required: true}` (ruling #48). Schema apply refuses a bare field `required` key: 422 `validation_failed` naming the path. The echo's `required?` follows `validation.required` only.

## `bp_*` prefix lock and reserved namespace

`bp_*` — plugin custom-field prefix, LOCKED. `SchemaDefinition.plugin_custom_prefix/0` returns `"bp_"`.

`plugin:<name>:<field>` — reserved for plugin-private fields. `parse/2` rejects these names by default; a plugin module load passes its own name as `:plugin` to opt in. `SchemaDefinition.plugin_reserved_prefix/0` returns `"plugin:"`.

## The sidebar test — per-field `surface` (pd-doctrine t7, rule 4)

Each field MAY carry `surface: "body" | "sidebar"` — PortableDoc doctrine rule 4 ("does it read as part of the article?"). `body` = title / rich text / featured image / content blocks; `sidebar` = slug, status, taxonomies, references, dates, trade metadata, settings. Parsed by `parse_field/2` onto `Field.surface`; recurses into `composite` subfields and `arrayOf` `of` descriptors. **Absent ⇒ `nil` (unclassified)**, so a schema without `surface` round-trips unchanged and `surface` never flips `flat?/1`. Any other value ⇒ `{:error, :field_surface_invalid}`. Metadata only; no consumer yet (D1 — sidebar-v2 reads it later).

**Audit boundary:** only the 8 seed schemas (`seeds/demo.ex`) and `paper.json` are stamped; others keep `surface: nil`.

## TUI constraint (D12)

Go TUI is **read-only** for v1 plugin schemas: v2 docs render as JSON, editor menus skip `composite / arrayOf / codelist / localizedText` fields. Studio (`/studio`) edits v2 schemas.

## Code anchors

- `api/lib/barkpark/content/schema_definition.ex` — `parse/2`, `flat?/1`, `plugin_custom_prefix/0`, `plugin_reserved_prefix/0`; `Field.surface` + `parse_field_surface/1` (the sidebar test)
- `api/lib/barkpark/content/validation.ex` — `validate/3`, `check_findings/3`, flat_mode
- `api/lib/barkpark/content/validation/rules.ex` — `Rules.compile/1`
- `api/lib/barkpark/content/codelists.ex` — `register/3`, `get/2`, `lookup/3`, `tree/2`
- `api/lib/barkpark/content/localized_text.ex` — `LocalizedText.resolve/2`
- `api/lib/barkpark/seeds/demo.ex` — `seed_codelists/0` (bundled codelist seeds; invoked via `Barkpark.Seeds.run()`)
- `api/lib/barkpark_web/components/fields/` — `composite_field`, `array_field`, `codelist_field`, `localized_text_field`
