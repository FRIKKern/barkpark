// Every place where the checker changes the page's look before a read (a sheet of its own put in the page, a pin set
// or taken off) runs inside restyle (check/probes.mjs), so the read after it is settled. Red when one does not.
import { readdirSync, readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const DIR = new URL('../check/', import.meta.url)
// The selftest's own plants change the page on purpose; the checker's readers are the rest.
const readers = () => readdirSync(DIR).filter((f) => f.endsWith('.mjs') && !/-cases\.mjs$|^selftest\.mjs$|^plants\.mjs$/.test(f))
const CHANGES = /document\.head\.prepend\(|(?:set|remove)Attribute\('data-pin'/g

/** The spans of every restyle( call in a file, by its brackets. */
function calls(text) {
  const spans = []
  for (const m of text.matchAll(/\brestyle\(/g)) {
    let depth = 0
    for (let i = m.index + m[0].length - 1; i < text.length; i++) {
      if (text[i] === '(') depth++
      else if (text[i] === ')' && --depth === 0) {
        spans.push([m.index, i])
        break
      }
    }
  }
  return spans
}

describe("the checker's own style changes", () => {
  it('each runs inside restyle, so the read after it is settled', () => {
    const open = []
    let places = 0
    for (const f of readers()) {
      const text = readFileSync(new URL(f, DIR), 'utf8')
      const spans = calls(text)
      for (const m of text.matchAll(CHANGES)) {
        places++
        if (!spans.some(([a, b]) => m.index > a && m.index < b)) open.push(`check/${f}:${text.slice(0, m.index).split('\n').length}`)
      }
    }
    console.log(`places the checker changes styles before a read: ${places}; settled before read: ${places - open.length}`)
    expect(places).toBeGreaterThan(0)
    expect(open).toEqual([])
  })
})
