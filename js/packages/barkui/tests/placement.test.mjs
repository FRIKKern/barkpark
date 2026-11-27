// The placement lists are in one place, check/placement.mjs, and docs/PARTS.md "Placement" prints them: these are
// red when the two differ in a name, in where it may stand (on a box, on the anchor, or on the root element or body),
// in the UI SDK control that writes it, or in the value it may hold. And --scrollbar-width, which the lock puts on the
// root element and every stage inherits, is read by no sheet the build ships and refused in part.css.
import { readdirSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { lintPartCss } from '../build/css-lint.mjs'
import { ALLOWED, PLACEMENT, REASON, ROOT_REASON, SCROLL_LOCK, SLOT_REASON, SLOTS, TRANSITION } from '../check/placement.mjs'

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

/** A slot as the passage prints it: its pieces' names in code, each write with its values and its lines (after the
    file's name where another file writes it), then the writer without its source file. */
const slotLine = (s) =>
  `- On ${s.slot.replace(/ui-[\w-]+/g, '`$&`')}: ${s.writes
    .map((w) => {
      return `\`${w.property}\` as ${w.values.map((v) => `\`${v}\``).join(' or ')} (${w.file ? `${w.file.split('/').pop()} ` : ''}${w.lines.join(', ')})`
    })
    .join(', ')}. ${s.writer.replace(/ \([^)]*\)$/, '')}.`
/** The passage's slot bullets, each on one line. */
const passageSlots = (text = PARTS()) => {
  const at = text.indexOf('\n## Placement\n')
  const passage = text.slice(at + 1, text.indexOf('\n## ', at + 1))
  return passage.split('\n- ').slice(1).filter((b) => b.startsWith('On ')).map((b) => `- ${b.split('\n\n')[0].replace(/\n\s+/g, ' ').trim()}`)
}

// Each control's pieces stand inside it, and its writer names the file that writes them.
const CONTROLS = [
  { root: 'ui-slider ', writer: 'UI SDK slider, on its pieces (components/slider/slider.js)' },
  { root: 'ui-number-input ', writer: 'UI SDK number input, on its step buttons and scrub area (components/number-input/number-input.js)' },
  { root: 'ui-tabs ', writer: 'UI SDK tabs, on its indicator (components/tabs/tabs.js)' },
  { root: 'ui-segmented-control ', writer: 'UI SDK segmented control, on its indicator (components/segmented-control/segmented-control.js)' },
]

describe("a control's pieces, the third list", () => {
  it('is the same in check/placement.mjs and in docs/PARTS.md "Placement": piece, property, value, lines and writer', () => {
    expect(passageSlots()).toEqual(SLOTS.map(slotLine))
  })
  it('keeps its own reason, holds each piece to the inside of its control, names the file and the lines that write each entry, and gives every entry its values', () => {
    expect(SLOT_REASON).not.toBe(REASON)
    expect(PARTS().replace(/\n\s*/g, ' ')).toContain(SLOT_REASON.replace('; that', ', and that'))
    for (const s of SLOTS) {
      const c = CONTROLS.find((x) => s.at.startsWith(x.root))
      expect(c, s.slot).toBeDefined()
      for (const at of s.at.split(', ')) expect(at, s.slot).toMatch(new RegExp(`^${c.root}`))
      expect(s.writer, s.slot).toBe(c.writer)
      for (const w of s.writes) {
        expect(w.lines.length && w.lines.every((n) => Number.isInteger(n)), `${s.slot} ${w.property}`).toBe(true)
        if (w.file !== undefined) expect(w.file, `${s.slot} ${w.property}`).toMatch(/^[\w/-]+\.js$/)
        // No entry takes any value: each names the values UI SDK writes.
        expect(w.values?.length > 0 && w.values.every((v) => typeof v === 'string' && v.trim() !== ''), `${s.slot} ${w.property}`).toBe(true)
      }
    }
  })
  it('holds a number input step button to the first button in its piece, the one UI SDK writes on', () => {
    const step = SLOTS.filter((s) => /ui-number-input-(increment|decrement)/.test(s.at))
    expect(step.length).toBe(1)
    expect(step[0].first).toBe(true)
    expect(step[0].slot).toMatch(/^the first button in /)
    for (const s of SLOTS) expect(s.first === undefined || s.first === true, s.slot).toBe(true)
  })
  it("holds each sliding indicator to its own six place variables, each a number of pixels, and no other piece to them", () => {
    const own = { 'ui-tabs-indicator': '--active-tab-', 'ui-segmented-control-indicator': '--segmented-control-indicator-' }
    for (const [slot, prefix] of Object.entries(own)) {
      const s = SLOTS.find((x) => x.slot === slot)
      expect(s?.writes.map((w) => w.property), slot).toEqual(['left', 'right', 'top', 'bottom', 'width', 'height'].map((side) => `${prefix}${side}`))
      for (const w of s.writes) expect(w.values, `${slot} ${w.property}`).toEqual(['{px}px'])
      for (const x of SLOTS.filter((y) => y !== s)) expect(x.writes.some((w) => w.property.startsWith(prefix)), `${x.slot} ${prefix}`).toBe(false)
    }
  })
  it('is red when the two differ, either way', () => {
    const text = PARTS()
    const plants = [text.replace('`touch-action` as `none` (179)', '`touch-action` as `auto` (179)'), text.replace('`z-index` as `1` or `2` (67)', '`z-index` as `1` or `2` (66)'), text.replace('- On `ui-slider-track`', '- On `ui-slider-tracks`'), text.replace('`--hold-delay` as `400ms` (hold.js 9)', '`--hold-delay` as `500ms` (hold.js 9)'), text.replace('`--hold-delay` as `400ms` (hold.js 9)', '`--hold-delay` as `400ms` (9)'), text.replace('`--active-tab-top` as `{px}px` (47)', '`--active-tab-top` as `{p}%` (47)'), text.replace('- On `ui-segmented-control-indicator`', '- On `ui-segmented-control-item`')]
    for (const t of plants) {
      expect(t).not.toBe(text)
      expect(passageSlots(t)).not.toEqual(SLOTS.map(slotLine))
    }
    const changed = [
      SLOTS.map((s) => (s.slot === 'ui-slider-thumb' ? { ...s, writes: [...s.writes, { property: 'color', values: ['red'], lines: [1] }] } : s)),
      SLOTS.map((s) => ({ ...s, writes: s.writes.map((w) => (w.property === 'opacity' ? { ...w, values: ['1'] } : w)) })),
      SLOTS.map((s) => (s.slot === 'ui-number-input-scrub-area' ? { ...s, writes: s.writes.map((w) => (w.property === 'touch-action' ? { ...w, values: ['manipulation'] } : w)) } : s)),
    ]
    for (const list of changed) expect(passageSlots()).not.toEqual(list.map(slotLine))
  })
})

describe('the placement list', () => {
  it('is the same in check/placement.mjs and in docs/PARTS.md "Placement": name, place, writer and value', () => {
    const doc = passageList()
    expect(doc).not.toBeNull()
    expect(doc).toEqual(listed())
  })
  it("keeps transition apart from the list, with its own reason; of the values, the check reads transition's", () => {
    expect(PLACEMENT.map((e) => e.property)).not.toContain('transition')
    expect(PLACEMENT.every((e) => e.value === undefined)).toBe(true)
    expect(TRANSITION.value).toBe('none')
    expect(TRANSITION.reason).not.toBe(REASON)
    const text = PARTS().replace(/\n\s*/g, ' ')
    expect(text).toContain("Of the values, the check reads transition's, the names anchor-name gives, and the scroll lock's (below).")
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
