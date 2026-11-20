// Adding parts, one at a time up to six, needs no new row in .github/required-checks.json and no new
// acknowledgement line in scripts/required-checks.test.sh. Built only from what the split and the knob do (no
// constant they export), so the same test reads red on code that would make a group with no row.
import { cpSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { discoverParts } from '../build/parts.mjs'
import { copyAs } from '../check/copy.mjs'
import { NAMES, partNames, partsDir, split } from '../check/jobs.mjs'

const repo = (p) => new URL(`../../../../${p}`, import.meta.url)
const spec = JSON.parse(readFileSync(repo('.github/required-checks.json'), 'utf8'))
const rows = new Set(spec.exclusions.map((e) => e.context))
const acks = readFileSync(repo('scripts/required-checks.test.sh'), 'utf8')
const scratch = mkdtempSync(join(tmpdir(), 'barkui-growth-test-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

/** The most copies the knob takes beside these parts: the first value it refuses, less one. */
function knobTop(dir) {
  for (let v = 0; v <= 200; v++) {
    try {
      partNames(dir, { BARKUI_PROOF_COPIES: String(v) })
    } catch {
      return v - 1
    }
  }
  return 200
}

describe('one to six parts need no new check-name row and no new acknowledgement line', () => {
  for (let n = 1; n <= 6; n++)
    it(`${n} part(s), with the proof knob at its top`, () => {
      const dir = join(scratch, `parts-${n}`)
      cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
      for (let i = 2; i <= n; i++) copyAs(join(dir, 'button'), `grown${i}-button`)
      expect(discoverParts(dir).length).toBe(n)
      const top = knobTop(dir)
      expect(top).toBeGreaterThanOrEqual(0)
      for (const v of [0, top]) {
        const groups = split(partNames(dir, { BARKUI_PROOF_COPIES: String(v) })).length
        const names = Array.from({ length: groups }, (_, i) => NAMES.group(i + 1))
        expect(names.filter((x) => !rows.has(x)), `${n} part(s), knob ${v}: rows`).toEqual([])
        expect(names.filter((x) => !acks.includes(`--expect-unrendered "${x}"`)), `${n} part(s), knob ${v}: acknowledgement lines`).toEqual([])
      }
    })
})
