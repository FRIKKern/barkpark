# Realtime webhook setup — Phoenix → Next.js `revalidateTag`

End-to-end wiring for Barkpark's realtime cache invalidation: a Studio
mutation triggers a signed POST from the Phoenix `Webhooks.Dispatcher` to
a Next.js route that calls `revalidateTag` for the canonical SDK cache
tags. The next `barkparkFetch` misses cache and re-fetches fresh data.

Background and the alternatives weighed (browser SSE, polling, etc.) are
captured in [`docs/ops/research/realtime-gap-analysis.md`](./research/realtime-gap-analysis.md).

## Architecture

```
┌──────────────┐   mutate    ┌────────────────┐  PubSub   ┌────────────────────┐
│ Studio editor│────────────▶│ Phoenix.Content│──────────▶│ Webhooks.Dispatcher│
└──────────────┘             └────────────────┘           └─────────┬──────────┘
                                                                    │ signed POST
                                                                    │ x-barkpark-signature: t=…,v1=…
                                                                    │ x-barkpark-delivery-id: <event_id>
                                                                    ▼
                                                ┌──────────────────────────────────┐
                                                │  Next.js  app/api/barkpark/      │
                                                │           webhook/route.ts       │
                                                │  createWebhookHandler({secret,   │
                                                │    onMutation: revalidateBarkpark│
                                                │  })                              │
                                                └──────────────┬───────────────────┘
                                                               │ revalidateTag(...)
                                                               ▼
                                                ┌──────────────────────────────────┐
                                                │  Next.js Data Cache              │
                                                │  bp:ds:<ds>:_all                 │
                                                │  bp:ds:<ds>:doc:<id>             │
                                                │  bp:ds:<ds>:type:<type>          │
                                                └──────────────┬───────────────────┘
                                                               │ next barkparkFetch misses
                                                               ▼
                                                          fresh page render
```

## Canonical tag scheme

`barkparkFetch` (in `@barkpark/core`) tags every cached fetch with three
keys per document touched. The webhook handler must invalidate those exact
tags, not loose paths.

| Tag                          | Scope                                         |
| ---------------------------- | --------------------------------------------- |
| `bp:ds:<dataset>:_all`       | Any read against the dataset (list queries).  |
| `bp:ds:<dataset>:doc:<id>`   | Reads of a specific published document id.    |
| `bp:ds:<dataset>:type:<type>`| Reads filtered by document `_type`.           |

Which event invalidates which tags:

| Event         | `_all` | `doc:<id>` | `type:<type>` |
| ------------- | :----: | :--------: | :-----------: |
| `create`      |   ✅   |     ✅     |      ✅       |
| `update`      |   ✅   |     ✅     |      ✅       |
| `publish`     |   ✅   |     ✅     |      ✅       |
| `unpublish`   |   ✅   |     ✅     |      ✅       |
| `delete`      |   ✅   |     ✅     |      ✅       |

The `_all` tag is the safety net — any list query that does not pin a
specific id or type still rerenders.

## Payload shape

`Webhooks.Dispatcher` posts a JSON body of:

```json
{
  "event": "publish",
  "type": "post",
  "doc_id": "p1",
  "document": {
    "_id": "p1",
    "_type": "post",
    "_rev": "01HZX…",
    "_publishedId": "p1",
    "title": "Hello, world",
    "content": { "category": "Tech" }
  },
  "dataset": "production",
  "sync_tags": [
    "bp:ds:production:_all",
    "bp:ds:production:doc:p1",
    "bp:ds:production:type:post"
  ],
  "timestamp": "2026-04-19T18:42:11Z"
}
```

The handler trusts `sync_tags` for fanout and falls back to constructing
tags from `dataset`, `doc_id`, and `type` if `sync_tags` is missing.

## Configuration

### Studio (Phoenix) side

Register a webhook subscription pointed at the Next.js route, with the
shared secret and the events you want delivered:

```
URL:     https://<your-app>/api/barkpark/webhook
Secret:  <shared-secret>
Events:  create, update, publish, unpublish, delete
```

### Next.js side

Set the same secret in your deploy environment:

```bash
BARKPARK_WEBHOOK_SECRET=<shared-secret>
```

The route file (shipped by `create-barkpark-app` templates) imports
`createWebhookHandler` from `@barkpark/nextjs/webhook` and pipes payloads
into `revalidateBarkpark` from `@barkpark/nextjs/revalidate`.

## HMAC signing

The signature header `x-barkpark-signature` carries `t=<unix>,v1=<hex>`
where `<hex>` is `HMAC_SHA256(secret, "${t}.${rawBody}")`. The handler
enforces a ±300 s freshness window and rejects with `401 stale` outside
it. Bodies must be hashed exactly as received — do not re-serialize.

## Verification

Generate a signature with your shared secret and POST it to the route:

```bash
SECRET="<shared-secret>"
T=$(date +%s)
BODY='{"event":"publish","type":"post","doc_id":"p1","dataset":"production","sync_tags":["bp:ds:production:_all","bp:ds:production:doc:p1","bp:ds:production:type:post"],"timestamp":"2026-04-19T18:42:11Z"}'
SIG=$(printf "%s.%s" "$T" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')
curl -i -X POST https://<your-app>/api/barkpark/webhook \
  -H "Content-Type: application/json" \
  -H "x-barkpark-delivery-id: smoke-1" \
  -H "x-barkpark-signature: t=${T},v1=${SIG}" \
  -d "$BODY"
```

Expected: `200 {"ok":true}` and the next `barkparkFetch` for that dataset
serves fresh data.

## Gotchas

- **Cold starts.** First post after a deploy may take 1–2 s on serverless
  platforms. Studio retries with backoff and an idempotent delivery id, so
  no event is lost.
- **Replay protection.** `Webhooks.Dispatcher` sends a stable `event_id` per
  mutation; the handler dedupes via an in-memory LRU keyed on the
  `x-barkpark-delivery-id` header (or `payload.deliveryId`). Replays return
  `200 {"deduped": true}` without re-running invalidation.
- **`force-dynamic` is required.** The route reads the request body and
  must never be statically optimized — the template sets
  `export const dynamic = 'force-dynamic'` and `export const runtime = 'nodejs'`
  (Node crypto is needed for HMAC).
- **Secret rotation.** `createWebhookHandler` accepts an optional
  `previousSecret`; signatures valid under either are accepted, so secrets
  can be rotated without downtime.
- **Custom routes.** If you mount the handler at a different path, update
  the Studio webhook URL — the handler is path-agnostic but Studio is not.
