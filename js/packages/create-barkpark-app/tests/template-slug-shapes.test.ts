// The Barkpark Studio stores a slug field as a plain string (its Generate
// button writes "my-post"); the starters' seeds store `{ current: "my-post" }`.
// Both starters read ONLY `slug.current`, so every post slugged in the Studio
// linked by id, dropped out of sitemap.xml and 404'd at its own slug URL
// (stranger walk, 2026-09-30). Every read now goes through the shared slugOf().
import { readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { AVAILABLE_TEMPLATES, SHARED_TEMPLATE_DIR } from '../src/constants'
import { slugOf } from '../templates/_shared/lib/slug'

const TEMPLATES_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'templates')

function sourceFiles(dir: string): string[] {
  const out: string[] = []
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name)
    if (statSync(p).isDirectory()) out.push(...sourceFiles(p))
    else if (/\.(ts|tsx)$/.test(name) && !name.endsWith('.d.ts')) out.push(p)
  }
  return out
}

describe('slugOf reads both stored shapes', () => {
  it('a Studio string slug', () => {
    expect(slugOf('my-post')).toBe('my-post')
  })
  it('a seeded {current} slug', () => {
    expect(slugOf({ current: 'welcome' })).toBe('welcome')
  })
  it('unset, empty or malformed is undefined', () => {
    for (const v of [undefined, null, '', { current: '' }, { current: null }, {}]) {
      expect(slugOf(v as never)).toBeUndefined()
    }
  })
})

describe('no starter reads slug.current directly', () => {
  it.each([...AVAILABLE_TEMPLATES])('%s app code goes through slugOf', (template) => {
    const offenders: string[] = []
    for (const file of sourceFiles(path.join(TEMPLATES_DIR, template))) {
      const rel = path.relative(TEMPLATES_DIR, file)
      // The seeds WRITE the {current} shape on purpose; the GROQ string in
      // queries.ts matches either shape.
      if (rel.includes(`${path.sep}seeds${path.sep}`) || rel.endsWith('queries.ts')) continue
      const code = readFileSync(file, 'utf8')
        .split('\n')
        .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
        .join('\n')
      if (
        /(?<!')slug[?!]?\.current|slug\?: \{ current/.test(code) ||
        code.includes("'slug.current', 'eq'")
      ) {
        offenders.push(rel)
      }
    }
    expect(offenders).toEqual([])
  })

  it('getDocBySlug tries both paths in each starter', () => {
    for (const template of AVAILABLE_TEMPLATES) {
      const lib = readFileSync(path.join(TEMPLATES_DIR, template, 'lib', 'barkpark.ts'), 'utf8')
      expect(lib).toContain("for (const path of ['slug.current', 'slug'])")
      expect(lib).toContain("from './slug'")
    }
    expect(
      readFileSync(path.join(TEMPLATES_DIR, SHARED_TEMPLATE_DIR, 'lib', 'slug.ts'), 'utf8'),
    ).toContain('export function slugOf')
  })
})
