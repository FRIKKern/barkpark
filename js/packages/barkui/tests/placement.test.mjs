// The placement lists are in one place, check/placement.mjs, and docs/PARTS.md "Placement" prints them: these are
// red when the two differ in a name, in where it may stand (on a box, on the anchor, or on the root element or body),
// in the UI SDK control that writes it, or in the value it may hold. And --scrollbar-width, which the lock puts on the
// root element and every stage inherits, is read by no sheet the build ships and refused in part.css.
import { readdirSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { lintPartCss } from '../build/css-lint.mjs'
import { ALLOWED, PLACEMENT, REASON, ROOT_REASON, SCROLL_LOCK, TRANSITION } from '../check/placement.mjs'

const PARTS = () => readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8')

/** The passage's lists: each bullet's leading names, with where it says they may stand, the control it says writes
    them, and the one value, or kind of value, it gives, if any. */
function passageList(text = PARTS()) {
  const at = text.indexOf('\n## Placement\n')
  if (at < 0) return null
  const passage = text.slice(at + 1, text.indexOf('\n## ', at + 1))
  const bullets = passage.split('\n- ').slice(1).map((b) => b.split('\n\n')[0].replace(/\n\s+/g, ' ').trim())
  return bullets.flatMap((b) => {
    const names = b.match(/^((?:`[^`]+`(?:, )?)+)/)?.[1].match(/`[^`]+`/g).map((n) => n.slice(1, -1)) ?? []
    const on = /only on a box/.test(b) ? 'box' : /only on an element whose anchor name/.test(b) ? 'anchor' : /only on the root element or body, while a dialog box is open/.test(b) ? 'root' : '?'
    const writer = b.match(/(UI SDK [^.]*)\.$/)?.[1] ?? '?'
    const value = b.match(/all five longhands `([^`]+)`|only as `([^`]+)`/)?.slice(1).find((v) => v !== undefined)
    const length = b.match(/only as a `([^`]+)` length/)?.[1]
    return names.map((property) => ({ property, on, writer, ...(value === undefined ? {} : { value }), ...(length === undefined ? {} : { length }) }))
  })
}
/** The lists as the passage must print them: the writer without its source file. */
const shown = (list) => list.map(({ property, on, writer, value, length }) => ({ property, on, writer: writer.replace(/ \([^)]*\)$/, ''), ...(value === undefined ? {} : { value }), ...(length === undefined ? {} : { length }) }))
const listed = () => shown([...ALLOWED, ...SCROLL_LOCK])

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
    expect(text).toContain("Values are not read, except transition's, the names anchor-name gives, and the scroll lock's (below).")
    expect(text).toContain(TRANSITION.reason.replace('; none', ', and `none`'))
  })
  it('names the UI SDK control and the source file that write each entry', () => {
    for (const e of ALLOWED) expect(e.writer, e.property).toMatch(/^UI SDK (select and menu|dialog), on the (box|trigger) \([\w/.-]+\.js( and [\w.-]+\.js)?\)$/)
    for (const e of SCROLL_LOCK) expect(e.writer, e.property).toBe('UI SDK dialog, on the root element (foundation/popups/modal.js)')
  })
  it('keeps the scroll lock apart, for the root element and body only, with its own reason', () => {
    expect(SCROLL_LOCK.map(({ property, value, length }) => [property, value ?? `a ${length} length`])).toEqual([
      ['overflow-x', 'hidden'],
      ['overflow-y', 'hidden'],
      ['scroll-behavior', 'auto'],
      ['scrollbar-gutter', 'stable'],
      ['--scrollbar-width', 'a px length'],
    ])
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
      text.replace('- `--scrollbar-width`: only', '- `--scrollbar-widths`: only'),
      text.replace('`scroll-behavior`: only as `auto`', '`scroll-behavior`: only as `smooth`'),
      text.replace('only as a `px` length', 'only as a `em` length'),
      text.replace('`overflow-x`, `overflow-y`: only as `hidden`, only on the root element or body, while a dialog box is open. UI SDK\n  dialog', '`overflow-x`, `overflow-y`: only as `hidden`, only on the root element or body, while a dialog box is open. UI SDK\n  select and menu'),
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
    changed.push(
      [...ALLOWED, ...SCROLL_LOCK, { property: 'padding-right', on: 'root', writer: SCROLL_LOCK[0].writer }],
      [...ALLOWED, ...SCROLL_LOCK.map((e) => (e.property === 'scrollbar-gutter' ? { ...e, value: 'auto' } : e))],
      [...ALLOWED, ...SCROLL_LOCK.map((e) => (e.length ? { ...e, length: 'em' } : e))],
    )
    for (const list of changed) expect(doc).not.toEqual(shown(list))
  })
})

/** Every sheet the build puts in the page (build/showroom.mjs): UI SDK's web.css, base.css, showroom.css and each
    part.css. */
function shippedSheets() {
  const pkg = new URL('..', import.meta.url).pathname
  const web = join(dirname(createRequire(import.meta.url).resolve('@ui-sdk/web/package.json')), 'browser', 'web.css')
  const parts = readdirSync(join(pkg, 'parts'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => join(pkg, 'parts', d.name, 'part.css'))
  return [web, join(pkg, 'css', 'base.css'), join(pkg, 'build', 'showroom.css'), ...parts].map((f) => [f, readFileSync(f, 'utf8')])
}

describe('--scrollbar-width, which the scroll lock puts on the root element and every stage inherits', () => {
  it('is read by no sheet the build ships', () => {
    const sheets = shippedSheets()
    expect(sheets.length).toBeGreaterThan(3)
    for (const [file, css] of sheets) expect(css.includes('--scrollbar-width'), file).toBe(false)
  })
  it('is refused in part.css, however it is read', () => {
    for (const rule of ['.x { padding-right: var(--scrollbar-width); }', '.x { width: calc(1px + var( --scrollbar-width )); }', '.x { --bark-gap: var(--scrollbar-width); }'])
      expect(lintPartCss(rule).some((f) => f.includes('reads --scrollbar-width')), rule).toBe(true)
  })
})
