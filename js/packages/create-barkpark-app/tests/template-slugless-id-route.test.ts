// task-4446ac10d3e23182: every list page links a post as
// `/posts/${slugOf(post.slug) ?? post._id}`, so a post with no slug is linked by
// its _id. getDocBySlug matched only slug.current / slug, so that link 404'd
// (live: `/` linked /posts/p2, and /posts/p2 answered 404 under `next start`).
// This drives each starter's REAL getDocBySlug over a stubbed barkparkFetch:
// a slugless document must resolve by its id, and a slugged document must NOT,
// so it keeps exactly one URL and an id never shadows another document's slug.
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { scaffold } from '../src/scaffold'

interface Doc {
  _id: string
  slug?: unknown
}

const store: Record<string, Doc> = {}
const fetchStub = vi.fn(async (req: { type: string; id?: string; query?: unknown }) => {
  if (req.id !== undefined) {
    const doc = store[req.id]
    if (!doc) throw new NotFound()
    return { result: doc }
  }
  // A filtered read: the stub answers by evaluating the filter's value against
  // both slug shapes, the way the server's eq on slug.current / slug would.
  const filter = (req.query as { filters: { path: string; value: string }[] }).filters[0]!
  const documents = Object.values(store).filter((d) => {
    const s = d.slug
    if (filter.path === 'slug.current') {
      return (
        typeof s === 'object' && s !== null && (s as { current?: string }).current === filter.value
      )
    }
    return s === filter.value
  })
  return { result: { documents } }
})

class NotFound extends Error {}

vi.mock('server-only', () => ({}))
vi.mock('@barkpark/core', () => ({
  createClient: () => ({}),
  BarkparkNotFoundError: NotFound,
  makeFilterExpression: (path: string, _op: string, value: string) => ({ path, value }),
}))
vi.mock('@barkpark/nextjs/server', () => ({
  createBarkparkServer: () => ({ barkparkFetch: fetchStub }),
}))

// The starters' barkpark.config.ts only exists once scaffold() renders it, so
// each starter is generated through the REAL generator and its lib imported
// from there.
let tmpRoot = ''
beforeAll(async () => {
  tmpRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cba-slugless-'))
  for (const template of ['blog-starter', 'website-starter'] as const) {
    await scaffold({
      template,
      targetDir: path.join(tmpRoot, template),
      projectName: 'slugless-fixture',
      pmCommand: 'npm',
    })
  }
}, 60_000)
afterAll(async () => {
  if (tmpRoot) await fs.rm(tmpRoot, { recursive: true, force: true })
})

type Lib = { getDocBySlug: <T>(type: string, slug: string) => Promise<T | null> }
const load = (template: string) => (): Promise<Lib> =>
  import(path.join(tmpRoot, template, 'lib', 'barkpark.ts')) as Promise<Lib>
const starters = {
  'blog-starter': load('blog-starter'),
  'website-starter': load('website-starter'),
} as const

beforeEach(() => {
  for (const k of Object.keys(store)) delete store[k]
  store['p2'] = { _id: 'p2', slug: null }
  store['welcome-id'] = { _id: 'welcome-id', slug: { current: 'welcome' } }
  store['studio-id'] = { _id: 'studio-id', slug: 'studio-post' }
})

describe.each(Object.entries(starters))('%s getDocBySlug', (_name, load) => {
  it('resolves a slugless document by the _id its list link uses', async () => {
    const { getDocBySlug } = await load()
    await expect(getDocBySlug<Doc>('post', 'p2')).resolves.toMatchObject({ _id: 'p2' })
  })

  it('still resolves both slug shapes', async () => {
    const { getDocBySlug } = await load()
    await expect(getDocBySlug<Doc>('post', 'welcome')).resolves.toMatchObject({ _id: 'welcome-id' })
    await expect(getDocBySlug<Doc>('post', 'studio-post')).resolves.toMatchObject({
      _id: 'studio-id',
    })
  })

  it('does not resolve a SLUGGED document by its id (one URL per document)', async () => {
    const { getDocBySlug } = await load()
    await expect(getDocBySlug<Doc>('post', 'welcome-id')).resolves.toBeNull()
  })

  it('a key matching nothing is null (the 404 path)', async () => {
    const { getDocBySlug } = await load()
    await expect(getDocBySlug<Doc>('post', 'no-such')).resolves.toBeNull()
  })
})
