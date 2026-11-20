// What a new part changes outside its folder, as docs/PARTS.md says it: nothing a
// script writes, and by hand only a changeset, up to MOST_PARTS parts.
import { createHash } from 'node:crypto'
import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { describe, expect, it } from 'vitest'
import { copyAs } from '../check/copy.mjs'
import { MOST_PARTS, partNames, split } from '../check/jobs.mjs'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom, root, tokensPath } from '../build/showroom.mjs'
import { readFacts, renderRows } from '../build/status.mjs'

const SKIP = new Set(['node_modules', 'dist', 'parts', '.turbo'])
/** Every file of the package outside parts/ (and what is never tracked), plus the sheet, as path -> hash. */
function tree(dir = root, out = {}) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) { if (!SKIP.has(e.name)) tree(p, out) } else out[relative(root, p)] = createHash('sha256').update(readFileSync(p)).digest('hex')
  }
  return out
}
const flat = (s) => s.replace(/\s+/g, ' ')

describe('a new part', () => {
  it('changes no file outside parts/ when it is built, split into groups and counted', async () => {
    const before = { ...tree(), sheet: statSync(tokensPath).mtimeMs }
    const at = mkdtempSync(join(tmpdir(), 'barkui-new-part-'))
    try {
      cpSync(join(partsDir, 'button'), join(at, 'parts', 'button'), { recursive: true })
      copyAs(join(at, 'parts', 'button'), 'copy')
      await buildShowroom({ dir: join(at, 'parts'), out: join(at, 'out'), proof: join(at, 'no-proof.json'), quiet: true })
      expect(split(partNames(join(at, 'parts'), {})).flatMap((g) => g.parts)).toEqual(['button', 'copy'])
      renderRows(readFacts())
    } finally {
      rmSync(at, { recursive: true, force: true })
    }
    expect({ ...tree(), sheet: statSync(tokensPath).mtimeMs }).toEqual(before)
  }, 30000)

  it('is told in docs/PARTS.md in full and in the README short, with the limit as it is', () => {
    const parts = flat(readFileSync(join(root, 'docs', 'PARTS.md'), 'utf8'))
    expect(parts).toContain(`Adding a part is adding a folder, up to ${MOST_PARTS} parts (\`MOST_PARTS\` in \`check/jobs.mjs\`).`)
    expect(parts).toContain('By hand, outside its folder, a part adds only a changeset')
    const readme = flat(readFileSync(join(root, 'README.md'), 'utf8'))
    expect(readme).toContain(`Up to ${MOST_PARTS} parts, a new part is its folder and a changeset`)
  })
})
