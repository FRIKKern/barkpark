/**
 * Abuse guards for the anonymous contact form (app/contact/actions.ts).
 *
 * The form writes with the site's SERVER token, so every accepted submission is
 * a document in your dataset. Three cheap fences sit in front of that write:
 *
 *   1. FIELD CAPS — each field has a maximum length. Next.js already caps a
 *      server-action request body (1 MB by default, `serverActions.bodySizeLimit`);
 *      these caps keep any single document small and readable.
 *   2. HONEYPOT — a visually hidden `bp_hp` input real visitors leave empty
 *      (same field name as the astro-starter). A filled one is answered with the
 *      normal success sentence and never written, so a bot learns nothing.
 *   3. RATE LIMIT — at most CONTACT_RATE_LIMIT submissions per client IP per
 *      CONTACT_RATE_WINDOW_MS. The counter lives IN MEMORY, so it is PER SERVER
 *      INSTANCE: on serverless or multi-instance hosting each instance counts on
 *      its own and a restart forgets. It stops a single client looping the
 *      form; for a shared limit put the form behind your host's rate limiting
 *      or a store such as Redis.
 */

export const CONTACT_LIMITS = { name: 200, email: 320, message: 5000 } as const
export const HONEYPOT_FIELD = 'bp_hp'
export const CONTACT_RATE_LIMIT = 5
export const CONTACT_RATE_WINDOW_MS = 10 * 60 * 1000
const MAX_TRACKED_CLIENTS = 10_000

export type ContactFields = { name: string; email: string; message: string }

/** `null` when every field is present and within its cap, else a visitor-facing sentence. */
export function contactFieldError(fields: ContactFields): string | null {
  if (fields.name.length === 0 || fields.email.length === 0 || fields.message.length === 0) {
    return 'All fields are required.'
  }
  for (const key of ['name', 'email', 'message'] as const) {
    if (fields[key].length > CONTACT_LIMITS[key]) {
      return `Please keep the ${key} under ${CONTACT_LIMITS[key]} characters.`
    }
  }
  return null
}

/** True when the hidden honeypot input carries a value — a bot filled every field. */
export function isHoneypotFilled(value: FormDataEntryValue | null): boolean {
  return typeof value === 'string' && value.trim().length > 0
}

/**
 * The client IP as the platform's proxy reports it: the FIRST `x-forwarded-for`
 * entry, else `x-real-ip`, else one shared bucket. Behind no proxy the header is
 * client-settable — the limit is a speed bump, not an identity.
 */
export function clientKey(headers: { get(name: string): string | null }): string {
  const forwarded = headers.get('x-forwarded-for')?.split(',')[0]?.trim()
  if (forwarded) return forwarded
  const real = headers.get('x-real-ip')?.trim()
  return real || 'unknown'
}

/** A fixed-window counter per client key. Exported as a factory so tests get a fresh one. */
export function createContactRateLimiter(
  limit: number = CONTACT_RATE_LIMIT,
  windowMs: number = CONTACT_RATE_WINDOW_MS,
) {
  const hits = new Map<string, { count: number; resetAt: number }>()
  return {
    /** Counts one submission for `key`; `false` once the window's budget is spent. */
    allow(key: string, now: number = Date.now()): boolean {
      const entry = hits.get(key)
      if (!entry || entry.resetAt <= now) {
        if (hits.size >= MAX_TRACKED_CLIENTS) {
          for (const [k, v] of hits) if (v.resetAt <= now) hits.delete(k)
          if (hits.size >= MAX_TRACKED_CLIENTS) hits.clear()
        }
        hits.set(key, { count: 1, resetAt: now + windowMs })
        return true
      }
      if (entry.count >= limit) return false
      entry.count += 1
      return true
    },
  }
}
