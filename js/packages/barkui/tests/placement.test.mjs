// The placement lists are in one place, check/placement.mjs, and docs/PARTS.md "Placement" prints them: these are
// red when the two differ in a name, in where it may stand (on a box, on the anchor, or on the root element or body),
// in the UI SDK control that writes it, or in transition's one value.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { ALLOWED, PLACEMENT, REASON, ROOT_REASON, SCROLL_LOCK, TRANSITION } from '../check/placement.mjs'

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
    const on = /only on a box/.test(b) ? 'box' : /only on an element whose anchor name/.test(b) ? 'anchor' : /only on the root element or body, while a dialog box is open/.test(b) ? 'root' : '?'
    const writer = b.match(/(UI SDK [^.]*)\.$/)?.[1] ?? '?'
    const value = b.match(/all five longhands `([^`]+)`/)?.[1]
    return names.map((property) => ({ property, on, writer, ...(value === undefined ? {} : { value }) }))
  })
}
/** The lists as the passage must print them: the writer without its source file. */
const listed = () => [...ALLOWED, ...SCROLL_LOCK].map(({ property, on, writer, value }) => ({ property, on, writer: writer.replace(/ \([^)]*\)$/, ''), ...(value === undefined ? {} : { value }) }))

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
    expect(text).toContain("Values are not read, except transition's and the names anchor-name gives.")
    expect(text).toContain(TRANSITION.reason.replace('; none', ', and `none`'))
  })
  it('names the UI SDK control and the source file that write each entry', () => {
    for (const e of ALLOWED) expect(e.writer, e.property).toMatch(/^UI SDK (select and menu|dialog), on the (box|trigger) \([\w/.-]+\.js( and [\w.-]+\.js)?\)$/)
    for (const e of SCROLL_LOCK) expect(e.writer, e.property).toBe('UI SDK dialog, on the root element (foundation/popups/modal.js)')
  })
  it('keeps the scroll lock apart, for the root element and body only, with its own reason', () => {
    expect(SCROLL_LOCK.map((e) => e.property)).toEqual(['overflow-x', 'overflow-y', 'scroll-behavior', 'scrollbar-gutter', '--scrollbar-width'])
    expect(SCROLL_LOCK.every((e) => e.on === 'root')).toBe(true)
    expect(ROOT_REASON).not.toBe(REASON)
    expect(PARTS().replace(/\n\s*/g, ' ')).toContain(ROOT_REASON.replace('; that is', ', which is'))
  })
  it('is red when the two differ, either way, in a name, a place, a writer or the value', () => {
    const text = PARTS()
    const plants = [
      text.replace('`--arrow-offset`: only on a box', '`--arrow-offsets`: only on a box'),
      text.replace('`--dialog-stack`, `--keyboard-inset`, `--visual-viewport-height`: only on a box. UI SDK dialog', '`--dialog-stack`, `--keyboard-inset`, `--visual-viewport-height`: only on a box. UI SDK select and menu'),
      text.replace('all five longhands `none`', 'all five longhands `all`'),
      text.replace('`scrollbar-gutter`, `--scrollbar-width`: only', '`scrollbar-gutter`: only'),
      text.replace('or body, while a dialog box is open. UI SDK dialog', 'or body, while a dialog box is open. UI SDK select and menu'),
    ]
    for (const t of plants) {
      expect(t).not.toBe(text)
      expect(passageList(t)).not.toEqual(listed())
    }
    const doc = passageList()
    const changed = [
      ALLOWED.map((e) => (e === TRANSITION ? { ...e, value: 'all' } : e)),
      ALLOWED.map((e) => (e.property === '--dialog-stack' ? { ...e, writer: 'UI SDK select and menu, on the box (x.js)' } : e)),
    ].map((list) => [...list, ...SCROLL_LOCK])
    changed.push([...ALLOWED, ...SCROLL_LOCK, { property: 'padding-right', on: 'root', writer: SCROLL_LOCK[0].writer }])
    for (const list of changed) expect(doc).not.toEqual(list.map(({ property, on, writer, value }) => ({ property, on, writer: writer.replace(/ \([^)]*\)$/, ''), ...(value === undefined ? {} : { value }) })))
  })
})
