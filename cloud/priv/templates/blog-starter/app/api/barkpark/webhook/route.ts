import { createWebhookHandler } from '@barkpark/nextjs/webhook'
import { revalidateBarkpark } from '@barkpark/nextjs/revalidate'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

// Barkpark Studio → Next.js revalidation webhook.
// Configure the corresponding webhook in Studio to POST events to
// https://<your-app>/api/barkpark/webhook and set BARKPARK_WEBHOOK_SECRET
// in your environment (same secret configured on the Barkpark side).
//
// Why the handler is built lazily instead of at module scope:
// createWebhookHandler validates its config synchronously and THROWS on an
// unset/empty secret. Next imports every route module during `next build`
// ("Collecting page data") — even with `dynamic = 'force-dynamic'` — so a
// module-scope `createWebhookHandler({ secret: process.env.…! })` would BREAK
// the production build of a freshly scaffolded app that hasn't set the secret
// yet. We defer instead: with the secret unset the route is UNAVAILABLE (503,
// fail-CLOSED — an unconfigured webhook must never fall open and skip HMAC
// verification), and the real handler is constructed lazily on first request
// once the secret exists (memoized so it is built at most once).
const secret = process.env.BARKPARK_WEBHOOK_SECRET

let handlers: ReturnType<typeof createWebhookHandler> | null = null

function getHandlers(): ReturnType<typeof createWebhookHandler> | null {
  if (!secret) return null
  if (handlers === null) {
    handlers = createWebhookHandler({
      secret,
      onMutation: (payload) => revalidateBarkpark(payload),
    })
  }
  return handlers
}

function unavailable(): Response {
  return new Response(JSON.stringify({ error: 'webhook_not_configured' }), {
    status: 503,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  })
}

export async function POST(req: Request): Promise<Response> {
  const h = getHandlers()
  return h ? h.POST(req) : unavailable()
}

export async function GET(req: Request): Promise<Response> {
  const h = getHandlers()
  return h ? h.GET(req) : unavailable()
}
