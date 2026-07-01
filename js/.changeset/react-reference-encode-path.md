---
"@barkpark/react": patch
---

Reference: encode the dataset and id segments in the derived doc-read fetcher path (`buildDocPath`), matching `@barkpark/core`'s `doc.ts`. Prevents malformed requests when a reference id or dataset contains a URL-special character.
