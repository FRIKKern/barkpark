// Pinned equals real. example.html shows each state worth seeing as a row pinned with data-pin (hover, active,
// focus-visible), and the lights read those rows in every skin, scheme, surface and width. This proves the pin
// shows what the real state shows: for each pinned row it finds the live control of the same kind (same element,
// same data-* attributes but data-pin, outside the inert rows), produces the real state on it with the browser's
// own input (the pointer at its centre for hover, held down there for active, Tab for focus-visible), and holds
// what that changes to what the pin changes. Compared, as the browser computes them: every property of the
// control and of its ::before and ::after (the change the state makes must be the change the pin makes), and every
// element from the control up to the part's stage (a state may change nothing there; no pin shows a host or an
// ancestor). The stage is also read as drawn while the state is held (reading.mjs). One skin, light, base surface,
// 1440px: part.css cannot tell skins apart, so the pin carries the same change to every other view.
import { waitsFor } from '../build/sheet-waits.mjs'
import { readView, verdict } from './reading.mjs'

// Values resolved against the box's own size: a state may change them, but a longer label changes them too, so
// only whether they change is compared.
const SIZED = ['width', 'height', 'inline-size', 'block-size', 'transform-origin', 'perspective-origin']

/** Runs in the check's world: each pinned element, its states, and its live twin, by index in the stage. */
function pins(n) {
  const h = window.__barkCheck
  const root = document.querySelector(`[data-part="${n}"]`)
  const all = [...root.querySelectorAll('*')]
  const kind = (el) => `${el.localName} ${[...el.attributes].filter((a) => a.name.startsWith('data-') && a.name !== 'data-pin').map((a) => `${a.name}=${a.value}`).sort().join(' ')}`
  const live = all.filter((el) => !el.closest('[inert]') && !el.hasAttribute('data-pin'))
  return all
    .filter((el) => el.hasAttribute('data-pin'))
    .map((el) => {
      const twin = live.find((x) => kind(x) === kind(el))
      return { pin: all.indexOf(el), states: el.getAttribute('data-pin').split(/\s+/).filter(Boolean), at: h.describe(el), live: twin ? all.indexOf(twin) : -1, liveAt: twin ? h.describe(twin) : '' }
    })
}

/** Runs in the check's world: computed styles of one stage element, its ::before and ::after, and its ancestors up
    to the stage. `unpin`: read it with data-pin taken off (then put back). */
function snap([n, i, unpin]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const el = [...root.querySelectorAll('*')][i]
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

/** Every way the real state on the live control differs from its pin, in plain words, plus the drawn reading's. */
export async function realStates(page, part, { skin, settle, title }) {
  const fails = []
  const where = 'base'
  const waits = waitsFor(skin, 'light', where)
  const rest = async () => {
    await page.mouse.move(0, 0)
    await page.barkCheck((id) => document.getElementById(id).focus(), title)
    await settle(page)
  }
  for (const p of await page.barkCheck(pins, part.name)) {
    if (p.live < 0) {
      fails.push(`pin ${p.at} has no live control of its kind in the stage (the same element and data-* attributes, outside the inert rows) to hold it to`)
      continue
    }
    const said = `real ${p.states.join(' and ')} on ${p.liveAt}`
    await rest()
    const [off, on] = [await page.barkCheck(snap, [part.name, p.pin, true]), await page.barkCheck(snap, [part.name, p.pin, false])]
    const pinAll = Object.fromEntries(['self', 'before', 'after'].map((pe) => [pe, change(off[pe], on[pe])]))
    const before = await page.barkCheck(snap, [part.name, p.live, false])
    let down = false
    try {
      if (p.states.includes('focus-visible')) {
        for (let i = 0; i < 60; i++) {
          await page.keyboard.press('Tab')
          if (await page.barkCheck(([n, k]) => document.activeElement === [...document.querySelector(`[data-part="${n}"]`).querySelectorAll('*')][k], [part.name, p.live])) break
        }
      }
      if (p.states.includes('hover') || p.states.includes('active')) {
        const at = await page.barkCheck(([n, k]) => {
          const el = [...document.querySelector(`[data-part="${n}"]`).querySelectorAll('*')][k]
          el.scrollIntoView({ block: 'center', inline: 'center' })
          const r = el.getBoundingClientRect()
          const [x, y] = [r.left + r.width / 2, r.top + r.height / 2]
          const top = document.elementFromPoint(x, y)
          return el === top || el.contains(top) ? { x, y } : { miss: `${window.__barkCheck.describe(top)} is on top at its centre` }
        }, [part.name, p.live])
        if (at.miss) {
          fails.push(`${said}: ${at.miss}`)
          continue
        }
        await page.mouse.move(at.x, at.y)
        if (p.states.includes('active')) {
          await page.mouse.down()
          down = true
        }
      }
      await settle(page)
      const now = await page.barkCheck(snap, [part.name, p.live, false])
      for (const pe of ['self', 'before', 'after']) {
        const real = change(before[pe], now[pe])
        const of = pe === 'self' ? '' : `::${pe} `
        for (const prop of new Set([...Object.keys(real), ...Object.keys(pinAll[pe])])) {
          const same = SIZED.includes(prop) ? prop in real === prop in pinAll[pe] : real[prop] === pinAll[pe][prop]
          if (!same) fails.push(`${said}: ${of}${prop} ${prop in real ? `becomes ${real[prop]}` : 'stays as it was'} where its pin (${p.at}) ${prop in pinAll[pe] ? `shows ${pinAll[pe][prop]}` : 'leaves it as it was'}`)
        }
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
