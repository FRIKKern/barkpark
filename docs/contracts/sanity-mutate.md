<!-- doc-tier: agent | canonical-for: sanity-mutate-api | budget: 500tok -->
# Sanity-shaped writes

`POST /w/:ws/p/:project/v{apiVersion}/data/mutate/:dataset` takes `@sanity/client` writes (`create`, `createOrReplace`, `createIfNotExists`, `patch`, `delete`, transactions, `dryRun`). It runs the `/v1/data/mutate` pipeline and checks, but writes **exactly the id it names**, as Sanity does: a bare `x` is the published document, `drafts.x` the draft. `/v1` keeps its draft-first semantics. Server-side only: no CORS on this path (owner decision pending, task-5e59bca0170d8eda).

| Mutation on bare `x` | Result | If `drafts.x` exists |
|---|---|---|
| `createOrReplace` | publishes `x` (direct publish: publish gates run) | 409, the draft stays |
| `create` | publishes `x`; 409 if `x` exists | 409 |
| `createIfNotExists` | publishes `x`; noop if `x` exists | 409 |
| `patch` | patches published `x`; 404 if missing | 409 |
| `delete` | deletes `x`; a missing id (bare or `drafts.`) is a noop, no result row | unpublishes `x`, the draft stays |

Sanity would write past a draft twin; here the write is refused with a 409 naming it, so no write discards a draft the client did not name. `patch` and `delete` may omit `type`. A `patch` takes Sanity's `diffMatchPatch` (`{path: patch_toText}` on a string; UTF-8 offsets, fuzzy match as @sanity/diff-match-patch, a hunk that no longer matches skipped), so concurrent typing in one span merges (`Barkpark.Content.DiffMatchPatch`). Per patch: 32 KiB of patch text, 100 hunks, 20,000 UTF-16 units of text; past them, or an unparsable patch, 422. Under `fence: "fields"` its paths are not fenced: they merge. The response is Sanity's `{transactionId, results: [{id, operation, document}]}`; the client's `transactionId` is ignored.
