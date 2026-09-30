import { draftMode } from 'next/headers'

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const raw = url.searchParams.get('path')
  const redirectPath =
    typeof raw === 'string' && raw.startsWith('/') && !raw.startsWith('//') && !raw.startsWith('/\\')
      ? raw
      : '/'
  const dm = await draftMode()
  dm.disable()
  // Relative Location, as /api/preview: `req.url` carries the bind host under a
  // self-hosted `next start`, so an absolute URL built from it pointed at localhost.
  return new Response(null, { status: 307, headers: { Location: redirectPath } })
}

export async function POST(req: Request): Promise<Response> {
  return GET(req)
}
