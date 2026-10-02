import { draftMode } from 'next/headers'

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const redirectPath = safeRedirectPath(url.searchParams.get('path'))
  const dm = await draftMode()
  dm.disable()
  // Relative Location, as /api/preview: `req.url` carries the bind host under a
  // self-hosted `next start`, so an absolute URL built from it pointed at localhost.
  return new Response(null, { status: 307, headers: { Location: redirectPath } })
}

export async function POST(req: Request): Promise<Response> {
  return GET(req)
}

// Same-origin relative paths only. A browser strips ASCII tab / LF / CR from a
// URL and reads `\` as `/` before it resolves a Location, so `/\t/evil.example`
// becomes `//evil.example` — another host — although it passes any prefix check
// on the raw string. Refuse control characters and backslashes outright, then
// require that the path resolves on our own origin.
function safeRedirectPath(raw: string | null): string {
  if (typeof raw !== 'string' || !raw.startsWith('/') || /[\u0000-\u001f\u007f\\]/.test(raw)) {
    return '/'
  }
  const base = 'http://redirect.invalid'
  let target: URL
  try {
    target = new URL(raw, base)
  } catch {
    return '/'
  }
  return target.origin === base ? target.pathname + target.search + target.hash : '/'
}
