---
'@barkpark/core': minor
---

`FilterOp` accepts `is`, and the SDK's operator list is now locked to the API's.

`Barkpark.Content.Query` validated fourteen filter operators; the `FilterOp`
union typed thirteen and omitted `is`, so a typed caller could not express
`filter[<field>][is]=null` — a filter the API accepts. `is` is now in the union
and in the builder's runtime guard, takes the literal `'null'` or `'notnull'`
(anything else is a self-explaining `BarkparkValidationError` rather than an
opaque 400), and serialises to `filter[<field>][is]=null` / `=notnull`. The
existing `eq(field, null)` / `neq(field, null)` sugar is unchanged and still
emits the same wire form.

The two lists can no longer drift. `FILTER_OPS` is a new exported runtime array
(`FilterOp` is derived from it, and `filter-builder.ts`'s duplicate `VALID_OPS`
literal is gone), and both languages now read one shared fixture:
`api/test/fixtures/filter_ops.json`. An Elixir test asserts the fixture equals
`Query.valid_filter_ops/0`; a JS test asserts `FILTER_OPS` equals the fixture.

Builder-only spellings (`starts_with`, `not_starts_with`) are deliberately NOT
in the union — they have clauses on `doc_id`/`_id` only and the controller's
door refuses them on the wire.
