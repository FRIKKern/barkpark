// The placement list is in one place, check/placement.mjs, and docs/PARTS.md "Placement" prints it: these are red
// when the two name different properties, or put one in a different place (on a box, or on the anchor).
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { ALLOWED, PLACEMENT, REASON, TRANSITION } from '../check/placement.mjs'

/** The passage's list: each bullet's leading names, with where it says they may stand. */
function passageList(text = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8')) {
  const at = text.indexOf('\n## Placement\n')
  if (at < 0) return null
  const passage = text.slice(at + 1, text.indexOf('\n## ', at + 1))
  const bullets = passage.split('\n- ').slice(1).map((b) => b.replace(/\n\s+/g, ' '))
  return bullets.flatMap((b) => {
    const names = b.match(/^((?:`[^`]+`(?:, )?)+)/)?.[1].match(/`[^`]+`/g).map((n) => n.slice(1, -1)) ?? []
    const on = /only on a box/.test(b) ? 'box' : /only on an element whose anchor name/.test(b) ? 'anchor' : '?'
    return names.map((property) => ({ property, on }))
  })
}

describe('the placement list', () => {
  it('is the same in check/placement.mjs and in docs/PARTS.md "Placement", name for name and place for place', () => {
    const doc = passageList()
    expect(doc).not.toBeNull()
    expect(doc).toEqual(ALLOWED.map(({ property, on }) => ({ property, on })))
  })
  it('keeps transition apart from the list, with its own reason, as the one entry whose value is read', () => {
    expect(PLACEMENT.map((e) => e.property)).not.toContain('transition')
    expect(PLACEMENT.every((e) => e.value === undefined)).toBe(true)
    expect(TRANSITION.value).toBe('none')
    expect(TRANSITION.reason).not.toBe(REASON)
    const text = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8').replace(/\n\s*/g, ' ')
    expect(text).toContain('Values are not read, except transition\'s.')
    expect(text).toContain(TRANSITION.reason.replace('; none', ', and `none`'))
  })
  it('names the UI SDK control that writes each entry', () => {
    for (const e of ALLOWED) expect(e.writer, e.property).toMatch(/^UI SDK (select and menu|dialog)\b/)
  })
  it('is red when the passage names an entry differently', () => {
    const text = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8').replace('`--arrow-offset`: only on a box', '`--arrow-offsets`: only on a box')
    expect(passageList(text)).not.toEqual(ALLOWED.map(({ property, on }) => ({ property, on })))
  })
})
