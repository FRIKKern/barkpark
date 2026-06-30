---
'create-barkpark-app': patch
---

The website starter's `post.tags` field now generates `string[]` instead of `unknown[]`. It was declared `type: 'array'` (schema v1, whose `of` must be an ARRAY — element is `of[0]`) but given `of: { type: 'string' }` (a single object — the v2 `arrayOf` shape). codegen's `array` case sees `of` isn't an array and falls back to `Array<unknown>`, so the field lost its type. Changed it to `type: 'arrayOf'` (matching the single-object `of`, and consistent with the blog starter), which codegen maps to `Array<string>`. Verified end-to-end against `@barkpark/codegen`.
