<!-- doc-tier: agent | canonical-for: webhook-realtime-wire-contract | budget: 800tok -->
# Webhook realtime — wire contract

Wire facts for signed mutation webhooks: `Webhooks.Dispatcher` →
`@barkpark/nextjs` `createWebhookHandler`. Setup: `docs/ops/realtime-webhook-setup.md`.

## HMAC signing

Signature value: `v1=<hex>` where `<hex> = HMAC_SHA256(secret, "<timestamp>.<rawBody>")`,
timestamp in unix seconds, hex lowercase. Hash the body **exactly as received** —
never re-serialize.

## Headers — dispatcher vs handler (KNOWN MISMATCH)

| Side | Headers |
|---|---|
| Dispatcher sends (`dispatcher.ex` `attempt/5`) | `content-type: application/json` · `x-barkpark-signature: v1=<hex>` (split) · `x-barkpark-timestamp: <unix>` · `x-barkpark-event-id: <mutation_events.id>` (when threaded) |
| SDK handler expects (`createWebhookHandler`) | `x-barkpark-signature: t=<unix>,v1=<hex>` (combined, Stripe-style) · `x-barkpark-delivery-id: <id>` (optional; falls back to `payload.deliveryId`) |

As shipped these are **wire-incompatible**: a real delivery fails `401 bad_signature`
(no `t=` in the header). **Declared fix direction: reconcile the dispatcher to the
SDK handler's contract** — emit combined `t=<unix>,v1=<hex>` + `x-barkpark-delivery-id`.
(Open since 2026-05-29.) Signed material is identical; only packaging differs.

## Freshness

±300 s (handler `DEFAULT_TOLERANCE_S = 300`; override via `toleranceSeconds`).
Outside the window → `401 {"error":"stale"}`.

## Secret rotation — `previousSecret`

`createWebhookHandler({secret, previousSecret?})` accepts signatures valid under
either secret (constant-time compares) for zero-downtime rotation. Server-side,
`Dispatcher.verify_signature/4` checks primary + unexpired previous secrets.

## Canonical tag scheme

Three tags per touched document: `bp:ds:<dataset>:{_all|doc:<id>|type:<type>}` —
`_all` = any dataset read, `doc:<id>` = one published id, `type:<type>` = `_type`
filters. Same suffixes also emitted under scoped prefix
`bp:ws:<ws>:p:<project>:ds:<dataset>`; legacy flat `bp:ds:*` retained for
back-compat; unscoped mutations resolve `<ws>`/`<project>` to `default`
(`build_payload/6` via `Tenancy.resolve_scope_slugs/2`). Dispatcher `sync_tags`
carries only `doc:` + `type:` (scoped + flat) — **no `:_all`**; the handler
reconstructs `_all` from payload fields, and rebuilds tags from
`dataset`/`doc_id`/`type` when `sync_tags` is missing. All five events
(`create update publish unpublish delete`) invalidate all three tags.

## Handler responses / dispatcher retries

Handler: `200 {ok:true}` · `200 {deduped:true}` (delivery-id LRU, 512 ids) ·
`401 bad_signature|stale` · `400 bad_request` · `500 handler_failed` · GET → `405`.
Dispatcher: fixed backoff `[1s, 5s, 30s]`, 3 attempts max, 4xx terminal,
dedup via `UNIQUE(endpoint_id, event_id)` in `webhook_deliveries`.

## Code anchors

- `api/lib/barkpark/webhooks/dispatcher.ex` — `sign_payload/3`, `verify_signature/4`, `build_payload/6`, `attempt/5`, `@default_retry_delays_ms`
- `js/packages/nextjs/src/webhook/index.ts` — `createWebhookHandler`, `parseSignatureHeader`, `DEFAULT_TOLERANCE_S`, `SIG_HEADER`, `DELIVERY_HEADER`
