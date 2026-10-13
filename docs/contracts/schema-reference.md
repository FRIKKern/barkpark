<!-- doc-tier: agent | canonical-for: schema-field-reference | budget: 2400tok -->
# Schema reference

Every key a schema may declare when you `POST /v1/schemas/:dataset` (or `bp schema apply`), what each field `type` means, and what the server checks. Derived from the code, not from fixtures. The four nested v2 types, stored value shapes and `flat_mode` are detailed in [schema-v2.md](schema-v2.md).

## The schema object

`name` and `title` are required. Beside them the changeset stores these keys and silently drops any other: `icon`, `visibility` (`public` | `private`), `kind` (`document` | `object`; an `object` schema is a named type other schemas use as a field `type`), `singleton`, `owner_scoped`, `fields`, `groups` (editor tabs: `{name, title, icon}`), `desk_groups`, `desk` (`orderings`, `views`, `editor`: `freeform` | `classic`), `list_preview`, `initial_values`, `cross_validations`, `layout`, `prefill`, `actions`, `cors_origins`.

A top-level `validations` list is read by `parse/2` but not cast, so it is not stored.

## Keys every field accepts

| Key | Meaning |
|---|---|
| `name` | Required string. `plugin:<name>:` is reserved for plugins (422). |
| `type` | Required string: a built-in type below, or the `name` of a `kind: "object"` schema in scope. |
| `title`, `description` | Label and help text in Studio. |
| `validation` | Rules, see [Validation](#validation). |
| `visibleWhen` | `{field, operator, value?, scope?}`. Operators: `eq`, `neq`, `in`, `empty`, `non_empty`, `starts_with`, `count_eq`, `count_neq`, `count_gt`, `count_lt`. An unknown operator means visible. `field` is a dotted path; `scope` is `document` (default) or `parent` (the enclosing object or array item; refused 422 on a top-level field). Hidden fields are still validated. |
| `readOnly` | `true`, or a `visibleWhen`-shaped predicate (read-only while it holds). Enforced for non-admin API writes on top-level fields only. |
| `group` | The schema `groups` tab this field sits on (or a composite's `groups` tab). |
| `surface` | `body` or `sidebar`; anything else is refused. Metadata only. |
| `encrypted`, `private`, `visibility`, `readable_by` | Encryption at rest and per-field read visibility. |
| `options` | Type-specific, below. |
| `onix` | Passed through for ONIX export. |

## Field types

The `builtin_field_types/0` list in `Barkpark.Content.Schema`. "No value check" means `Content.Validation` applies only the generic rules; Studio draws a text input unless noted.

| Type | Meaning and type-specific keys |
|---|---|
| `string` | One line of text. |
| `text` | Multi-line text; `rows` sets the textarea height (default 3). |
| `number`, `integer`, `float` | Numeric input. `min`/`max` compare the value (v2 schemas only). |
| `boolean` | Checkbox. |
| `date`, `datetime`, `time` | Datetime picker for `datetime`; no value check. |
| `color` | Colour picker. |
| `url`, `email` | No value check; use `pattern`. |
| `slug` | Text with a Generate button. `options.source` (or `source`) names the field it derives from, default `title`. Stored as `{_type: "slug", current}` or a string. |
| `select` | `options` is a list of values or `{value, title}` (or `label`) pairs. `layout: "radio"` draws radio buttons. The server does not check membership. |
| `tags` | No value check. |
| `reference` | Points at another document. Targets: `refType` (one type), `to` (list of type names or `{type}`), or `refTypes`. `refTypeTolerant: true` keeps `refType` for the picker but resolves the target as any type. Stored as `{_ref, _type: "reference"}` or a bare id. |
| `image` | URL or `{asset: {_ref}, hotspot, crop}`. `options.hotspot: true` (or `hotspot: true`) enables the focal point and checks `hotspot`/`crop` sides are numbers 0–1. `fields` adds subfields (for example `alt`) checked like a composite's; `alt: true` shows an alt input. |
| `file` | URL or `{asset: {_ref}}`. `fields` as for `image`; no hotspot. |
| `richText` | Rich text. `editor: "blocks"` opts into the block editor; `blocks` narrows its vocabulary: `styles` (`normal`, `h1`–`h6`, `blockquote`), `lists` (`bullet`, `number`), `marks` (`strong`, `em`, `strikethrough`, `underline`, `code`), `annotations` (`link`), `of` (`image`, `divider`, `code`, `diagram`, or `{name, fields}` custom object blocks whose fields are checked, including `options.list` membership), `inline` (inline objects, [schema-v2.md](schema-v2.md)). Block writes outside the vocabulary are refused. |
| `markdown`, `json`, `embed`, `geopoint` | No value check. |
| `source` | Read-only verbatim text in Studio. |
| `array`, `object` | v1 structured values, read-only JSON in Studio. `array` takes `of` or `options.list` for the SDK echo. No `min`/`max`/`unique` check: use `arrayOf`. |
| `composite` | Object with `fields`; recursive. Optional `groups` tabs. |
| `arrayOf` | List. `of` is one field shape, or a list of `{name, …}` member types matched on each item's `_type`. `ordered: true` adds reordering. |
| `codelist` | `codelistId` (`<plugin>:<name>`), optional integer `version`. Value is a non-empty string without whitespace. |
| `localizedText` | `languages` list, `format` (`plain` \| `rich`), `fallbackChain`. Value is a map of language to text. |
| `paragraph`, `park`, `sheet`, `valueref`, `task`, `paper`, `portableDocument` | Types used by shipped templates and plugins. No value check. |

## Validation

`validation` is one rule map or a list of rule maps:

```json
"validation": [
  {"required": true},
  {"pattern": "^[a-z0-9-]+$", "message": "Lowercase letters, digits and dashes."},
  {"max": 200, "level": "warning", "message": "Over 200 characters is cut on the card."}
]
```

| Key | Effect |
|---|---|
| `required` | `true` fails on `null` or `""` only. An empty list or map passes; use `min: 1` on an `arrayOf`. A `localizedText` needs text in at least one language; its `pattern`/`min`/`max` apply to each language at `/field/<lang>`. A bare `required` on the field (outside `validation`) is refused 422. |
| `min`, `max` | String: character count (an empty string skips `min`). Number: the value, v2 schemas only. `arrayOf`: item count. Non-number bounds are ignored. |
| `pattern` | Regex the string must match. Skipped for empty or non-string values; an invalid regex is ignored. |
| `unique` | `true` on an `arrayOf`: no two items with the same `_ref` or value. |
| `message` | Replaces the wording of every finding the map produces with one finding, code `custom`. |
| `level` | `error` (default), `warning` or `info`. `warning` and `info` never block. Any other value counts as `error`. |

`pattern` with `message` is enforced on top-level fields and nested ones (`validation_nested_tree_test` pins a composite subfield). In a list, the maps at one level are merged and a later key wins, so a `message` in one error-level map rewords every error-level finding on that field.

Where findings go: Studio blocks publish on errors and shows warnings. API writes return them as `warnings` (code `schema_validation`) unless the dataset is listed in `BARKPARK_SCHEMA_ENFORCE_DATASETS`, where errors refuse the write with 422 `validation_failed`.

A flat schema (no `composite`, `arrayOf`, `codelist`, `localizedText`, structured `image`/`file`, or object blocks) checks top-level fields only and never range-checks numbers.

## Cross-field rules

`cross_validations` entries: `{name, title, rule, level, fields}`. `rule` is a `visibleWhen` predicate, or `{all: [...]}` / `{any: [...]}` of them. Studio shows unsatisfied rules as a banner; API writes get the same rules as findings (code `cross_validation`, path `/<first of fields>`) through the warnings/422 door above, by `level`. A rule naming an undeclared field or an unknown operator, or with no `rule`, is skipped and logged.

## Unknown keys

Measured against `POST /v1/schemas/:dataset` on 2026-10-10. Only the field `type` is refused when unknown. Any other key Barkpark does not read still answers 201 (or 200 with `validate_only`), with one `warnings` entry per key: `{code: "schema_unknown_key", severity: "advisory", path, message}`. A body with no unknown key has no `warnings`. The vocabularies live in `SchemaUnknownKeys`:

| You send | Result |
|---|---|
| Unknown `type` anywhere: a top-level field, a `composite`/`image`/`file` subfield, an `arrayOf.of` (one shape or list member), an `array.of` entry, a `richText` `blocks.of` object field | 422 `validation_failed`, `details.fields`: `unknown field type "strng": …` |
| Misspelled field key (`requred: true`) | 201, stored and echoed; never read; warning at `/fields/0/requred` |
| Misspelled rule key (`validation: {requird: true}`) | 201, stored; the rule never runs; warning at `/fields/0/validation/requird` |
| Misspelled schema key (`singelton: true`) | 201, dropped; not echoed; warning at `/singelton` |
| Bare `required` on a field, bad `surface`, `visibleWhen.scope`, a reserved `blocks.inline` field name | 422 `validation_failed` |

Check the echo: `required?` on each field says whether an error-level `required` rule is in force.

## Code anchors

- `api/lib/barkpark/content/schema_definition.ex` — `changeset/2`, `parse/2`
- `api/lib/barkpark/content/schema.ex` — `builtin_field_types/0`, `upsert_schema/3`
- `api/lib/barkpark/content/validation.ex` — `check/3`, `rules_at/2`
- `api/lib/barkpark/content/schema_unknown_keys.ex` — `unknown/1`
- `api/lib/barkpark/content/field_visibility.ex`, `api/lib/barkpark/content/cross_validator.ex`, `api/lib/barkpark/content/read_only_fields.ex`
- `api/lib/barkpark/portable_doc/field_vocabulary.ex` — `from_field/1`
