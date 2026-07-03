---
'@barkpark/core': patch
---

core: sharper TypeScript ergonomics for schema field types and typed queries — additive and non-breaking.

- New exported `BarkparkFieldType` open union enumerating the full field-type vocabulary the codegen mapper understands (`string`/`text`/`color`/`datetime`/`number`/`boolean`/`slug`/`image`/`select`/`codelist`/`reference`/`array`/`arrayOf`/`composite`/`object`/`richText`/`localizedText`). It replaces the bare `type: string` on `BarkparkSchema.fields[]` and `UpsertSchemaInput.fields[]`, so authoring a schema now gets autocomplete for the known types. The `(string & {})` arm keeps any arbitrary string assignable, so existing code and server-added types still compile.
- `DocsBuilder<T>` field-name parameters (`where`/`eq`/`neq`/`in`/`nin`/`has`/`contains`/`startsWith`/`endsWith`/`gt`/`gte`/`lt`/`lte`) now take a new `DocFieldName<T>` open union `(keyof T & string) | (string & {})` instead of `string`. A typed client (`client.docs<Post>(...)`) surfaces the document's known keys as autocomplete while still accepting dot-paths like `price.amount` and any other string — so nothing that compiled before breaks.

Types-only change; no runtime behaviour is affected.
