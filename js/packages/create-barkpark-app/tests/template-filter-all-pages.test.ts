// A starter page that narrows a type's documents in JS must read EVERY page of
// them first.
//
// `getDocs(type)` returns one page: the query route's default of 100 rows.
// The blog starter's tag and author pages filtered that page client-side
// (`allPosts.filter(p => p.tags?.some(...))`), so every match past the first
// 100 posts disappeared. Live, with 133 published posts all carrying one tag,
// /tags/<tag> listed 100. `getAllDocs` follows `hasMore` to the end.
//
// The rule pinned here: in either starter, a variable assigned from a
// one-page `getDocs(...)` is never `.filter(...)`ed.
import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { AVAILABLE_TEMPLATES, SHARED_TEMPLATE_DIR } from '../src/constants'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const TEMPLATES_DIR = path.resolve(HERE, '..', 'templates')

async function walk(dir: string): Promise<string[]> {
  let entries
  try {
    entries = await fs.readdir(dir, { withFileTypes: true })
  } catch {
    return []
  }
  const out: string[] = []
  for (const e of entries) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) out.push(...(await walk(p)))
    else if (/\.tsx?$/.test(e.name)) out.push(p)
  }
  return out
}

describe('starter pages filter the whole type, not its first page', () => {
  for (const template of [...AVAILABLE_TEMPLATES, SHARED_TEMPLATE_DIR]) {
    it(`${template}: no .filter() over a one-page getDocs() result`, async () => {
      const offenders: string[] = []
      for (const file of await walk(path.join(TEMPLATES_DIR, template, 'app'))) {
        const src = await fs.readFile(file, 'utf8')
        for (const m of src.matchAll(/const\s+(\w+)\s*=\s*await\s+getDocs\s*</g)) {
          if (new RegExp(`\\b${m[1]}\\.filter\\(`).test(src)) {
            offenders.push(`${path.relative(TEMPLATES_DIR, file)}: ${m[1]} = getDocs(...) then ${m[1]}.filter(...)`)
          }
        }
      }
      expect(offenders).toEqual([])
    })
  }

  it('blog-starter tag and author pages read every post', async () => {
    for (const rel of ['app/tags/[slug]/page.tsx', 'app/authors/[id]/page.tsx']) {
      const src = await fs.readFile(path.join(TEMPLATES_DIR, 'blog-starter', rel), 'utf8')
      expect(src, rel).toMatch(/await getAllDocs<Post>\('post'\)/)
    }
  })
})
