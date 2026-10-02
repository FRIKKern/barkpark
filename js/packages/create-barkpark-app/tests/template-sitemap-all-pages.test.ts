// Both starters built sitemap.xml from getDocs(), which reads ONE page of the
// query route (100 rows by default) and drops the envelope's hasMore — a site
// with 133 published posts shipped a sitemap with exactly 100 of them (stranger
// walk, 2026-10-01: next build of the website starter, 100 -> 122 post URLs once
// fixed; the rest have no string slug). Every sitemap read now goes through
// getAllDocs, which follows hasMore page by page. lib/barkpark.ts imports
// 'server-only' and @barkpark/nextjs, so these pins read the source.
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { AVAILABLE_TEMPLATES } from '../src/constants'

const TEMPLATES_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'templates')
const read = (template: string, rel: string) =>
  readFileSync(path.join(TEMPLATES_DIR, template, rel), 'utf8')

describe.each([...AVAILABLE_TEMPLATES])('%s sitemap reads every page', (template) => {
  it('the sitemap never reads a single page with getDocs', () => {
    const sitemap = read(template, 'app/sitemap.ts')
    expect(sitemap).toContain("getAllDocs<Post>('post')")
    expect(sitemap).not.toMatch(/\bgetDocs</)
  })

  it('getAllDocs follows hasMore with offset paging up to the sitemap cap', () => {
    const lib = read(template, 'lib/barkpark.ts')
    expect(lib).toMatch(/export async function getAllDocs<T>\(type: string(, order\?: string)?\)/)
    expect(lib).toContain('if (!env.result?.hasMore || page.length === 0) break')
    expect(lib).toContain('offset += page.length')
    expect(lib).toContain('export const SITEMAP_MAX_URLS = 50_000')
    expect(lib).toMatch(/hasMore\?: boolean/)
  })
})
