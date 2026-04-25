# Schema Definition v2 — Plugin author reference

> Phase 0 deliverable. Source of truth: `api/lib/barkpark/content/schema_definition.ex`.
> Masterplan: `.doey/plans/masterplan-20260425-085425.md` (Phase 0, decisions 1–21, risks).

## Audience and purpose

This document is for **plugin authors** writing new schema types and **future Taskmasters** picking up Phase 1+ work. If you are editing a v1 schema (post, page, author, category, project, siteSettings, navigation, colors), you do not need this — those continue to work unchanged via the validator's permanent `flat_mode` branch.

Read this when you are about to:

- Author a new plugin schema that declares a `composite`, `arrayOf`, `codelist`, or `localizedText` field
- Reserve a top-level cross-field rule slot for the Phase 3 evaluator
- Attach `onix:` mapping metadata to a field for the Phase 6 export adapter
- Register a codelist in the Phase 0 registry (`Barkpark.Content.Codelists`)
- Wire fallback-chain language resolution at the rendering layer

## What v2 is

Schema Definition v2 adds four nested field types and one top-level slot to the existing v1 schema format. The v1 primitives — `string`, `slug`, `text`, `richText`, `image`, `select`, `boolean`, `datetime`, `color`, `reference`, `array` — keep working verbatim. The four v2 types only appear in plugin-authored schemas; the eight legacy seed schemas (post, page, author, category, project, siteSettings, navigation, colors) use no v2 types and round-trip unchanged.

The single owner is `Barkpark.Content.SchemaDefinition`. Public surface:

| Function | Purpose |
| --- | --- |
| `parse/2` | Map → `{:ok, %SchemaDefinition.Parsed{}}` or `{:error, reason}` |
| `flat?/1` | True when the schema can run on the legacy v1 validator path |
| `plugin_reserved_prefix/0` | Returns `"plugin:"` |
| `plugin_custom_prefix/0` | Returns `"bp_"` |

`parse/2` is **data-only**. There is no `Code.eval`, no runtime macro evaluation, no dynamic compilation (Decision 7 — locked). The DSL is plain maps; the parser walks them.

### `composite` — nested object with named subfields

```elixir
%{
  "name" => "publishing",
  "type" => "composite",
  "fields" => [
    %{"name" => "imprint", "type" => "string"},
    %{"name" => "publishedDate", "type" => "datetime"},
    %{
      "name" => "city",
      "type" => "composite",
      "fields" => [%{"name" => "code", "type" => "string"}]
    }
  ]
}
```

Composites recurse arbitrarily deep. The recursive validator (`Barkpark.Content.Validation`) walks composites with paths shaped `/<parent>/<child>` and folds path information into the v1-shaped error envelope so existing clients continue to work.

### `arrayOf` — homogeneous array with `ordered` flag

```elixir
%{
  "name" => "contributors",
  "type" => "arrayOf",
  "ordered" => true,
  "of" => %{"type" => "composite", "fields" => [...]}
}
```

`ordered: true` arrays sort by index and surface up/down reorder buttons in the LiveView field component (`Barkpark.Web.Components.Fields.ArrayField.array_field/1`). `ordered: false` arrays are unordered sets — the up/down buttons are hidden. Drag reorder (Sortable.js + LiveView JS hook) is **deferred to v2**: Phase 0 ships up/down buttons + a "move to position N" input. This honors CLAUDE.md golden rule #4 (no blocking `<script>` in `<head>`); no JS hook contract is wired in Phase 0.

### `codelist` — registry-backed enum pinned to an issue

```elixir
%{
  "name" => "language",
  "type" => "codelist",
  "codelistId" => "onixedit:language",
  "version" => 73
}
```

`codelistId` follows the `<plugin>:<name>` convention (Decision 20). The registry is `Barkpark.Content.Codelists` (Phase 0 ships the tables + module; **the core ships zero codelists** — Phase 4 OnixEdit is the first consumer).

`version` is the codelist issue. ONIX integers like `73` are typical; the column is `:string` so semantic versions like `"2024-q1"` or publisher-specific tags also work.

### `localizedText` — multi-language string with fallback chain

```elixir
%{
  "name" => "blurb",
  "type" => "localizedText",
  "languages" => ["nob", "eng"],
  "format" => "rich",
  "fallbackChain" => ["nob", "eng", "first-non-empty"]
}
```

`format` is `"plain"` or `"rich"`. The `:rich` widget in Phase 0 is a `<textarea>` with a marker class — the richer editor lands in Phase 5. `fallbackChain` is documented under [fallbackChain semantics](#fallbackchain-semantics) below.

### Top-level `validations: [...]` slot

```elixir
%{
  "name" => "book",
  "fields" => [...],
  "validations" => [
    %{
      "name" => "isbn-required",
      "severity" => "error",
      "when" => %{"path" => "/format", "op" => "eq", "value" => "epub"},
      "then" => %{"path" => "/isbn", "op" => "nonempty"}
    }
  ]
}
```

The slot is **reserved but inert** in Phase 0. The parser preserves it on the `%Parsed{validations: ...}` field; the validator threads it but does not evaluate it. The interpreted-AST evaluator ships in Phase 3 (`Barkpark.Content.Validation.Rules`). Plugin authors can author rules now — they will start firing once Phase 3 lands. **No `Code.eval`** at any point — Decision 7.

### Per-field `onix:` metadata pass-through

```elixir
%{
  "name" => "isbn",
  "type" => "string",
  "onix" => %{
    "element" => "ProductIdentifier",
    "in" => "ProductIdentifier",
    "codelistId" => 5
  }
}
```

The parser preserves the `onix:` map verbatim on `%Field{onix: ...}`. **Emission ships in Phase 6** (`Barkpark.Plugins.OnixEdit.Export` walks book → ONIX 3.0 reference-tag XML using `xml_builder`). Until then, the metadata is stored data only.

## The `bp_*` prefix decision

The Phase 0 audit on 2026-04-25 (`grep -rn 'bp_' api/priv/repo/seeds.exs api/lib/barkpark/content/`) returned **zero collisions**. `bp_*` is therefore **LOCKED** as the plugin custom-field prefix.

Plugin authors use `bp_*` for non-standard fields they want to store on a document without polluting the public schema namespace. Example on a forthcoming OnixEdit `book` doc:

```elixir
%{"name" => "bp_internal_note", "type" => "string"}
```

`SchemaDefinition.plugin_custom_prefix/0` returns `"bp_"` — code that needs to identify these fields should call this helper rather than hardcoding the literal.

The fallback `bpx_` is held in reserve **only** if a future audit ever finds a collision (it must not — the audit is a Phase 0 invariant that all subsequent phases preserve). If a collision is ever reported, switch the constant in `schema_definition.ex` and document the offending file in CLAUDE.md's "Past Mistakes" section.

## The reserved namespace

Field names in the form `plugin:<name>:<field>` are reserved for **plugin-private fields** — internal state a plugin needs to attach to a document but does not expose to user-authored schemas.

`SchemaDefinition.parse/2` rejects these names by default:

```elixir
SchemaDefinition.parse(%{
  "name" => "book",
  "fields" => [%{"name" => "plugin:foo:bar", "type" => "string"}]
})
# => {:error, {:reserved_namespace, "plugin:foo:bar"}}
```

A plugin module load passes its own name as `:plugin` to opt in:

```elixir
SchemaDefinition.parse(schema, plugin: "onixedit")
# allows fields named "plugin:onixedit:*"
# still rejects "plugin:other:*"
```

`SchemaDefinition.plugin_reserved_prefix/0` returns `"plugin:"`. Code matching reserved names should use this helper.

## `flat_mode` is permanent

`Barkpark.Content.Validation.validate(content, title, schema)` dispatches on `SchemaDefinition.flat?/1`:

- **`flat_mode` branch** — runs when `flat?/1` returns `true`. Behaviour is the original v1 validator, byte-for-byte. The eight legacy seed schemas (post, page, author, category, project, siteSettings, navigation, colors) round-trip through this branch unchanged.
- **v2 branch** — runs when `flat?/1` returns `false` (the schema declares any of `composite`, `arrayOf`, `codelist`, `localizedText`, OR any non-empty top-level `validations: [...]`). Recurses into nested types and folds the path into v1-shaped error messages so existing clients keep working.

The name `flat_mode` is **permanent**. It is NOT a deprecation gate, NOT a sunset flag, and there is NO migration timetable forcing legacy schemas onto v2. Migrating legacy schemas to the v2 format is a v2 follow-up the project may or may not ever choose to do — if it happens, it happens because a feature requires it, not because Phase 0 forced it.

This explicit non-deprecation is part of risk mitigation in the masterplan: legacy schemas continue to work, Phase 0 proves the v2 plumbing without rewriting any existing data.

## fallbackChain semantics

`fallbackChain` is **pure data-resolution at the rendering layer** — not a validation concern.

The resolver lives at `Barkpark.Content.LocalizedText.resolve/2`:

```elixir
LocalizedText.resolve(
  %{"nob" => "", "eng" => "Hello"},
  ["nob", "eng", "first-non-empty"]
)
# => {:ok, "eng", "Hello"}
```

The convention default is `["nob", "eng", "first-non-empty"]`. Plugin authors override it per-field in the schema. The token `"first-non-empty"` walks any remaining language slot in iteration order and returns the first non-blank value; `"any"` is an accepted alias. Whitespace-only values are treated as missing.

When the **primary** language (the head of `fallbackChain`) is missing and a fallback is used, the LiveView field component (`Barkpark.Web.Components.Fields.LocalizedTextField.localized_text_field/1`) renders a `<span class="warning bp-localized-warning" data-severity="warning" data-missing-primary="<lang>" data-using-fallback="<lang>">`. This is a **tag class today** — the full severity DSL with `error | warning | info` semantics ships in Phase 3. Phase 0 surfaces the signal so Phase 3 has a hook; the visual treatment follows Phase 3's spec.

ONIX export (Phase 6) and Studio (Phase 5) honor the same chain via the same resolver — single source of truth.

## Codelist registry: plugin_name discriminator

Decision 20: `codelists.plugin_name` is a discriminator column. Two plugins can register a list named `language` without collision because the uniqueness key is `(plugin_name, list_id, issue)`.

List IDs follow the `<plugin>:<name>` convention (e.g. `onixedit:contributor_role`, `commerce:currency`). Issues are stored as `:string` to support both ONIX integers (`"73"`) and semantic versions (`"2024-q1"`).

Hierarchical lists (Thema, codelist 93, ~3000 nodes) use a `parent_id` self-reference on `codelist_values`. The registry exposes `tree/2` which materializes a nested `[%{value, label, children: [...]}]` map in **two queries plus an in-memory build** — verified safe at Thema scale.

`Barkpark.Content.Codelists` public surface:

| Function | Purpose |
| --- | --- |
| `register/3` | Idempotent upsert of a codelist + values + translations |
| `get/2` | Latest issue of a list, with values + translations preloaded |
| `lookup/3` | Returns `%{value, label, parent_code}` or `nil`; default fallback `["nob", "eng", any, code-as-fallback]` |
| `tree/2` | Nested tree map for hierarchical lists |
| `list/1` | Index of registered lists for a plugin |

**Core ships zero codelists.** The registry tables exist, the module exists, the parser will exist in Phase 4 (OnixEdit) — but the host app is not opinionated about which codelists are loaded. Norwegian publishers bring their own EDItEUR-licensed snapshot per the Phase 4 bring-your-own-snapshot model (Decision 21).

## Phase 0 vs Phase 1+ boundary

What Phase 0 ships (this slice):

- The four v2 field types in `SchemaDefinition` + `parse/2` + `flat?/1`
- The recursive validator with permanent `flat_mode` branch
- The codelist registry tables + `Barkpark.Content.Codelists` module
- LiveView HEEx field components for all four v2 types (`composite_field`, `array_field`, `codelist_field`, `localized_text_field`)
- The `LocalizedText.resolve/2` helper
- Dependency declarations: `:sweet_xml`, `:xml_builder`, `:cloak_ecto`, `:oban` in `mix.exs`
- The `bp_*` prefix lock and the `plugin:<name>:<field>` reserved namespace
- This document, plus the CLAUDE.md "Plugin schemas" section

What Phase 0 explicitly does NOT ship:

- **Oban + cloak_ecto wiring** — the deps are declared, the supervisor + plugin_settings + plugin_doc_state tables + encryption are Phase 1.
- **Cross-field rule DSL evaluator** — the top-level `validations: [...]` slot is reserved and inert; the interpreted-AST evaluator + severity gates + perf bench are Phase 3.
- **Error envelope v2** — the v1 envelope is still default. Header opt-in via `Accept-Version: 2` lands in Phase 3.
- **Any core codelists** — registry is empty until Phase 4 (OnixEdit) seeds the first one.
- **Thema tree picker** — flat `<select>` with breadcrumb labels is the Phase 0 UX; the modal browser ships in Phase 5.
- **Simplified / Advanced toggle** — Phase 5.
- **Plugin contract** (`Barkpark.Plugin` behaviour, manifest format, hook pipeline, scaffolder) — Phase 2.
- **OnixEdit plugin** — Phases 4–5.
- **ONIX 3.0 export** — Phase 6.
- **Bokbasen integration** — Phase 7.
- **Acknowledgement loop** — Phase 8.

## Verification status

This Phase 0 slice was authored on a development machine **without a local Elixir/mix toolchain**. The following commands were NOT run during Phase 0 authoring:

- `mix deps.get`
- `mix compile --warnings-as-errors`
- `mix test`
- `mix ecto.migrate`
- `make rebuild`

The canonical Phase 0 verification gate is the **production rebuild** (server `89.167.28.206` has Erlang/Elixir via ASDF — see CLAUDE.md "Production Server"). PRs land code-only; the deploy-side rebuild runs the test suite, migrates the codelist registry tables, and confirms the API still responds (`curl -s http://89.167.28.206/api/schemas | head -20`).

Pre-merge CI (when wired) will be the second verification path. Both routes run identical commands.

When you deploy Phase 0 changes via `make deploy` or the post-merge git hook, **always remember the golden rules from CLAUDE.md**:

1. NEVER compile without cleaning first — `make rebuild` removes `api/_build/prod` before `mix compile`.
2. NEVER skip `systemctl restart barkpark` after compiling — the old BEAM process stays in memory otherwise.
3. ALWAYS test after deploy: `curl -s http://89.167.28.206/api/schemas | head -20`.

These are non-negotiable for any change touching `schema_definition.ex`, the validator, the codelist module, or the new HEEx components — they are all loaded at boot and will be served stale if the BEAM process is not restarted.

## Pointer index

| Concern | File |
| --- | --- |
| Spec module | `api/lib/barkpark/content/schema_definition.ex` |
| Recursive validator | `api/lib/barkpark/content/validation.ex` |
| Codelist registry | `api/lib/barkpark/content/codelists.ex` + `codelists/{codelist,value,translation}.ex` |
| Codelist migration | `api/priv/repo/migrations/20260425090000_create_codelist_registry.exs` |
| LocalizedText resolver | `api/lib/barkpark/content/localized_text.ex` |
| Field components | `api/lib/barkpark_web/components/fields/{composite,array,codelist,localized_text}_field.ex` |
| Tests | `api/test/barkpark/content/{schema_definition,validation,codelists,localized_text}_test.exs` + `api/test/barkpark_web/components/fields/*_test.exs` |
| Masterplan | `.doey/plans/masterplan-20260425-085425.md` |
| TUI constraint | `CLAUDE.md` § "Plugin schemas" |
