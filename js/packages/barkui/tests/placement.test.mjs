// The placement list is in one place, check/placement.mjs, and docs/PARTS.md "Placement" prints it: these are red
// when the two differ in a name, in where it may stand (on a box, or on the anchor), in the UI SDK control that
// writes it, or in transition's one value.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { ALLOWED, PLACEMENT, REASON, TRANSITION } from '../check/placement.mjs'

const PARTS = () => readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8')

/** The passage's list: each bullet's leading names, with where it says they may stand, the control it says writes
    them, and the one value it gives, if any. */
function passageList(text = PARTS()) {
  const at = text.indexOf('\n## Placement\n')
  if (at < 0) return null
  const passage = text.slice(at + 1, text.indexOf('\n## ', at + 1))
  const bullets = passage.split('\n- ').slice(1).map((b) => b.split('\n\n')[0].replace(/\n\s+/g, ' ').trim())
  return bullets.flatMap((b) => {
    const names = b.match(/^((?:`[^`]+`(?:, )?)+)/)?.[1].match(/`[^`]+`/g).map((n) => n.slice(1, -1)) ?? []
    const on = /only on a box/.test(b) ? 'box' : /only on an element whose anchor name/.test(b) ? 'anchor' : '?'
    const writer = b.match(/(UI SDK [^.]*)\.$/)?.[1] ?? '?'
    const value = b.match(/all five longhands `([^`]+)`/)?.[1]
    return names.map((property) => ({ property, on, writer, ...(value === undefined ? {} : { value }) }))
  })
}
/** The list as the passage must print it: the writer without its source file. */
const listed = () => ALLOWED.map(({ property, on, writer, value }) => ({ property, on, writer: writer.replace(/ \([^)]*\)$/, ''), ...(value === undefined ? {} : { value }) }))

describe('the placement list', () => {
  it('is the same in check/placement.mjs and in docs/PARTS.md "Placement": name, place, writer and value', () => {
    const doc = passageList()
    expect(doc).not.toBeNull()
    expect(doc).toEqual(listed())
  })
  it('keeps transition apart from the list, with its own reason, as the one entry whose value is read', () => {
    expect(PLACEMENT.map((e) => e.property)).not.toContain('transition')
    expect(PLACEMENT.every((e) => e.value === undefined)).toBe(true)
    expect(TRANSITION.value).toBe('none')
    expect(TRANSITION.reason).not.toBe(REASON)
    const text = PARTS().replace(/\n\s*/g, ' ')
    expect(text).toContain("Values are not read, except transition's.")
    expect(text).toContain(TRANSITION.reason.replace('; none', ', and `none`'))
  })
  it('names the UI SDK control and the source file that write each entry', () => {
    for (const e of ALLOWED) expect(e.writer, e.property).toMatch(/^UI SDK (select and menu|dialog), on the (box|trigger) \([\w/.-]+\.js( and [\w.-]+\.js)?\)$/)
  })
  it('is red when the two differ, either way, in a name, a place, a writer or the value', () => {
    const text = PARTS()
    const plants = [
      text.replace('`--arrow-offset`: only on a box', '`--arrow-offsets`: only on a box'),
      text.replace('`--dialog-stack`, `--keyboard-inset`, `--visual-viewport-height`: only on a box. UI SDK dialog', '`--dialog-stack`, `--keyboard-inset`, `--visual-viewport-height`: only on a box. UI SDK select and menu'),
      text.replace('all five longhands `none`', 'all five longhands `all`'),
    ]
    for (const t of plants) {
      expect(t).not.toBe(text)
      expect(passageList(t)).not.toEqual(listed())
    }
    const doc = passageList()
    const changed = [
      ALLOWED.map((e) => (e === TRANSITION ? { ...e, value: 'all' } : e)),
      ALLOWED.map((e) => (e.property === '--dialog-stack' ? { ...e, writer: 'UI SDK select and menu, on the box (x.js)' } : e)),
    ]
    for (const list of changed) expect(doc).not.toEqual(list.map(({ property, on, writer, value }) => ({ property, on, writer: writer.replace(/ \([^)]*\)$/, ''), ...(value === undefined ? {} : { value }) })))
  })
})
