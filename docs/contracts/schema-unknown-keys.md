<!-- doc-tier: agent | canonical-for: schema-unknown-keys | budget: 500tok -->
# Schema unknown keys

What `POST /v1/schemas/:dataset` answers when a schema carries a key Barkpark does not read. The keys themselves are listed in [schema-reference.md](schema-reference.md).

On `POST /v1/schemas/:dataset`, only the field `type` is refused when unknown. Any other key Barkpark does not read still answers 201 (or 200 with `validate_only`), with one `warnings` entry per key: `{code: "schema_unknown_key", severity: "advisory", path, message}`. A body with no unknown key has no `warnings`. The vocabularies live in `SchemaUnknownKeys`:

| You send | Result |
|---|---|
| Unknown `type` anywhere: a top-level field, a `composite`/`image`/`file` subfield, an `arrayOf.of` (one shape or list member), an `array.of` entry, a `richText` `blocks.of` object field | 422 `validation_failed`, `details.fields`: `unknown field type "strng": …` |
| Misspelled field key (`requred: true`) | 201, stored and echoed; never read; warning at `/fields/0/requred` |
| Misspelled rule key (`validation: {requird: true}`) | 201, stored; the rule never runs; warning at `/fields/0/validation/requird` |
| Misspelled schema key (`singelton: true`) | 201, dropped; not echoed; warning at `/singelton` |
| Bare `required` on a field, bad `surface`, `visibleWhen.scope`, a reserved `blocks.inline` field name | 422 `validation_failed` |

Check the echo: `required?` on each field says whether an error-level `required` rule is in force.

## Code anchors

- `api/lib/barkpark/content/schema_unknown_keys.ex` — `unknown/1`
