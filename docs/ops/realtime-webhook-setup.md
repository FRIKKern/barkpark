<!-- doc-tier: agent | canonical-for: realtime-webhook-setup-procedure | budget: 600tok -->
# Realtime webhook setup — Phoenix → Next.js `revalidateTag`

Procedure only. All wire facts — the HMAC scheme, full header sets, the
dispatcher/handler header mismatch + declared fix direction, the ±300 s window,
`previousSecret` rotation, and the `bp:ds:<dataset>:{_all|doc:<id>|type:<type>}`
tag scheme — live in the contract: **`docs/contracts/webhook-realtime.md`**.

> Dispatcher and SDK handler are wire-compatible as of the reconciliation
> (2026-05-29). See the contract for the full header table.

## 1 · Studio (Phoenix) side

Register a webhook subscription pointed at the Next.js route:

```
URL:     https://<your-app>/api/barkpark/webhook
Secret:  <shared-secret>
Events:  create, update, publish, unpublish, delete  # also valid: discardDraft, patch
```

## 2 · Next.js side

Set the same secret in the deploy environment:

```bash
BARKPARK_WEBHOOK_SECRET=<shared-secret>
```

The route file (shipped by `create-barkpark-app` templates) calls
`createWebhookHandler` from `@barkpark/nextjs/webhook` and exports the returned
`{ POST, GET }` handlers, with `onMutation` piping payloads into
`revalidateBarkpark` from `@barkpark/nextjs/revalidate`. The route must set
`export const dynamic = 'force-dynamic'` and `export const runtime = 'nodejs'`
(Node crypto for HMAC). If you mount the handler at a different path, update
the Studio webhook URL — the handler is path-agnostic, Studio is not.

## 3 · Smoke test

```bash
SECRET="<shared-secret>"
T=$(date +%s)
BODY='{"event":"publish","type":"post","doc_id":"p1","dataset":"production","sync_tags":["bp:ds:production:doc:p1","bp:ds:production:type:post"],"timestamp":"2026-04-19T18:42:11Z"}'
SIG=$(printf "%s.%s" "$T" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')
curl -i -X POST https://<your-app>/api/barkpark/webhook \
  -H "Content-Type: application/json" \
  -H "x-barkpark-delivery-id: smoke-1" \
  -H "x-barkpark-signature: t=${T},v1=${SIG}" \
  -d "$BODY"
```

Expected: `200 {"ok":true}`; replaying the same delivery id returns
`200 {"deduped":true}`; the next `barkparkFetch` for that dataset serves fresh
data. First post after a deploy may take 1–2 s on serverless cold starts — the
dispatcher retries with backoff and an idempotent delivery id, so no event is
lost.
