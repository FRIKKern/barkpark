// The checker's input on a page, and the one place that holds the browser library's own objects.
// - The wall: `launch` hands back a wall object in the browser's place, and every library object an allowed call
//   hands back (pages, contexts, frames, sessions, anything reached from them, an event's arguments too) is a wall
//   object as well. On one, a name on the closed list in check/wall.mjs goes through; every other name throws by name
//   and is kept as a refusal, so a refusal inside a timer or a callback is still red where the run is read.
// - The input: keys and the pointer, made here on the library's own page and nowhere else. After each comes its rest
//   step, afterAct in check/probes.mjs: a frame is drawn, so what the input started shows, then the page comes to
//   rest inside the bound before the next read (after a key, the browser's scroll of the element with focus into
//   view included), or the act is red there, named with the file and line the checker made it from.
import { chromium } from 'playwright'
import { fileURLToPath } from 'node:url'
import { ALLOWED, CDP_ALLOWED, EVERY, PAGE_FIELDS, PLAIN, WALL } from './wall.mjs'

/** The mark check/load-wall.mjs sets on a run that started with it (not imported from there: an import would set it). */
const LOAD_WALL = Symbol.for('barkui.check.loadWall')

const HERE = fileURLToPath(import.meta.url)
const PACKAGE = fileURLToPath(new URL('..', import.meta.url))

/** The file and line a call came from, for the message alone: the first frame in a file outside this one and outside
    the library. The wall never decides by it. */
function from() {
  for (const l of new Error().stack.split('\n').slice(1)) {
    const m = l.match(/(?:\(|\bat )(?:file:\/\/)?(\/[^\s():]+):(\d+):\d+/)
    if (!m || m[1] === HERE || m[1].includes('/node_modules/')) continue
    return `${m[1].replace(PACKAGE, '')}:${m[2]}`
  }
  return 'an unknown file'
}

/** A refusal: a name off the closed list, reached on a wall object. */
export class WallRefusal extends Error {}
const REFUSED = []
/** Every refusal this run, as `{ what, at, n }`: `n` is its place in the run's list. */
export const refusals = () => REFUSED.map((r) => ({ ...r }))
function refuse(kind, name) {
  const what = `${kind}.${typeof name === 'symbol' ? `[${String(name)}]` : name}`
  const at = from()
  REFUSED.push({ what, at, n: REFUSED.length })
  throw new WallRefusal(`the browser library is reached only through check/acts.mjs: ${what}, from ${at}, is not on the wall's list (check/wall.mjs)`)
}

/** The library's own name for an object's class: its bundle may mark the name with a leading _ or a trailing number. */
const nameOf = (o) => o?.constructor?.name?.replace(/^_+|\d+$/g, '') ?? ''
/** How each kind of check/wall.mjs's PLAIN is told. */
const IS = {
  Object: (v) => [Object.prototype, null].includes(Object.getPrototypeOf(v)),
  Array: (v) => Array.isArray(v),
  Buffer: (v) => Buffer.isBuffer(v),
  Error: (v) => v instanceof Error,
  ...Object.fromEntries(['Uint8Array', 'ArrayBuffer', 'Date', 'RegExp'].map((k) => [k, (v) => v instanceof globalThis[k]])),
}
for (const k of PLAIN) if (!IS[k]) throw new Error(`check/wall.mjs's PLAIN names ${k}, which check/acts.mjs cannot tell`)
/** The kind of plain data a value is, by check/wall.mjs's PLAIN, or null for anything else. */
const plainOf = (v) => PLAIN.find((k) => IS[k](v)) ?? null
/** Every method name a library object's class and its parents define: what the wall reads of the library. */
function methodsOf(v) {
  const out = new Set()
  for (let p = Object.getPrototypeOf(v); p && !['Object', 'ChannelOwner', 'EventEmitter'].includes(nameOf(p)); p = Object.getPrototypeOf(p))
    for (const k of Object.getOwnPropertyNames(p)) if (k !== 'constructor' && typeof Object.getOwnPropertyDescriptor(p, k).value === 'function') out.add(k)
  return out.size
}

const TARGET = new WeakMap()
const WALLS = new WeakMap()
const LISTENERS = new WeakMap()
const EVENT_CALLS = ['on', 'once', 'off', 'addListener', 'removeListener']
/** What a library call is given: wall objects back to the library's own, and an event's listener walled, so what
    the library hands it is a wall object. */
function given(name, a) {
  if (TARGET.has(a)) return TARGET.get(a)
  if (typeof a === 'function' && EVENT_CALLS.includes(name)) {
    if (!LISTENERS.has(a)) LISTENERS.set(a, (...xs) => a(...xs.map((x) => wall(x))))
    return LISTENERS.get(a)
  }
  if (Array.isArray(a)) return a.map((x) => given('', x))
  if (a && Object.getPrototypeOf(a) === Object.prototype) return Object.fromEntries(Object.entries(a).map(([k, x]) => [k, given('', x)]))
  return a
}
/** What the check's code gets for a value the library hands back. A primitive, as it is. Plain data of a kind on
    check/wall.mjs's PLAIN, as it is, an array's or a plain object's values walled by this same rule (a copy where one
    changes). A promise, as a promise of its value walled. Every other value, an object of any class or a function, as
    its wall object, one per value: the wall's default is wall. */
function wall(v, seen = new Set()) {
  if (v === null || (typeof v !== 'object' && typeof v !== 'function')) return v
  if (TARGET.has(v)) return v
  if (WALLS.has(v)) return WALLS.get(v)
  if (v instanceof Promise) return v.then((x) => wall(x), thrown)
  const plain = typeof v === 'object' ? plainOf(v) : null
  if (plain === 'Array' || plain === 'Object') {
    if (seen.has(v)) return v
    seen.add(v)
    let out = v
    for (const k of Object.keys(v)) {
      const x = wall(v[k], seen)
      if (x === v[k]) continue
      if (out === v) out = Array.isArray(v) ? [...v] : { ...v }
      out[k] = x
    }
    return out
  }
  // An error is data while every field of its own is: one that holds anything else is a wall object.
  if (plain === 'Error') {
    if (seen.has(v)) return v
    seen.add(v)
    return Object.keys(v).every((k) => wall(v[k], seen) === v[k]) ? v : walled(v)
  }
  if (plain) return v
  return walled(v)
}
/** What a call throws or a promise rejects with goes through the wall as well. */
const thrown = (e) => {
  throw wall(e)
}
/** The wall, for the tests: what any value is once it has passed. */
export const throughWall = (v) => wall(v)
/** A wall object for `v`: on it, a name on the closed list for its kind goes through, and every other name is refused
    by name; called, if it is a function, it is refused. */
function walled(v) {
  const kind = nameOf(v) || 'an object of no class'
  if (typeof v === 'object') WALL.read[kind] = Math.max(WALL.read[kind] ?? 0, methodsOf(v))
  const allowed = new Set([...EVERY, ...(ALLOWED[kind] ?? [])])
  const fields = new Set(kind === 'Page' ? PAGE_FIELDS : [])
  const w = new Proxy(v, {
    get(t, name) {
      if (!allowed.has(name)) refuse(kind, name)
      const value = Reflect.get(t, name, t)
      // The check's own fields hold the check's own values, set through this wall.
      if (fields.has(name)) return value
      if (typeof value !== 'function') return wall(value)
      return (...args) => {
        if (kind === 'CDPSession' && name === 'send' && !CDP_ALLOWED.includes(args[0])) refuse(kind, `send('${args[0]}')`)
        let out
        try {
          out = value.apply(t, args.map((a) => given(name, a)))
        } catch (e) {
          thrown(e)
        }
        return out && typeof out.then === 'function' ? out.then((x) => wall(x), thrown) : wall(out)
      }
    },
    set(t, name, value) {
      if (!fields.has(name)) refuse(kind, name)
      t[name] = value
      return true
    },
    apply: () => refuse(kind, 'a call'),
    construct: () => refuse(kind, 'new'),
    has: (t, name) => allowed.has(name) || refuse(kind, name),
    getOwnPropertyDescriptor: (t, name) => refuse(kind, name),
    defineProperty: (t, name) => refuse(kind, name),
    deleteProperty: (t, name) => refuse(kind, name),
    ownKeys: () => refuse(kind, 'its own keys'),
    getPrototypeOf: () => refuse(kind, 'its prototype'),
    setPrototypeOf: () => refuse(kind, 'its prototype'),
  })
  TARGET.set(w, v)
  WALLS.set(v, w)
  return w
}

let guarded = false
/** A refusal thrown where no code catches it (a timer, a listener) is kept and read where the run is read; it never
    ends the run. Anything else uncaught ends it, as it would. */
function guard() {
  if (guarded) return
  guarded = true
  const end = (e) => {
    // Kept (refusals), so the case or run it came in is red by it; a run that ends on its own after one is red too.
    if (e instanceof WallRefusal) {
      process.exitCode = 1
      return
    }
    console.error(e)
    process.exit(1)
  }
  process.on('uncaughtException', end)
  process.on('unhandledRejection', end)
  // A run whose work stops while a browser is still open (a promise left waiting forever) ends red, never at 0.
  process.on('beforeExit', () => {
    if (!OPEN.size) return
    console.error(`the run stopped with ${OPEN.size} browser(s) still open: some work never finished`)
    process.exit(1)
  })
}
const OPEN = new Set()

/** The browser, as a wall object. */
export async function launch(options) {
  // The run holds that the library is loaded by this file alone: it starts with check/load-wall.mjs, whose hook
  // refuses the library to every other file.
  if (!globalThis[LOAD_WALL]) throw new Error('the check starts with its load wall: node --import ./check/load-wall.mjs <script>')
  guard()
  const browser = await chromium.launch(options)
  OPEN.add(browser)
  browser.on('disconnected', () => OPEN.delete(browser))
  return wall(browser)
}

/** The library's own page behind a wall page, for the input below. */
const own = (page) => TARGET.get(page) ?? page
// PLANT: a key goes to another open page the checker acted on, when there is one.
const ACTED = []
const wrongPage = (page) => {
  const p = own(page)
  if (!ACTED.includes(p)) ACTED.push(p)
  return ACTED.find((x) => x !== p && !x.isClosed()) ?? p
}

/** Where the checker made the act: the first caller outside this file, as check/<file>.mjs:<line>. */
function where() {
  for (const l of new Error().stack.split('\n').slice(1)) {
    if (l.includes('/check/acts.mjs')) continue
    const m = l.match(/\/(check\/[\w.-]+\.mjs):(\d+)/)
    if (m) return `${m[1]}:${m[2]}`
  }
  return 'an unknown place'
}
const rested = (page, act, at, kind = 'pointer') => page.barkCheck((a) => window.__barkCheck.afterAct(a), [`${act} at ${at}`, kind])

/** A key pressed and let go. */
export async function press(page, key) {
  const at = where()
  await wrongPage(page).keyboard.press(key)
  await rested(page, `the key ${key}`, at, 'key')
}

/** A click at a point, with `modifiers` held (the key names the library takes, such as Control). */
export async function click(page, x, y, { modifiers = [] } = {}) {
  const at = where()
  const { keyboard, mouse } = own(page)
  for (const k of modifiers) await keyboard.down(k)
  try {
    await mouse.click(x, y)
  } finally {
    for (const k of [...modifiers].reverse()) await keyboard.up(k)
  }
  await rested(page, modifiers.length ? `a ${modifiers.join('+')} click` : 'a click', at)
}

/** A click at the middle of the element `selector` names, scrolled into view first. */
export async function clickOn(page, selector, options) {
  const { x, y } = await page.barkCheck((s) => {
    const el = document.querySelector(s)
    el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' })
    const r = el.getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  }, selector)
  await click(page, x, y, options)
}

/** The pointer moved to a point. */
const LAST = new WeakMap()
export async function pointTo(page, x, y) {
  const at = where()
  // PLANT: the skip put back: a move to the point the pointer is already at is not made.
  const was = LAST.get(page)
  if (was && was.x === x && was.y === y) return
  LAST.set(page, { x, y })
  await own(page).mouse.move(x, y)
  await rested(page, 'the pointer moved', at)
}

/** The pointer's button held down where the pointer is. */
export async function pointerDown(page) {
  const at = where()
  await own(page).mouse.down()
  await rested(page, 'the pointer pressed', at)
}

/** The pointer's button let go. */
export async function pointerUp(page) {
  const at = where()
  await own(page).mouse.up()
  await rested(page, 'the pointer let go', at)
}
