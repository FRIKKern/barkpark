<!-- doc-tier: agent | canonical-for: sdk-envelope-contract | budget: 300tok -->
# 0001 — SDK envelope contract: nested result, Phoenix is canonical

**Status:** Accepted 2026-04-19. Corrected 2026-06-10 (prior text described the wrong wire shape). The longer original ADR record was removed; recover from git history.

**The SDK adapts to the API; the API is canonical.** Phoenix wraps every response in a `result` key with outer metadata. The SDK reads through that wrapper — never the reverse:

| Endpoint | Canonical wire shape |
|---|---|
| `GET /v1/data/query/{dataset}/{type}` | `{"result":{"count":N,"documents":[...], ...},"schemaHash":"...","etag":"...","ms":N,"syncTags":[...]}` |
| `GET /v1/data/doc/{dataset}/{type}/{id}` | `{"result":{_id, ...fields},"schemaHash":"...","etag":"...","ms":N,"syncTags":[...]}` |

SDK read path (introduced in `@barkpark/core@1.0.0-preview.1`):

- Query: `data.result?.documents ?? data.documents ?? []` (graceful fallback for transient callers that bypass the wrapper)
- Doc: `data.result` (the inner object is the document envelope)

`schemaHash` enables schema-sensitive caching. `etag` supports conditional `GET` (`If-None-Match`). `ms` is server processing time. `syncTags` are cache-tag hints for on-demand ISR revalidation.

**Binding:**
- Any envelope change requires an API version bump and a new ADR.
- Regression fixtures in `js/packages/core/tests/envelope-contract.test.ts` guard the flat-response fallback path (the shape Phoenix served before 2026-06-10). They catch regressions where the SDK would break on a flat body; they do **not** cover the `result`-nested primary path — that path currently has no dedicated fixture coverage.

## Code anchors

- `js/packages/core/src/docs.ts` — query envelope read path — the list executor inside `createDocsOperation` (`data.result?.documents ?? data.documents ?? []`)
- `js/packages/core/src/doc.ts` — single-doc envelope read path — the `'result' in data` conditional inside `getDoc`
- `js/packages/core/src/client.ts` — public client constructor; delegates to doc.ts and docs.ts
- `api/lib/barkpark_web/controllers/query_controller.ex` — envelope producer
