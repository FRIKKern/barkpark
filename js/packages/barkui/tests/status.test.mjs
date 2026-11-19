import { describe, expect, it } from 'vitest'
import { applyBlock, END, readFacts, renderBlocks, stalePages, START } from '../build/status.mjs'

const facts = { parts: [{ name: 'button', family: 'action' }], skins: ['a', 'b'], surfaces: ['base'], ui: 3, bark: 4, uiSdk: '1.0.0' }

describe('status blocks', () => {
  it('README and ROADMAP carry the numbers the files hold (run node build/status.mjs when this fails)', () => {
    expect(stalePages()).toEqual([])
  })

  it('every number comes from the files: a new part folder or skin moves the block', () => {
    const real = readFacts()
    const more = { ...real, parts: [...real.parts, { name: 'zz-new', family: 'zz' }], skins: [...real.skins, 'zz-skin'] }
    const before = renderBlocks(real)
    const after = renderBlocks(more)
    expect(after['README.md']).not.toBe(before['README.md'])
    expect(after['README.md']).toContain('zz-new')
    expect(after['README.md']).toContain('zz-skin')
    expect(after['docs/ROADMAP.md']).toContain('| zz | zz-new |')
  })

  it('catches a block typed by hand', () => {
    const block = renderBlocks(facts)['README.md']
    const page = `# x\n${START}\n${block}\n${END}\ntail\n`
    expect(applyBlock(page, block)).toBe(page)
    const typed = page.replace('1: button', '2: button, menu')
    expect(applyBlock(typed, block)).toBe(page)
  })

  it('refuses a page without exactly one marker pair', () => {
    expect(() => applyBlock('no markers', 'x')).toThrow(/exactly one/)
    expect(() => applyBlock(`${START}${END}${START}${END}`, 'x')).toThrow(/exactly one/)
    expect(() => applyBlock(`${END}${START}`, 'x')).toThrow(/exactly one/)
  })
})
