import { draftMode } from 'next/headers'
import { NextResponse } from 'next/server'

/**
 * Entry into draft-mode preview. For production, use
 * `createDraftModeRoutes` from `@barkpark/nextjs/draft-mode` with a signed URL.
 * This starter exposes a simple handler for local development.
 */
export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const redirectPath = url.searchParams.get('path') ?? '/'

  const dm = await draftMode()
  dm.enable()

  return NextResponse.redirect(new URL(redirectPath, url.origin), { status: 307 })
}
