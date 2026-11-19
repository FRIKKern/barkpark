// Real states, per pair. For every rule of the part that holds a state (:hover, :active) and every live control
// that matches the rest of its selector (the state taken out, as element.matches says; outside the inert rows,
// not a pinned row), the check produces that state on that control with the browser's own input: the pointer at
// its centre for hover, held down there for active (a real press is both). While it holds:
// - the stage is read as drawn (reading.mjs), and that reading records what applies (coverage.mjs);
// - every computed property of the control and its ::before and ::after must change exactly as some pinned row
//   with the same data-pin changes when its pin is taken off, so a pinned row, read in every skin, scheme,
//   surface and width, shows this change too; the machine picks the row, by comparing;
// - nothing from the control up to the stage may change (no pin shows a host or an ancestor).
// One skin, light, base surface, 1440px.
import { waitsFor } from '../build/sheet-waits.mjs'
import { readView, verdict } from './reading.mjs'

// Values resolved against the box's own size: a state may change them, but a longer label changes them too, so
// only whether they change is compared.
const SIZED = ['width', 'height', 'inline-size', 'block-size', 'transform-origin', 'perspective-origin']
const MODES = { hover: 'hover', active: 'hover active' }

/** Runs in the check's world: the pinned rows, and the (rule, live control) pairs a state must be driven for. */
function plan([n, entries]) {
  const h = window.__barkCheck
  const root = document.querySelector(`[data-part="${n}"]`)
  const els = [root, ...root.querySelectorAll('*')]
  const pins = els.flatMap((el, i) => (el.hasAttribute('data-pin') ? [{ el: i, states: el.getAttribute('data-pin').split(/\s+/).filter(Boolean).sort().join(' '), at: h.describe(el) }] : []))
  const pairs = []
  entries.forEach((e, rule) => {
    if (!e.states.length) return
    els.forEach((el, i) => {
      if (i && !el.closest('[inert]') && !el.hasAttribute('data-pin') && el.matches(e.rest)) pairs.push({ rule, el: i, at: h.describe(el), states: e.states })
    })
  })
  return { pins, pairs }
}

/** Runs in the check's world: computed styles of one stage element, its ::before and ::after, and its ancestors up
    to the stage. `unpin`: read it with data-pin taken off (then put back). */
function snap([n, i, unpin]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const el = [root, ...root.querySelectorAll('*')][i]
  const read = (s) => Object.fromEntries([...s].map((p) => [p, s.getPropertyValue(p)]))
  const pin = el.getAttribute('data-pin')
  // Taking the pin off starts the control's transitions; run them to their end, as the reading after a real state
  // waits for them, so the values read are where the state lands.
  const land = () => {
    getComputedStyle(el).color
    for (const a of el.getAnimations({ subtree: true })) if (a instanceof CSSTransition) a.finish()
  }
  if (unpin) {
    el.removeAttribute('data-pin')
    land()
  }
  try {
    const up = []
    for (let x = el.parentElement; x && root.contains(x); x = x.parentElement) up.push({ at: window.__barkCheck.describe(x), style: read(getComputedStyle(x)) })
    return { self: read(getComputedStyle(el)), before: read(getComputedStyle(el, '::before')), after: read(getComputedStyle(el, '::after')), up }
  } finally {
    if (unpin) {
      el.setAttribute('data-pin', pin)
      land()
    }
  }
}

const change = (from, to) => Object.fromEntries(Object.keys(to).filter((p) => from[p] !== to[p]).map((p) => [p, to[p]]))
const PARTS = ['self', 'before', 'after']
const changes = (from, to) => Object.fromEntries(PARTS.map((k) => [k, change(from[k], to[k])]))
/** Where two changes differ, in words: one line per property, `real` against the pin's. */
function differ(real, pin) {
  const out = []
  for (const k of PARTS) {
    const of = k === 'self' ? '' : `::${k} `
    for (const prop of new Set([...Object.keys(real[k]), ...Object.keys(pin[k])])) {
      const same = SIZED.includes(prop) ? prop in real[k] === prop in pin[k] : real[k][prop] === pin[k][prop]
      if (!same) out.push(`${of}${prop} ${prop in real[k] ? `becomes ${real[k][prop]}` : 'stays as it was'} where the pin ${prop in pin[k] ? `shows ${pin[k][prop]}` : 'leaves it as it was'}`)
    }
  }
  return out
}

/** Every way a real state differs from what the lights read, in plain words; `pairs` gets the pairs it drove. */
export async function realStates(page, part, { skin, settle, title, entries, pairs }) {
  const fails = []
  const where = 'base'
  const waits = waitsFor(skin, 'light', where)
  const rest = async () => {
    await page.mouse.move(0, 0)
    await page.barkCheck((id) => document.getElementById(id).focus(), title)
    await settle(page)
  }
  await rest()
  const { pins, pairs: todo } = await page.barkCheck(plan, [part.name, entries])
  pairs.push(...todo)
  for (const p of pins) p.change = changes(await page.barkCheck(snap, [part.name, p.el, true]), await page.barkCheck(snap, [part.name, p.el, false]))
  // Each control once per mode its rules give it.
  const drives = new Map()
  for (const p of todo) for (const s of p.states) drives.set(`${p.el} ${MODES[s]}`, { el: p.el, at: p.at, mode: MODES[s] })
  for (const { el, at, mode } of drives.values()) {
    const said = `real ${mode.replace(' ', ' and ')} on ${at}`
    await rest()
    const before = await page.barkCheck(snap, [part.name, el, false])
    let down = false
    try {
      const to = await page.barkCheck(([n, k]) => {
        const root = document.querySelector(`[data-part="${n}"]`)
        const x = [root, ...root.querySelectorAll('*')][k]
        x.scrollIntoView({ block: 'center', inline: 'center' })
        const r = x.getBoundingClientRect()
        const [cx, cy] = [r.left + r.width / 2, r.top + r.height / 2]
        const top = document.elementFromPoint(cx, cy)
        return x === top || x.contains(top) ? { x: cx, y: cy } : { miss: `${window.__barkCheck.describe(top)} is on top at its centre` }
      }, [part.name, el])
      if (to.miss) {
        fails.push(`${said}: the pointer cannot reach it: ${to.miss}`)
        continue
      }
      await page.mouse.move(to.x, to.y)
      if (mode.includes('active')) {
        await page.mouse.down()
        down = true
      }
      await settle(page)
      const now = await page.barkCheck(snap, [part.name, el, false])
      const real = changes(before, now)
      const same = pins.filter((p) => p.states === mode.split(' ').sort().join(' '))
      if (!same.length) fails.push(`${said}: no pinned row shows data-pin="${mode}", so no other view reads this state`)
      else if (!same.some((p) => !differ(real, p.change).length)) {
        const near = same.map((p) => ({ p, d: differ(real, p.change) })).sort((a, b) => a.d.length - b.d.length)[0]
        fails.push(`${said}: ${near.d[0]} (nearest pinned row ${near.p.at}); no pinned row shows this change, so no other view reads it`)
      }
      now.up.forEach((u, i) => {
        const moved = change(before.up[i].style, u.style)
        const prop = Object.keys(moved)[0]
        if (prop) fails.push(`${said}: ${u.at} ${prop} becomes ${moved[prop]}; a state may change nothing above the control, where no pin shows it`)
      })
      // Text-only is a fact about a control at rest (README), read in every view with its pin let go; here the
      // control is not at rest, so that one reading is left to the views.
      const v = await readView(page, part, waits)
      fails.push(...verdict({ ...v, bounds: { ...v.bounds, misnamed: [] } }, `${said}, ${skin} light on ${where}: `, waits).fails)
    } finally {
      await page.mouse.move(0, 0)
      if (down) await page.mouse.up()
    }
  }
  await rest()
  return fails
}
