import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { END, pinText, readFacts, readmePath, readStatus, renderRows, renderStatus, START } from '../build/status.mjs'

const facts = { skins: ['a', 'b'], surfaces: ['base'], ui: 3, bark: 4, core: '1.0.0', web: '1.0.0' }
const page = (block) => `x\n${START}\n${block}\n${END}\n`

describe('status block', () => {
  it('README carries a block the script wrote, untouched by hand (run node build/status.mjs when this fails)', () => {
    expect(readStatus(readFileSync(readmePath, 'utf8'))).not.toHaveProperty('why')
  })

  it('keeps its shape (a change here must change the block in README too)', () => {
    expect(renderStatus(facts, '2026-01-02')).toBe(
      [
        '| What | Read from the files |',
        '|---|---|',
        '| Skins in the sheet | 2: a, b |',
        '| Surfaces a part can sit on | 1: base |',
        '| Colour names in the sheet | 3 `--ui-*` (UI SDK\'s), 4 `--bark-*` (BarkUI\'s own) |',
        '| UI SDK | `@ui-sdk/core` and `@ui-sdk/web` 1.0.0, pinned to that exact version |',
        '',
        'Read from the sheet and package.json; last changed on 2026-01-02.',
        '<!-- stamp: 0153accd1779acc4 -->',
      ].join('\n'),
    )
  })

  it('catches a number typed by hand and a block in another shape', () => {
    const good = renderStatus(facts, '2026-01-02')
    expect(readStatus(page(good)).rows).toEqual(renderRows(facts))
    expect(readStatus(page(good.replace('2: a, b', '3: a, b, c'))).why).toMatch(/by hand/)
    expect(readStatus(page(good.split('\n').slice(0, -1).join('\n'))).why).toMatch(/no stamp/)
    expect(readStatus('no block').why).toMatch(/exactly one/)
  })

  it('never counts parts, so adding a part folder changes no other file', () => {
    expect(Object.keys(readFacts()).sort()).toEqual(['bark', 'core', 'skins', 'surfaces', 'ui', 'web'])
  })

  it('says pinned only when package.json holds one exact version for both packages', () => {
    expect(pinText({ core: '0.1.0-beta.10', web: '0.1.0-beta.10' })).toMatch(/pinned to that exact version/)
    expect(pinText({ core: '^0.1.0', web: '^0.1.0' })).toMatch(/not pinned/)
    expect(pinText({ core: '0.1.0', web: '0.2.0' })).toMatch(/two different exact versions/)
  })
})
