import { draftMode } from 'next/headers'
import { NextResponse } from 'next/server'
import { constantTimeEqual } from '../../../lib/constant-time-equal'

// `constantTimeEqual` uses `node:crypto`, and this route is the boundary in
// front of draft mode — pin the Node runtime rather than inheriting a default.
export const runtime = 'nodejs'

/**
 * Entry into draft-mode preview.
 *
 * Guarded fail-closed: if `BARKPARK_PREVIEW_SECRET` is set, the caller must pass
 * a matching `?secret=`; otherwise draft mode only opens outside production. This
 * keeps local dev frictionless while preventing anonymous visitors from enabling
 * draft mode on a deployed site and reading unpublished content. For a full
 * signed-URL flow, use `createDraftModeRoutes` from `@barkpark/nextjs/draft-mode`.
 *
 * The redirect target is same-origin only — external and protocol-relative paths
 * are rejected to prevent open redirects.
 *
 * The secret comparison is CONSTANT-TIME (`lib/constant-time-equal.ts`). A plain
 * `!==` compares length first and then bytes with an early exit, leaking both
 * the secret's length and the position of the first wrong byte; this route is
 * the only thing between an anonymous GET and `draftMode().enable()`, and it is
 * copied into every generated project, so it matches the same `timingSafeEqual`
 * standard as `@barkpark/nextjs`'s `createDraftModeRoutes` and the webhook
 * verifier in `@barkpark/core`.
 */
export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const raw = url.searchParams.get('path')
  const redirectPath =
    typeof raw === 'string' && raw.startsWith('/') && !raw.startsWith('//') && !raw.startsWith('/\\')
      ? raw
      : '/'

  const secret = process.env.BARKPARK_PREVIEW_SECRET
  if (secret) {
    if (!constantTimeEqual(url.searchParams.get('secret'), secret)) {
      return new Response('Invalid preview secret', { status: 401 })
    }
  } else if (process.env.NODE_ENV === 'production') {
    return new Response(
      'Preview is disabled: set BARKPARK_PREVIEW_SECRET (and pass ?secret=) or wire createDraftModeRoutes from @barkpark/nextjs/draft-mode',
      { status: 401 },
    )
  }

  const dm = await draftMode()
  dm.enable()

  return NextResponse.redirect(new URL(redirectPath, url.origin), { status: 307 })
}
