<!-- doc-tier: agent | canonical-for: sync-tag-convention | budget: 900tok -->
# 0003 — Canonical SDK cache tag convention

**Status:** Accepted 2026-04-19; amended 2026-05-29 (tenancy scoping). Consolidates ADR-0003 + realtime gap-analysis option rationale (attic'd).

## Decision

One convention across SDK and Phoenix webhook dispatcher:

- `bp:ds:<dataset>:_all` — every fetch in a dataset
- `bp:ds:<dataset>:doc:<id>` — per-document fetch
- `bp:ds:<dataset>:type:<type>` — per-type list fetch

`barkparkFetch` auto-tags every published-branch fetch, in order:
`[bp:ds:<ds>:_all, bp:ds:<ds>:type:<type> (when opts.type), bp:ds:<ds>:doc:<id> (when opts.id), ...userTags, ...knownSyncTags]`.

Dispatcher emits a **4-entry** `sync_tags` on every webhook — scoped first, legacy dataset-only retained:

```elixir
scoped = "bp:ws:#{ws_slug}:p:#{project_slug}:ds:#{dataset}"
sync_tags: ["#{scoped}:doc:#{doc_id}", "#{scoped}:type:#{type}",
            "bp:ds:#{dataset}:doc:#{doc_id}", "bp:ds:#{dataset}:type:#{type}"]
```

`revalidateBarkpark` prefers `payload.sync_tags` verbatim; also emits canonical tags constructed from `{dataset, doc_id, type}` (or legacy `{_id, _type, ids, types}`); all tags are deduped before `revalidateTag` fires.

## The four broken points (pre-Task #17)

1. `/v1/data/listen/:dataset` (SSE) sits behind `:require_token` — public browsers can't subscribe without shipping a token.
2. `router.refresh()` only invalidates the Router Cache — `force-cache` fetches stayed stale until `revalidateTag` ran.
3. Nothing bridged the SSE event's `syncTags` to a `revalidateTag()` call (server-only API).
4. `revalidateBarkpark` emitted `barkpark:doc:*` / `barkpark:type:*` while `barkparkFetch` registered `bp:ds:<ds>:*` — zero overlap → silent no-op; dispatcher emitted no tag list at all.

## Why Option 1 (webhook-bridge) over 2/3

- **Option 2** (server-side SSE bridge in Next.js): long-lived process; hostile to serverless/edge; multi-instance Data Cache fragmentation (worker A's revalidate misses worker B). Rejected.
- **Option 3** (client SSE → Server Action): needs a browser-exposed token (no listen-only token type exists); chatty; unauthenticated action endpoint needs rate-limiting. Kept as possible preview-mode add-on.
- **Option 1**: ~4 file edits, no new infra, no browser token, HMAC-signed + dedup'd + retried delivery already existed. Preview/draft pages use `cache:'no-store'` and stay on `<BarkparkLive/>` + `router.refresh()`.

## Back-compat guarantees

- `revalidateBarkpark({_id, _type, dataset})` still works (normalized to canonical tags).
- `revalidateBarkpark('id-string')` is a **silent no-op** (a bare id has no dataset context) — pass the webhook payload directly.
- Draft branch (`cache: 'no-store'`) must NEVER set `next.tags` (ADR-004 / Next 15.5.15 contract).
- Legacy 2-entry dataset-only tags remain in `sync_tags`; scoped tags are additive.

## Verification

- `api/test/barkpark/webhooks/dispatcher_test.exs` — verifies expected `sync_tags` entries are present for a publish event (membership assertions, not full-list pin).
- `js/packages/nextjs/tests/revalidate.test.ts` — sync_tags/derived/dedup + guard: no legacy `barkpark:doc:*` emitted.
- `js/packages/nextjs/tests/server.test.ts` — list-fetch auto-tag order `['bp:ds:production:_all','bp:ds:production:type:post',...userTags]`.

## Code anchors

- `api/lib/barkpark/webhooks/dispatcher.ex` — `sync_tags` build + `sign_payload`
- `js/packages/nextjs/src/revalidate/index.ts` — `revalidateBarkpark`
- `js/packages/nextjs/src/server/core.ts` — `barkparkFetch` auto-tagging
- `js/packages/nextjs/src/actions/defineActions.ts`
