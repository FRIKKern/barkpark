// Real states, per pair. For every rule of the part that holds a state (:hover, :active, :checked) and every live
// control that matches the rest of its selector (the state taken out, as element.matches says; outside the inert
// rows, not a pinned row), the check produces that state on that control with the browser's own input: the pointer
// at its centre for hover, held down there for active (a real press is both), a click there for checked (only on
// a checkbox or radio not checked at rest; one checked at rest is read in every view as it stands). While it holds:
// - every computed property of the control, its ::before and ::after and everything inside it must be what the
//   same control shows with that state pinned (data-pin), and nothing from the control up to the stage may change
//   (no pin shows a host or an ancestor): so the control pinned is the control in that state;
// - the control's change must be exactly the change of some pinned row with the same data-pin, so a pinned row,
//   read in every skin, scheme, surface and width, shows this change too; the machine picks the row, by comparing.
// Then, per state, every live control is pinned at once and the stage is read as drawn (reading.mjs), in light and
// in dark: a value that computes alike in light can draw otherwise in dark. That reading records what applies
// (coverage.mjs), so each pair is judged as drawn while its rule applies. Two readings per state instead of one
// per control: a reading costs about a second, a driven control a few frames.
// The states are driven in one skin, light, base surface, 1440px. The selftest may give the drive a list of selectors
// (`states` as a list, check.mjs): then only the live controls one of them matches are driven, and a selector that
// matches no live control of the stage stops the run by name.
import { click, pointTo, pointerDown, pointerUp } from './acts.mjs'
import { waitsFor } from '../build/sheet-waits.mjs'
import { readView, verdict } from './reading.mjs'
import { unnamedNow } from './layers.mjs'

// Values resolved against the box's own size: a state may change them, but a longer label changes them too, so
// only whether they change is compared.
const SIZED = ['width', 'height', 'inline-size', 'block-size', 'transform-origin', 'perspective-origin']
const MODES = { hover: 'hover', active: 'hover active', checked: 'checked' }

/** Runs in the check's world: the pinned rows, and the (rule, live control) pairs a state must be driven for. */
function plan([n, entries, cover]) {
  const h = window.__barkCheck
  const root = document.querySelector(`[data-part="${n}"]`)
  const els = [root, ...root.querySelectorAll('*')]
  const pins = els.flatMap((el, i) => (el.hasAttribute('data-pin') ? [{ el: i, states: el.getAttribute('data-pin').split(/\s+/).filter(Boolean).sort().join(' '), at: h.describe(el) }] : []))
  const pairs = []
  entries.forEach((e, rule) => {
    if (!e.states.length) return
    els.forEach((el, i) => {
      if (!i || el.closest('[inert]') || el.hasAttribute('data-pin') || !el.matches(e.rest)) return
      if (cover && !cover.some((s) => el.matches(s))) return
      // A control already checked at rest is read in every view as it is; only the others are driven to it.
      const states = e.states.filter((s) => s !== 'checked' || !el.matches(':checked'))
      pairs.push({ rule, el: i, at: h.describe(el), states, kind: el.localName === 'input' ? el.type : el.localName })
    })
  })
  const live = els.filter((el, i) => i && !el.closest('[inert]') && !el.hasAttribute('data-pin'))
  const uncovered = (cover ?? []).filter((s) => !live.some((el) => el.matches(s)))
  return { pins, pairs, uncovered }
}

/** Runs in the check's world: sets data-pin on stage elements (`pin` a value, or null to take it off), through
    restyle (probes.mjs): the transitions this starts run to their end, as a reading after a real state waits for them. */
function setPins([n, list, pin]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const els = [root, ...root.querySelectorAll('*')]
  window.__barkCheck.restyle('pins set or taken off', () => {
    for (const i of list) {
      if (pin === null) els[i].removeAttribute('data-pin')
      else els[i].setAttribute('data-pin', pin)
    }
  })
}

/** Runs in the check's world: computed styles of one stage element, its ::before and ::after, everything inside it
    and its ancestors up to the stage. `pin`: read it with data-pin set to that (null: taken off), then put back. */
function snap([n, i, pin]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const el = [root, ...root.querySelectorAll('*')][i]
  const read = (s) => Object.fromEntries([...s].map((p) => [p, s.getPropertyValue(p)]))
  const was = el.getAttribute('data-pin')
  const put = (value) =>
    window.__barkCheck.restyle('a pin set for one snapshot and put back', () => {
      if (value === null) el.removeAttribute('data-pin')
      else el.setAttribute('data-pin', value)
    })
  if (pin !== undefined) put(pin)
  try {
    const h = window.__barkCheck
    const up = []
    for (let x = el.parentElement; x && root.contains(x); x = x.parentElement) up.push({ at: h.describe(x), style: read(getComputedStyle(x)) })
    const down = [...el.querySelectorAll('*')].map((x) => ({ at: h.describe(x), style: read(getComputedStyle(x)) }))
    return { self: read(getComputedStyle(el)), before: read(getComputedStyle(el, '::before')), after: read(getComputedStyle(el, '::after')), up, down }
  } finally {
    if (pin !== undefined) put(was)
  }
}

/** Runs in the check's world: the stage as data, one line per element (its attributes, checked, indeterminate,
    value, its children and its own text), so the check can tell that a drive left it as it found it. */
function stage([n]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  return [root, ...root.querySelectorAll('*')].map((el) => ({
    at: window.__barkCheck.describe(el),
    is: JSON.stringify([
      [...el.attributes].map((a) => `${a.name}=${a.value}`).sort(),
      el.checked ?? null, el.indeterminate ?? null, el.localName === 'input' || el.localName === 'textarea' || el.localName === 'select' ? el.value : null,
      [...el.childNodes].map((c) => (c.nodeType === 3 ? `#${c.data}` : c.nodeName)),
    ]),
  }))
}

/** What a drive left changed: the first element whose line differs, in plain words, or null. */
function leftChanged(before, after) {
  if (before.length !== after.length) return `the stage holds ${after.length} elements after it where it held ${before.length}`
  const k = before.findIndex((b, i) => b.is !== after[i].is)
  if (k < 0) return null
  const [was, now] = [JSON.parse(before[k].is), JSON.parse(after[k].is)]
  const names = ['attributes', 'checked', 'indeterminate', 'value', 'children and text']
  const what = names.filter((_, i) => JSON.stringify(was[i]) !== JSON.stringify(now[i]))
  return `${after[k].at} is left with other ${what.join(', ')} (${what.map((w) => JSON.stringify(now[names.indexOf(w)])).join('; ')}, was ${what.map((w) => JSON.stringify(was[names.indexOf(w)])).join('; ')})`
}

/** Runs in the check's world: which checkboxes and radios of the stage are checked; given that list, puts them back
    so, through restyle, so putting them back starts no transition. The check's own housekeeping after a real click. */
function checks([n, put]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const boxes = [...root.querySelectorAll('input[type="checkbox"], input[type="radio"]')]
  if (put) window.__barkCheck.restyle('checkboxes and radios put back', () => boxes.forEach((b, i) => (b.checked = put[i])))
  return boxes.map((b) => b.checked)
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
export async function realStates(page, part, { skin, settle, title, entries, pairs, show, cover = null }) {
  const fails = []
  const where = 'base'
  await show('light')
  const rest = async () => {
    await pointTo(page, 0, 0)
    await page.barkCheck((id) => {
      const el = document.getElementById(id)
      el.focus({ preventScroll: true })
      el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' })
    }, title)
    await settle(page)
  }
  await rest()
  const { pins, pairs: todo, uncovered } = await page.barkCheck(plan, [part.name, entries, cover])
  if (uncovered.length) throw new Error(`the state drive is given ${uncovered.join(', ')}, which matches no live control of the stage`)
  pairs.push(...todo)
  for (const p of pins) p.change = changes(await page.barkCheck(snap, [part.name, p.el, null]), await page.barkCheck(snap, [part.name, p.el]))
  // Each control once per mode its rules give it.
  const drives = new Map()
  for (const p of todo) for (const s of p.states) drives.set(`${p.el} ${MODES[s]}`, { el: p.el, at: p.at, mode: MODES[s], kind: p.kind })
  const held = new Map()
  process.stderr.write(`T> ${part.name}     drives ${drives.size}: ${[...drives.values()].map((d) => `${d.at} ${d.mode}`).join(' | ')}\n`)
  let D0 = performance.now()
  for (const { el, at, mode, kind } of drives.values()) {
    const said = `real ${mode.replace(' ', ' and ')} on ${at}`
    if (mode === 'checked' && kind !== 'checkbox' && kind !== 'radio') {
      fails.push(`${said}: the check drives :checked only on a checkbox or a radio, by a click; this is a ${kind}`)
      continue
    }
    await rest()
    const ticks = mode === 'checked' ? await page.barkCheck(checks, [part.name]) : null
    const found = await page.barkCheck(stage, [part.name])
    const before = await page.barkCheck(snap, [part.name, el])
    let down = false
    try {
      const to = await page.barkCheck(([n, k]) => {
        const root = document.querySelector(`[data-part="${n}"]`)
        const x = [root, ...root.querySelectorAll('*')][k]
        x.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
        const r = x.getBoundingClientRect()
        const [cx, cy] = [r.left + r.width / 2, r.top + r.height / 2]
        const top = document.elementFromPoint(cx, cy)
        return x === top || x.contains(top) ? { x: cx, y: cy } : { miss: `${window.__barkCheck.describe(top)} is on top at its centre` }
      }, [part.name, el])
      if (to.miss) {
        fails.push(`${said}: the pointer cannot reach it: ${to.miss}`)
        continue
      }
      if (mode === 'checked') {
        // A real click, then the pointer away, so what is read is checked and nothing else.
        await click(page, to.x, to.y)
        await pointTo(page, 0, 0)
      } else {
        await pointTo(page, to.x, to.y)
        if (mode.includes('active')) {
          await pointerDown(page)
          down = true
        }
      }
      await settle(page)
      // The pointer can open a box in the top layer (a tooltip on hover) that closes again before any reading.
      for (const f of await unnamedNow(page, part)) fails.push(`${said}: ${f}`)
      if (mode === 'checked' && !(await page.barkCheck(([n, k]) => { const r = document.querySelector(`[data-part="${n}"]`); return [r, ...r.querySelectorAll('*')][k].matches(':checked') }, [part.name, el]))) {
        fails.push(`${said}: a click at its centre does not check it`)
        continue
      }
      const now = await page.barkCheck(snap, [part.name, el])
      await pointTo(page, 0, 0)
      if (down) await pointerUp(page)
      down = false
      // A click changed what is checked; put every box and radio of the stage back as it was at rest.
      if (ticks) await page.barkCheck(checks, [part.name, ticks])
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
      await pointTo(page, 0, 0)
      if (down) await pointerUp(page)
      if (ticks) await page.barkCheck(checks, [part.name, ticks])
      // A drive is judged, not kept: what the check put back (what is checked) and nothing else may differ.
      await rest()
      const left = leftChanged(found, await page.barkCheck(stage, [part.name]))
      if (left) fails.push(`${said}: ${left}; a judged ${mode.replace(' ', ' and ')} must leave the stage as it found it, and the check puts back only what is checked`)
    }
  }
  process.stderr.write(`T> ${part.name}     drive loop ${((performance.now() - D0) / 1000).toFixed(1)}\n`); D0 = performance.now()
  // Each state once, with every control it was proven on pinned. Text-only is a fact about a control at rest
  // (docs/PARTS.md), read in every view with its pin let go; here the controls are not at rest, so that one reading is
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
  process.stderr.write(`T> ${part.name}     held readings ${((performance.now() - D0) / 1000).toFixed(1)}\n`)
  await rest()
  return fails
}
