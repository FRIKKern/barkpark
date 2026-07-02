import { draftMode } from 'next/headers'
import { NextResponse } from 'next/server'

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
    if (url.searchParams.get('secret') !== secret) {
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
