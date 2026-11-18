import { cpSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { discoverParts, REQUIRED_FILES } from '../build/parts.mjs'

const realParts = join(import.meta.dirname, '..', 'parts')
let dirs = []
const scratch = () => {
  const d = mkdtempSync(join(tmpdir(), 'barkui-parts-'))
  dirs.push(d)
  return d
}
afterEach(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
  dirs = []
})

// A folder that is a valid part, written from nothing but its own files.
function plantPart(root, name, skip = []) {
  const dir = join(root, name)
  cpSync(join(realParts, 'button'), dir, { recursive: true })
  writeFileSync(
    join(dir, 'part.json'),
    JSON.stringify({ name, family: 'test', element: 'ui-button', imports: ['@ui-sdk/web/button'], summary: 'A planted part.' }),
  )
  for (const f of skip) rmSync(join(dir, f))
  return dir
}

describe('discoverParts', () => {
  it('finds every part folder in the real tree, button among them', () => {
    const names = discoverParts(realParts).map((p) => p.name)
    expect(names).toContain('button')
    expect(names).toEqual(readdirSync(realParts, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name).sort())
  })

  it('finds a new folder with no edit anywhere else', () => {
    const root = scratch()
    cpSync(realParts, root, { recursive: true })
    const before = discoverParts(root).map((p) => p.name)
    plantPart(root, 'zz-planted')
    const after = discoverParts(root).map((p) => p.name)
    expect(after).toEqual([...before, 'zz-planted'])
    const planted = discoverParts(root).find((p) => p.name === 'zz-planted')
    expect(planted.example).toContain('ui-button')
    expect(planted.json.summary).toBe('A planted part.')
  })

  for (const missing of REQUIRED_FILES) {
    it(`refuses a folder with no ${missing}, naming the folder and the file`, () => {
      const root = scratch()
      plantPart(root, 'half-done', [missing])
      expect(() => discoverParts(root)).toThrow(new RegExp(`half-done.*${missing.replace('.', '\\.')}`))
    })
  }

  it('refuses a part.json whose name is not its folder', () => {
    const root = scratch()
    const dir = plantPart(root, 'one')
    writeFileSync(join(dir, 'part.json'), JSON.stringify({ name: 'two', family: 'x', element: 'ui-button', imports: [], summary: 's' }))
    expect(() => discoverParts(root)).toThrow(/one.*part\.json.*"two"/)
  })

  it('gives each part a content hash that moves when any of its files moves', () => {
    const root = scratch()
    const dir = plantPart(root, 'hashed')
    const a = discoverParts(root)[0].hash
    writeFileSync(join(dir, 'example.html'), '<p>changed</p>')
    expect(discoverParts(root)[0].hash).not.toBe(a)
  })
})
