---
'@barkpark/nextjs': patch
---

Realtime webhook → `revalidateTag` bridge now works end-to-end.

**Added:** Canonical SDK cache tag convention `bp:ds:<dataset>:{_all|doc:<id>|type:<type>}`. `barkparkFetch` auto-tags list fetches with `bp:ds:<ds>:type:<type>` and per-document fetches with `bp:ds:<ds>:doc:<id>` so webhook-driven `revalidateTag` actually matches issued tags. User-supplied `tags` trail the canonical set.

**Added:** `revalidateBarkpark` now accepts the Phoenix webhook payload shape `{event, type, doc_id, document, dataset, sync_tags}` and prefers `sync_tags` (already canonical) when present; otherwise constructs canonical tags from `{dataset, doc_id, type}`. Tags are deduped before fan-out.

**Fixed:** `revalidateBarkpark` previously emitted `barkpark:doc:*` / `barkpark:type:*` literals which never matched any tag issued by `barkparkFetch` (which used `bp:ds:<ds>:_all`). Invalidation was silently a no-op. All call sites now use the canonical `bp:ds:<ds>:*` prefix. Legacy `{_id, _type, ids, types}` input is normalized to canonical tags when a `dataset` is supplied; bare-string input is now a silent no-op (no dataset context).

**Added (create-barkpark-app):** `app/api/barkpark/webhook/route.ts` wired into `website-starter` and `blog-starter` templates with HMAC verification, delivery dedup, and a forward to `revalidateBarkpark`.

Backend counterpart (Phoenix `Webhooks.Dispatcher`): every event payload now carries `sync_tags: ["bp:ds:<ds>:doc:<id>", "bp:ds:<ds>:type:<type>"]` (see ADR-0003).
