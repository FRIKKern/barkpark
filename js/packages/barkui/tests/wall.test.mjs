// The browser library is loaded only for check/acts.mjs, held by the run itself (check/load-wall.mjs): any other file
// that asks for it is refused by name before the library loads, and a run that did not start with the load wall
// cannot start a browser.
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { refusedLoad } from '../check/load-wall.mjs'
import { throughWall, WallRefusal } from '../check/acts.mjs'
import { PLAIN } from '../check/wall.mjs'

const PKG = fileURLToPath(new URL('..', import.meta.url))
const at = (f) => new URL(`../check/${f}`, import.meta.url).href
const run = (code, wall = true) =>
  spawnSync(process.execPath, [...(wall ? ['--import', './check/load-wall.mjs'] : []), '--input-type=module', '-e', code], { cwd: PKG, encoding: 'utf8' })

describe('the load wall', () => {
  it('lets check/acts.mjs and the library itself load the library, and no other file', () => {
    expect(refusedLoad('playwright', at('acts.mjs'))).toBeNull()
    expect(refusedLoad('playwright-core/lib/server', 'file:///x/node_modules/.pnpm/playwright@1/node_modules/playwright/index.js')).toBeNull()
    expect(refusedLoad('node:fs', at('selftest.mjs'))).toBeNull()
    expect(refusedLoad('playwright', at('selftest.mjs'))).toMatch(/^the browser library is loaded only by check\/acts\.mjs: .*check\/selftest\.mjs asks for playwright$/)
    expect(refusedLoad('playwright-core', at('proofs.mjs'))).toMatch(/asks for playwright-core$/)
    expect(refusedLoad('playwright', undefined)).toMatch(/^the browser library is loaded only by check\/acts\.mjs: undefined asks for playwright$/)
  })

  it('refuses the library in a run, by name, before it loads', () => {
    const got = run("await import('playwright')")
    expect(got.status).not.toBe(0)
    expect(got.stderr).toMatch(/the browser library is loaded only by check\/acts\.mjs: .* asks for playwright/)
    expect(run("await import('playwright'); console.log('loaded')", false).stdout.trim()).toBe('loaded')
  })

  it('lets no browser start in a run without it', () => {
    const got = run("const { launch } = await import('./check/acts.mjs'); await launch()", false)
    expect(got.status).not.toBe(0)
    expect(got.stderr).toMatch(/the check starts with its load wall: node --import \.\/check\/load-wall\.mjs <script>/)
  })
})

describe('the wall, by default', () => {
  class Gadget {
    poke() {}
  }
  const refused = (f) => expect(f).toThrow(WallRefusal)

  it('walls a value of a kind it does not know, wherever it sits', async () => {
    refused(() => throughWall(new Gadget()).poke)
    refused(() => throughWall({ a: [{ b: new Gadget() }] }).a[0].b.poke)
    refused(() => throughWall(new Map([[1, new Gadget()]])).get)
    refused(() => throughWall(() => 1)())
    refused(() => throughWall(Object.assign(new Error('x'), { held: new Gadget() })).held)
    refused(() => throughWall(Object.create(Gadget.prototype)).poke)
    await expect(throughWall(Promise.resolve(new Gadget())).then((g) => g.poke)).rejects.toThrow(WallRefusal)
    await expect(throughWall(Promise.reject(new Gadget())).catch((g) => g.poke)).rejects.toThrow(WallRefusal)
  })

  it('hands on as it is only the plain kinds of one closed list', () => {
    expect(PLAIN).toEqual(['Object', 'Array', 'Buffer', 'Uint8Array', 'ArrayBuffer', 'Date', 'RegExp', 'Error'])
    const samples = [{ a: 1 }, [1], Buffer.from('x'), new Uint8Array(1), new ArrayBuffer(1), new Date(0), /x/, new Error('x')]
    for (const v of samples) expect(throughWall(v)).toBe(v)
    for (const v of [1, 'x', true, null, undefined, 1n, Symbol.for('x')]) expect(throughWall(v)).toBe(v)
  })
})
