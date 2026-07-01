---
'@barkpark/codegen': patch
---

**Fixed:** generated `BarkparkSystemFields` now includes `_draft: boolean` and `_publishedId: string`. Every document envelope carries these (the server's `content/envelope.ex` `@reserved` set has 7 keys and always emits both; `@barkpark/core`'s `BarkparkDocument` already types them), but the generated types declared only 5 system fields — so a codegen-typed `doc._draft` / `doc._publishedId` was a compile error even though the value is always present. The generated interface now matches the server envelope and the core document type.
