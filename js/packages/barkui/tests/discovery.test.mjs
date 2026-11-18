import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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
function plantPart(root, name, skip = [], example) {
  const dir = join(root, name)
  cpSync(join(realParts, 'button'), dir, { recursive: true })
  // The button's ids, moved under this part's own prefix.
  const html = readFileSync(join(dir, 'example.html'), 'utf8').replaceAll('id="button-', `id="${name}-`)
  writeFileSync(join(dir, 'example.html'), example ?? html)
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

  it('refuses an example id outside the part\'s own prefix', () => {
    const root = scratch()
    plantPart(root, 'aa', [], '<ui-button><button id="save" data-slot="button">Save</button></ui-button>')
    expect(() => discoverParts(root)).toThrow(/parts\/aa: example\.html id "save" must start with "aa-"/)
  })

  it('refuses two parts that print the same id', () => {
    const root = scratch()
    plantPart(root, 'aa', [], '<ui-button><button id="aa-x-1" data-slot="button">One</button></ui-button>')
    plantPart(root, 'aa-x', [], '<ui-button><button id="aa-x-1" data-slot="button">Two</button></ui-button>')
    expect(() => discoverParts(root)).toThrow(/id "aa-x-1" is printed by both parts\/aa and parts\/aa-x/)
  })

  it('refuses a demo.mjs that is not one function of its part\'s root', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    writeFileSync(join(dir, 'demo.mjs'), "for (const el of document.querySelectorAll('ui-button')) el.remove()\n")
    expect(() => discoverParts(root)).toThrow(/parts\/aa: demo\.mjs must `export default function \(root\)`/)
  })

  for (const [what, line] of [
    ['a <style> element', '<style>button { background-image: linear-gradient(red, red) }</style>'],
    ['a style= attribute', '<ui-button><button id="aa-x" data-slot="button" style="background: #fff">X</button></ui-button>'],
    ['an on*= handler', '<ui-button><button id="aa-x" data-slot="button" onclick="go()">X</button></ui-button>'],
    ['a <script> element', '<script>document.body.remove()</script>'],
  ]) {
    it(`refuses an example.html with ${what}, naming the file and line`, () => {
      const root = scratch()
      plantPart(root, 'aa', [], `<p>fine</p>\n${line}\n`)
      expect(() => discoverParts(root)).toThrow(/parts\/aa\/example\.html line 2: /)
    })
  }
})
