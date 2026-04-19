# ADR-0003: Canonical SDK cache tag convention

**Status:** Accepted
**Date:** 2026-04-19
**Deciders:** Barkpark core team
**Related:** Task #17 (realtime gap remediation); docs/adr/0001-sdk-envelope-contract.md; docs/ops/realtime-webhook-setup.md; docs/ops/research/realtime-gap-analysis.md

## Context

The `@barkpark/nextjs` SDK exposes `revalidateBarkpark(payload)` for webhook
handlers to fan out Next's `revalidateTag(...)` for a mutation. It also
exposes `barkparkFetch` which, on the published branch, sets `next.tags` so
that registered tags can later be invalidated.

Prior to Task #17 these two sides used different prefixes:

| Surface | Tag shape |
|---|---|
| `barkparkFetch` (src/server/core.ts) | `bp:ds:<dataset>:_all` |
| `revalidateBarkpark` (src/revalidate/index.ts) | `barkpark:doc:<id>`, `barkpark:type:<type>` |
| `defineActions` (src/actions/defineActions.ts) | `bp:ds:<dataset>:doc:<id>`, `:type:<type>` (already canonical) |

No tag fired by `revalidateBarkpark` ever matched a tag registered by
`barkparkFetch`. Webhook-driven invalidation was silently a no-op.

The Phoenix webhook dispatcher (`api/lib/barkpark/webhooks/dispatcher.ex`)
did not emit any tag list in its payload, forcing every revalidator to
re-derive tags from the document / event shape.

## Decision

**One canonical tag convention across the SDK and the webhook dispatcher:**

- `bp:ds:<dataset>:_all` — every fetch in a dataset.
- `bp:ds:<dataset>:doc:<id>` — a per-document fetch.
- `bp:ds:<dataset>:type:<type>` — a per-type list fetch.

`barkparkFetch` auto-tags every published-branch fetch with, in order:

```
[`bp:ds:<ds>:_all`,
 `bp:ds:<ds>:type:<type>`,      // when opts.type is set
 `bp:ds:<ds>:doc:<id>`,         // when opts.id is set
 ...userTags,
 ...knownSyncTags]
```

The Phoenix dispatcher emits a `sync_tags` array on every webhook payload:

```elixir
sync_tags: [
  "bp:ds:#{dataset}:doc:#{doc_id}",
  "bp:ds:#{dataset}:type:#{type}"
]
```

`revalidateBarkpark` prefers `payload.sync_tags` verbatim when present, and
falls back to constructing canonical tags from `{dataset, doc_id, type}` (or
the legacy `{_id, _type, ids, types}` equivalents). All tags are deduped
before `revalidateTag` fires.

## Consequences

- **Positive:** Webhook → Next cache invalidation is now functional. A
  publish of `{dataset=production, type=post, doc_id=p1}` invalidates every
  fetch tagged with `bp:ds:production:_all` / `:type:post` / `:doc:p1`.
- **Positive:** Revalidators can trust `payload.sync_tags` directly without
  re-deriving tags client-side.
- **Neutral:** `barkparkFetch`'s `next.tags` list grows by one or two
  entries. No cache key changes; force-cache semantics preserved.
- **Back-compat:** `revalidateBarkpark({_id, _type, dataset})` still works
  (normalized to canonical tags). `revalidateBarkpark('id-string')` becomes
  a silent no-op because a bare id has no dataset context — callers should
  pass the webhook payload directly.
- **Draft branch unchanged:** `cache: 'no-store'` branch must still NEVER
  set `next.tags` (ADR-0001 L31 / Next 15.5.15 contract).
- **Documented:** `docs/ops/realtime-webhook-setup.md` walks a fresh
  integration end-to-end; the CHANGELOG entry for `@barkpark/nextjs`
  announces the prefix change as a bug fix.

## Verification

- `api/test/barkpark/webhooks/dispatcher_test.exs` pins the exact two-entry
  `sync_tags` list for a representative publish event.
- `js/packages/nextjs/tests/revalidate.test.ts` asserts sync_tags / derived
  tags / dedup and includes a regression guard that no legacy
  `barkpark:doc:*` / `barkpark:type:*` literal is emitted.
- `js/packages/nextjs/tests/server.test.ts` asserts the list-fetch auto-tag
  order `['bp:ds:production:_all', 'bp:ds:production:type:post', ...userTags]`.
