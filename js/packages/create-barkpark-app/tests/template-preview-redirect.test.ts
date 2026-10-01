import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

// The blog-starter's /api/preview and /api/exit-preview redirected to
// `new URL(path, url.origin)`. Under a self-hosted `next start`, a route
// handler's req.url carries the server's bind host, so behind a real host or a
// proxy the editor was sent to http(s)://localhost:<port>/… (stranger walk,
// 2026-10-01). The redirect is now a RELATIVE Location — the browser resolves it
// against the host it actually asked — like @barkpark/nextjs's
// createDraftModeRoutes.

const draft = { enabled: false }
vi.mock('next/headers', () => ({
  draftMode: async () => ({
    enable: () => {
      draft.enabled = true
    },
    disable: () => {
      draft.enabled = false
    },
  }),
}))

// NextResponse.redirect as Next implements it: an ABSOLUTE Location from the URL
// it is handed. The fixed routes no longer import it; the mock only matters for
// the old shape, which is what makes this test red against it.
vi.mock('next/server', () => ({
  NextResponse: {
    redirect: (url: URL | string, init?: { status?: number }) =>
      new Response(null, { status: init?.status ?? 307, headers: { Location: String(url) } }),
  },
}))

// The routes import next/headers, which this package does not install for tsc:
// load them by URL so the typecheck does not follow the import (vitest's mocks
// above still apply at run time).
type RouteModule = { GET: (req: Request) => Promise<Response> }
const PREVIEW = new URL('../templates/blog-starter/app/api/preview/route.ts', import.meta.url).href
const EXIT = new URL('../templates/blog-starter/app/api/exit-preview/route.ts', import.meta.url)
  .href
const load = (href: string) => import(/* @vite-ignore */ href) as Promise<RouteModule>

const SECRET = 'r2d-preview-secret'
let savedSecret: string | undefined

beforeEach(() => {
  savedSecret = process.env.BARKPARK_PREVIEW_SECRET
  process.env.BARKPARK_PREVIEW_SECRET = SECRET
  draft.enabled = false
})
afterEach(() => {
  if (savedSecret === undefined) delete process.env.BARKPARK_PREVIEW_SECRET
  else process.env.BARKPARK_PREVIEW_SECRET = savedSecret
})

// What `next start` hands a route handler: its OWN bind host, whatever the
// browser's Host header said.
const asNextStartSees = (pathAndQuery: string) =>
  new Request(`http://localhost:4697${pathAndQuery}`)

describe('blog-starter preview redirects stay on the host the editor came from', () => {
  it('/api/preview answers a relative Location', async () => {
    const { GET } = await load(PREVIEW)
    const res = await GET(asNextStartSees(`/api/preview?secret=${SECRET}&path=/posts/hello`))
    expect(res.status).toBe(307)
    expect(res.headers.get('location')).toBe('/posts/hello')
    expect(draft.enabled).toBe(true)
  })

  it('/api/exit-preview answers a relative Location', async () => {
    draft.enabled = true
    const { GET } = await load(EXIT)
    const res = await GET(asNextStartSees('/api/exit-preview?path=/posts/hello'))
    expect(res.status).toBe(307)
    expect(res.headers.get('location')).toBe('/posts/hello')
    expect(draft.enabled).toBe(false)
  })

  it('keeps refusing off-site targets: they collapse to /', async () => {
    const { GET } = await load(PREVIEW)
    for (const target of ['//evil.example/x', 'https://evil.example/x', '/\\evil.example']) {
      const res = await GET(
        asNextStartSees(`/api/preview?secret=${SECRET}&path=${encodeURIComponent(target)}`),
      )
      expect(res.headers.get('location')).toBe('/')
    }
  })

  it('a bad secret still never enables draft mode', async () => {
    const { GET } = await load(PREVIEW)
    const res = await GET(asNextStartSees('/api/preview?secret=nope&path=/posts/hello'))
    expect(res.status).toBe(401)
    expect(draft.enabled).toBe(false)
  })
})
