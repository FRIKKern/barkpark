// Owner ruling #42: `{ _ref }` is the canonical reference shape. The seeds and
// the typed client write it, and the Barkpark Studio does too since the ruling;
// Studio saves made before it stored a bare id ("ada"), rewritten only when the
// document is next saved. Every starter reference read goes through refOf(),
// which accepts both, so a post whose author is a bare id still shows its
// author and appears on the author's page.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { AVAILABLE_TEMPLATES } from '../src/constants'
import { refOf } from '../templates/_shared/lib/ref'

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

describe('refOf reads both stored shapes', () => {
  it('the canonical {_ref} object', () => {
    expect(refOf({ _ref: 'ada', _type: 'reference' })).toBe('ada')
  })
  it('a bare id from an older Studio save', () => {
    expect(refOf('ada')).toBe('ada')
  })
  it('unset, empty or malformed is undefined', () => {
    for (const v of [undefined, null, '', { _ref: '' }, { _ref: null }, {}]) {
      expect(refOf(v as never)).toBeUndefined()
    }
  })
})

describe('no starter reads ._ref directly', () => {
  it.each([...AVAILABLE_TEMPLATES])('%s app code goes through refOf', (template) => {
    const offenders: string[] = []
    for (const file of sourceFiles(path.join(TEMPLATES_DIR, template))) {
      const rel = path.relative(TEMPLATES_DIR, file)
      // The seeds WRITE the canonical {_ref} shape on purpose; the GROQ strings
      // in queries.ts match either shape.
      if (rel.includes(`${path.sep}seeds${path.sep}`) || rel.endsWith('queries.ts')) continue
      const code = readFileSync(file, 'utf8')
        .split('\n')
        .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
        .join('\n')
      if (/[?!]?\._ref\b|: \{ _ref: string \}/.test(code)) offenders.push(rel)
    }
    expect(offenders).toEqual([])
  })

  it('the GROQ helpers match a bare id as well as {_ref}', () => {
    const q = readFileSync(path.join(TEMPLATES_DIR, 'blog-starter', 'lib', 'queries.ts'), 'utf8')
    expect(q).toContain('author == $authorId')
    expect(q).toContain('$tagId in tags)')
  })
})
