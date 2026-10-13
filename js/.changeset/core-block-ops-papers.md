---
'@barkpark/core': minor
---

Add block-op and paper writes to the client, so an app no longer needs its own HTTP client for them.

- `applyDocOp(type, id, op, ifRev)` sends one PortableDoc block op to `POST /v1/data/doc/:dataset/:type/:id/ops` (the scoped route on a scoped client). `ifRev` is the document's `_rev`. When `drafts.<id>` exists, the op edits the draft.
- `publishPaper(paper)` publishes a paper through `POST /v1/plugins/bulldocs/papers`. This route has no revision fence.
- `applyPaperOps(slug, ops, { ifRev })` applies an atomic batch of ops to a paper, fenced on the paper's integer rev.
- `proposePaperEdits(slug, { ops, source })` proposes insert-only edits to the paper's draft.

The paper calls send the client's dataset in the body. On a scoped client, they also send the workspace and project as `X-Barkpark-Workspace` / `X-Barkpark-Project` headers, because the Bulldocs routes have no `/w/:ws/p/:proj` mount.

A stale `ifRev` throws `BarkparkConflictError` with `status: 412` and `serverCode: 'precondition_failed'`. Nothing is written. For a document op, `err.serverDoc.rev` carries the current rev.

`MediaAsset` now types the `asset` document that v1 media responses embed (`MediaAssetDocument`, with `altText` and `fileInfo.width`/`height`).
