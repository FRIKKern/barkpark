// "Latest posts" lists posts newest-PUBLISHED first.
//
// Both starters read posts without an order, and the query route's default is
// `_updatedAt desc`, so editing an old post moved it to the top of the home page.
// The blog's `order(publishedAt desc)` GROQ strings in lib/queries.ts never run.
// Every post listing now passes POST_ORDER, which the query route accepts as
// `?order=publishedAt:desc,_createdAt:desc`. lib/barkpark.ts imports
// 'server-only' and @barkpark/nextjs, so these pins read the source.
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { AVAILABLE_TEMPLATES } from '../src/constants'

const TEMPLATES_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'templates')
const read = (template: string, rel: string) =>
  readFileSync(path.join(TEMPLATES_DIR, template, rel), 'utf8')

describe.each([...AVAILABLE_TEMPLATES])('%s orders posts by publishedAt', (template) => {
  it('declares POST_ORDER as publishedAt desc with a creation-time tie-break', () => {
    expect(read(template, 'lib/barkpark.ts')).toContain(
      "export const POST_ORDER = 'publishedAt:desc,_createdAt:desc'",
    )
  })

  it('getDocs forwards an order into the query', () => {
    const lib = read(template, 'lib/barkpark.ts')
    expect(lib).toMatch(/export async function getDocs<T>\([\s\S]*?order\?: string/)
    expect(lib).toMatch(/order: opts\.order/)
  })

  it('the home page lists posts in POST_ORDER', () => {
    const page = read(template, 'app/page.tsx')
    expect(page).toMatch(/getDocs<Post>\('post', \{[\s\S]*?order: POST_ORDER/)
  })
})

describe('blog-starter tag and author pages', () => {
  it.each(['app/tags/[slug]/page.tsx', 'app/authors/[id]/page.tsx'])('%s reads posts in POST_ORDER', (rel) => {
    const src = read('blog-starter', rel)
    expect(src).toContain("await getAllDocs<Post>('post', POST_ORDER)")
  })

  it('getAllDocs forwards its order on every page it reads', () => {
    const lib = read('blog-starter', 'lib/barkpark.ts')
    expect(lib).toContain('export async function getAllDocs<T>(type: string, order?: string)')
    expect(lib).toContain('query: { filters: [], limit: 1000, offset, ...(order !== undefined ? { order } : {}) }')
  })
})
