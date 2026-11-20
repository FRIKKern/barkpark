// Real states, per pair. For every rule of the part that holds a state (:hover, :active) and every live control
// that matches the rest of its selector (the state taken out, as element.matches says; outside the inert rows,
// not a pinned row), the check produces that state on that control with the browser's own input: the pointer at
// its centre for hover, held down there for active (a real press is both). While it holds:
// - every computed property of the control, its ::before and ::after and everything inside it must be what the
//   same control shows with that state pinned (data-pin), and nothing from the control up to the stage may change
//   (no pin shows a host or an ancestor): so the control pinned is the control in that state;
// - the control's change must be exactly the change of some pinned row with the same data-pin, so a pinned row,
//   read in every skin, scheme, surface and width, shows this change too; the machine picks the row, by comparing.
// Then, per state, every live control is pinned at once and the stage is read as drawn (reading.mjs), in light and
// in dark: a value that computes alike in light can draw otherwise in dark. That reading records what applies
// (coverage.mjs), so each pair is judged as drawn while its rule applies. Two readings per state instead of one
// per control: a reading costs about a second, a driven control a few frames.
// The states are driven in one skin, light, base surface, 1440px.
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

/** Runs in the check's world: sets data-pin on stage elements (`pin` a value, or null to take it off), running
    the transitions this starts to their end, as a reading after a real state waits for them. */
function setPins([n, list, pin]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const els = [root, ...root.querySelectorAll('*')]
  for (const i of list) {
    if (pin === null) els[i].removeAttribute('data-pin')
    else els[i].setAttribute('data-pin', pin)
  }
  for (const i of list) {
    getComputedStyle(els[i]).color
    for (const a of els[i].getAnimations({ subtree: true })) if (a instanceof CSSTransition) a.finish()
  }
}

/** Runs in the check's world: computed styles of one stage element, its ::before and ::after, everything inside it
    and its ancestors up to the stage. `pin`: read it with data-pin set to that (null: taken off), then put back. */
function snap([n, i, pin]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const el = [root, ...root.querySelectorAll('*')][i]
  const read = (s) => Object.fromEntries([...s].map((p) => [p, s.getPropertyValue(p)]))
  const was = el.getAttribute('data-pin')
  const land = () => {
    getComputedStyle(el).color
    for (const a of el.getAnimations({ subtree: true })) if (a instanceof CSSTransition) a.finish()
  }
  if (pin !== undefined) {
    if (pin === null) el.removeAttribute('data-pin')
    else el.setAttribute('data-pin', pin)
    land()
  }
  try {
    const h = window.__barkCheck
    const up = []
    for (let x = el.parentElement; x && root.contains(x); x = x.parentElement) up.push({ at: h.describe(x), style: read(getComputedStyle(x)) })
    const down = [...el.querySelectorAll('*')].map((x) => ({ at: h.describe(x), style: read(getComputedStyle(x)) }))
    return { self: read(getComputedStyle(el)), before: read(getComputedStyle(el, '::before')), after: read(getComputedStyle(el, '::after')), up, down }
  } finally {
    if (pin !== undefined) {
      if (was === null) el.removeAttribute('data-pin')
      else el.setAttribute('data-pin', was)
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
export async function realStates(page, part, { skin, settle, title, entries, pairs, show }) {
  const fails = []
  const where = 'base'
  await show('light')
  const rest = async () => {
    await page.mouse.move(0, 0)
    await page.barkCheck((id) => document.getElementById(id).focus(), title)
    await settle(page)
  }
  await rest()
  const { pins, pairs: todo } = await page.barkCheck(plan, [part.name, entries])
  pairs.push(...todo)
  for (const p of pins) p.change = changes(await page.barkCheck(snap, [part.name, p.el, null]), await page.barkCheck(snap, [part.name, p.el]))
  // Each control once per mode its rules give it.
  const drives = new Map()
  for (const p of todo) for (const s of p.states) drives.set(`${p.el} ${MODES[s]}`, { el: p.el, at: p.at, mode: MODES[s] })
  const held = new Map()
  for (const { el, at, mode } of drives.values()) {
    const said = `real ${mode.replace(' ', ' and ')} on ${at}`
    await rest()
    const before = await page.barkCheck(snap, [part.name, el])
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
      const now = await page.barkCheck(snap, [part.name, el])
      await page.mouse.move(0, 0)
      if (down) await page.mouse.up()
      down = false
      await rest()
      const pinned = await page.barkCheck(snap, [part.name, el, mode])
      const unlike = differ(changes(before, now), changes(before, pinned)).map((d) => d.replace('where the pin', 'where the control pinned'))
      now.down.forEach((d, k) => {
        const prop = Object.keys(change(pinned.down[k].style, d.style))[0]
        if (prop) unlike.push(`${d.at} inside it: ${prop} becomes ${d.style[prop]} where the control pinned shows ${pinned.down[k].style[prop]}`)
      })
      if (unlike.length) fails.push(`${said}: ${unlike[0]}; the pin does not show this state, so no view reads it`)
      else held.set(mode, [...(held.get(mode) ?? []), el])
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
    } finally {
      await page.mouse.move(0, 0)
      if (down) await page.mouse.up()
    }
  }
  // Each state once, with every control it was proven on pinned. Text-only is a fact about a control at rest
  // (README), read in every view with its pin let go; here the controls are not at rest, so that one reading is
  // left to the views.
  for (const [mode, list] of held) {
    await rest()
    await page.barkCheck(setPins, [part.name, list, mode])
    try {
      for (const scheme of ['light', 'dark']) {
        await show(scheme)
        await settle(page)
        const w = waitsFor(skin, scheme, where)
        const v = await readView(page, part, w)
        fails.push(...verdict({ ...v, bounds: { ...v.bounds, misnamed: [] } }, `${mode.replace(' ', ' and ')} held on every live control it applies to, ${skin} ${scheme} on ${where}: `, w).fails)
      }
    } finally {
      await show('light')
      await page.barkCheck(setPins, [part.name, list, null])
    }
  }
  await rest()
  return fails
}
