---
'@barkpark/codegen': patch
---

Fail loud, not opaque, on two malformed-schema shapes the envelope validator lets through. A `composite` whose nested `fields` array carries a `null`/`undefined` entry now raises the same locatable "sub-field with no `name`" error a nameless sub already did, instead of `TypeError: Cannot read properties of null (reading 'name')` — the nested `fields` key is an unvalidated zod passthrough, so this reached the mapper directly and one level down under `array`/`arrayOf`. A schema with an empty `name` now raises `codegen: schema #N has an empty \`name\`` instead of emitting `export interface  extends …` and dying inside prettier at a line number in generated output. Neither is sanitized into an invented name, and the deliberate soft degradations (`Array<unknown>`, `Record<string, unknown>`, `never`) are unchanged.
