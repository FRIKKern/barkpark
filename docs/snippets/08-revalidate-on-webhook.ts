// 08-revalidate-on-webhook.ts
// App Router webhook route at app/api/barkpark/webhook/route.ts.
// Verifies HMAC, deduplicates retries, and fires revalidateBarkpark() for each
// mutation. Also demonstrates the dual-secret rotation window via previousSecret.
//
// Expected:
//   POST 200 { ok: true }         → tags revalidated
//   POST 200 { deduped: true }    → same delivery-id seen inside LRU window
//   POST 401 { error: 'bad_signature' | 'stale' }
//   GET  405 { error: 'method_not_allowed' }

import { createWebhookHandler } from '@barkpark/nextjs/webhook'
import { revalidateBarkpark } from '@barkpark/nextjs/revalidate'

const secret = process.env.BARKPARK_WEBHOOK_SECRET
if (secret === undefined) throw new Error('BARKPARK_WEBHOOK_SECRET is required')

const previousSecret = process.env.BARKPARK_WEBHOOK_SECRET_PREVIOUS

export const { POST, GET } = createWebhookHandler({
  secret,
  ...(previousSecret !== undefined ? { previousSecret } : {}),
  onMutation(payload) {
    // Barkpark mutation events carry { _id, _type, ... }. revalidateBarkpark
    // narrows these into doc:<id> + type:<type> tag calls.
    revalidateBarkpark(payload as { _id?: string; _type?: string })
  },
})
