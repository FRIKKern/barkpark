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
import { ALLOWED, CDP_ALLOWED, EVERY, PAGE_FIELDS, PLAIN_KINDS, WALL } from './wall.mjs'

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
  if (at === 'an unknown file') return
  REFUSED.push({ what, at, n: REFUSED.length })
  throw new WallRefusal(`the browser library is reached only through check/acts.mjs: ${what}, from ${at}, is not on the wall's list (check/wall.mjs)`)
}

/** The library's own name for an object's class: its bundle may mark the name with a leading _ or a trailing number. */
const nameOf = (o) => o?.constructor?.name?.replace(/^_+|\d+$/g, '') ?? ''
/** The kind of a library object, or null for anything else (data, the check's own functions, errors). */
function kindOf(v) {
  if (!v || (typeof v !== 'object' && typeof v !== 'function')) return null
  const own = nameOf(v)
  if (PLAIN_KINDS.includes(own)) return own
  for (let p = Object.getPrototypeOf(v); p; p = Object.getPrototypeOf(p)) if (nameOf(p) === 'ChannelOwner') return own
  return null
}
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
    if (!LISTENERS.has(a)) LISTENERS.set(a, (...xs) => a(...xs.map(wall)))
    return LISTENERS.get(a)
  }
  if (Array.isArray(a)) return a.map((x) => given('', x))
  if (a && Object.getPrototypeOf(a) === Object.prototype) return Object.fromEntries(Object.entries(a).map(([k, x]) => [k, given('', x)]))
  return a
}
/** What the check's code gets for a value: a library object as its wall object (one per object), arrays of them
    walled, anything else as it is. */
function wall(v) {
  if (Array.isArray(v)) return v.map(wall)
  if (TARGET.has(v)) return v
  const kind = kindOf(v)
  if (!kind) return v
  if (WALLS.has(v)) return WALLS.get(v)
  WALL.read[kind] = Math.max(WALL.read[kind] ?? 0, methodsOf(v))
  const allowed = new Set([...EVERY, ...(ALLOWED[kind] ?? [])])
  const fields = new Set(kind === 'Page' ? PAGE_FIELDS : [])
  const w = new Proxy(v, {
    get(t, name) {
      if (!allowed.has(name)) refuse(kind, name)
      const value = Reflect.get(t, name, t)
      if (typeof value !== 'function' || fields.has(name)) return wall(value)
      return (...args) => {
        if (kind === 'CDPSession' && name === 'send' && !CDP_ALLOWED.includes(args[0])) refuse(kind, `send('${args[0]}')`)
        const out = value.apply(t, args.map((a) => given(name, a)))
        return out && typeof out.then === 'function' ? out.then(wall) : wall(out)
      }
    },
    set(t, name, value) {
      if (!fields.has(name)) refuse(kind, name)
      t[name] = value
      return true
    },
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
  guard()
  const browser = await chromium.launch(options)
  OPEN.add(browser)
  browser.on('disconnected', () => OPEN.delete(browser))
  return wall(browser)
}

/** The library's own page behind a wall page, for the input below. */
const own = (page) => TARGET.get(page) ?? page

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
  await own(page).keyboard.press(key)
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
export async function pointTo(page, x, y) {
  const at = where()
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
