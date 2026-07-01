---
'@barkpark/core': minor
---

**Added:** `client.exportDataset(opts?)` — stream a dataset's documents as an async iterable (`GET /v1/data/export/:dataset`, NDJSON). The backup/portability export (Sanity's `dataset export` equivalent): the API had it and the CLI's `bp migrate` used the copy path, but the SDK could not export a dataset programmatically. Yielded lazily (a large dataset never sits in memory at once); `opts.type` restricts to one document type, `opts.perspective` picks published/drafts/raw, `opts.signal` cancels. New `ExportOptions` type.
