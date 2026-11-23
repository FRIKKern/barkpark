// The browser library's own objects live only in check/acts.mjs: no other file of the check names the library, so
// every other file reaches a browser only through acts.mjs's launch, as a wall object (check/wall.mjs).
import { readdirSync, readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const CHECK = new URL('../check/', import.meta.url)
const NAMES = /\bplaywright(-core)?\b|\bchromium\b/

describe('the wall', () => {
  it('leaves the browser library to check/acts.mjs alone', () => {
    const files = readdirSync(CHECK).filter((f) => f.endsWith('.mjs'))
    expect(files).toContain('acts.mjs')
    expect(files.filter((f) => f !== 'acts.mjs' && NAMES.test(readFileSync(new URL(f, CHECK), 'utf8')))).toEqual([])
  })
})
