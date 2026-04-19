import { createWebhookHandler } from '@barkpark/nextjs/webhook'
import { revalidateBarkpark } from '@barkpark/nextjs/revalidate'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

// Barkpark Studio → Next.js revalidation webhook.
// Configure the corresponding webhook in Studio to POST events to
// https://<your-app>/api/barkpark/webhook and set BARKPARK_WEBHOOK_SECRET
// in your environment (same secret configured on the Barkpark side).
export const { POST, GET } = createWebhookHandler({
  secret: process.env.BARKPARK_WEBHOOK_SECRET!,
  onMutation: (payload) => revalidateBarkpark(payload),
})
