// What a new part changes outside its folder, as docs/PARTS.md says it: nothing a
// script writes, and by hand only a changeset, up to MOST_PARTS parts.
import { createHash } from 'node:crypto'
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { describe, expect, it } from 'vitest'
import { copyAs } from '../check/copy.mjs'
import { MOST_PARTS, partNames, split } from '../check/jobs.mjs'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom, root, tokensPath } from '../build/showroom.mjs'
import { readFacts, renderRows } from '../build/status.mjs'

const SKIP = new Set(['node_modules', 'dist', 'parts', '.turbo'])
/** Every file of the package outside parts/ (and what is never tracked), plus the sheet, as path -> hash. A link is
    read through, so a worktree whose node_modules is a link to another one's reads the same as one with a real
    folder. */
function tree(dir = root, out = {}, from = root) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(e.name)) continue
    const p = join(dir, e.name)
    if (statSync(p).isDirectory()) tree(p, out, from)
    else out[relative(from, p)] = createHash('sha256').update(readFileSync(p)).digest('hex')
  }
  return out
}
const flat = (s) => s.replace(/\s+/g, ' ')

describe('a new part', () => {
  it('reads the package the same whether node_modules and other folders are real or links', () => {
    const at = mkdtempSync(join(tmpdir(), 'barkui-tree-'))
    try {
      const make = (d, files) => Object.entries(files).forEach(([f, body]) => (mkdirSync(join(d, f, '..'), { recursive: true }), writeFileSync(join(d, f), body)))
      make(join(at, 'real'), { 'a.mjs': 'a', 'docs/b.md': 'b', 'node_modules/x/index.js': 'x', 'parts/p/part.css': 'p' })
      make(join(at, 'away'), { 'node_modules/x/index.js': 'x', 'docs/b.md': 'b' })
      make(join(at, 'linked'), { 'a.mjs': 'a', 'parts/p/part.css': 'p' })
      symlinkSync(join(at, 'away', 'node_modules'), join(at, 'linked', 'node_modules'))
      symlinkSync(join(at, 'away', 'docs'), join(at, 'linked', 'docs'))
      const real = tree(join(at, 'real'), {}, join(at, 'real'))
      expect(real).toEqual(tree(join(at, 'linked'), {}, join(at, 'linked')))
      expect(Object.keys(real).sort()).toEqual(['a.mjs', join('docs', 'b.md')])
    } finally {
      rmSync(at, { recursive: true, force: true })
    }
  })

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
