// The wall round the checker's input. Where the check opens a page (check/proofs.mjs, open), it reads the methods of
// the browser library's own page-side objects from those objects: the page, its keyboard, mouse and touchscreen,
// and every frame, locator and element handle a page method hands back. A method on the one closed list below makes
// no input and is let through. Every other method, one the library adds later included, throws by name and file
// unless check/acts.mjs called it, where every act is followed by its rest step. The library's own calls inside it
// go through as they are.
import { fileURLToPath } from 'node:url'

const READS = ['$', '$$', '$eval', '$$eval', 'ariaSnapshot', 'ariaSnapshotJSON', 'content', 'evaluate', 'evaluateAll', 'evaluateHandle', 'getAttribute', 'innerHTML', 'innerText', 'inputValue', 'isChecked', 'isDisabled', 'isEditable', 'isEnabled', 'isHidden', 'isVisible', 'textContent', 'title', 'url']
const FINDS = ['frameLocator', 'getByAltText', 'getByLabel', 'getByPlaceholder', 'getByRole', 'getByTestId', 'getByText', 'getByTitle', 'locator']
const WAITS = ['waitForFunction', 'waitForLoadState', 'waitForNavigation', 'waitForSelector', 'waitForTimeout', 'waitForURL']
/** The methods that make no input to a page, by the library's name for each object: the one closed list. */
export const NO_INPUT = {
  Page: [...READS, ...FINDS, ...WAITS, 'addInitScript', 'addListener', 'addScriptTag', 'addStyleTag', 'clearConsoleMessages', 'clearPageErrors', 'close', 'consoleMessages', 'context', 'emulateMedia', 'exposeBinding', 'exposeFunction', 'frame', 'frames', 'goBack', 'goForward', 'goto', 'isClosed', 'mainFrame', 'off', 'on', 'once', 'opener', 'pageErrors', 'pdf', 'prependListener', 'reload', 'removeAllListeners', 'removeListener', 'requestGC', 'requests', 'route', 'routeFromHAR', 'routeWebSocket', 'screenshot', 'setContent', 'setDefaultNavigationTimeout', 'setDefaultTimeout', 'setExtraHTTPHeaders', 'setViewportSize', 'unroute', 'unrouteAll', 'video', 'viewportSize', 'waitForEvent', 'waitForRequest', 'waitForResponse', 'workers'],
  Frame: [...READS, ...FINDS, ...WAITS, 'addScriptTag', 'addStyleTag', 'childFrames', 'frameElement', 'goto', 'isDetached', 'name', 'page', 'parentFrame', 'setContent'],
  Locator: [...READS, ...FINDS, 'all', 'allInnerTexts', 'allTextContents', 'and', 'boundingBox', 'contentFrame', 'count', 'describe', 'description', 'elementHandle', 'elementHandles', 'filter', 'first', 'last', 'normalize', 'nth', 'or', 'page', 'screenshot', 'toString', 'visible', 'waitFor'],
  FrameLocator: [...FINDS, 'first', 'last', 'nth', 'owner'],
  ElementHandle: [...READS, 'asElement', 'boundingBox', 'contentFrame', 'dispose', 'getProperties', 'getProperty', 'jsonValue', 'ownerFrame', 'screenshot', 'toString', 'waitForElementState', 'waitForSelector'],
  JSHandle: [...READS, 'asElement', 'dispose', 'getProperties', 'getProperty', 'jsonValue', 'toString'],
  Keyboard: [],
  Mouse: [],
  Touchscreen: [],
}

const ACTS_FILE = fileURLToPath(new URL('./acts.mjs', import.meta.url))
const HERE = fileURLToPath(import.meta.url)
const PACKAGE = fileURLToPath(new URL('..', import.meta.url))
const WALLED = Symbol('walled')
/** What the wall has read so far: each object's methods, by the library's name for it. */
export const WALL = { read: {}, refused: 0 }

/** The file and line that called the walled method, or null when the library itself did. */
function caller() {
  for (const l of new Error().stack.split('\n').slice(1)) {
    const m = l.match(/\(?((?:file:\/\/)?\/[^():]+):(\d+):\d+\)?$/)
    if (!m) continue
    const file = m[1].replace(/^file:\/\//, '')
    if (file === HERE) continue
    if (file.includes('/node_modules/')) return null
    return { file, line: m[2] }
  }
  return null
}

/** A method's own name for every function the object's class and its parents up to the library's base define. */
function methodsOf(obj) {
  const out = new Set()
  for (let p = Object.getPrototypeOf(obj); p && !['Object', 'ChannelOwner', 'EventEmitter'].includes(p.constructor?.name); p = Object.getPrototypeOf(p))
    for (const k of Object.getOwnPropertyNames(p)) if (k !== 'constructor' && !k.startsWith('_') && typeof Object.getOwnPropertyDescriptor(p, k).value === 'function') out.add(k)
  return [...out]
}

/** Walls one of the library's objects in place: each method off the closed list throws unless check/acts.mjs called
    it; each one on it goes through, and what it hands back is walled in turn. */
export function wall(obj) {
  if (!obj || typeof obj !== 'object' || obj[WALLED]) return obj
  const kind = obj.constructor?.name
  if (!(kind in NO_INPUT)) return obj
  obj[WALLED] = true
  const names = methodsOf(obj)
  WALL.read[kind] = Math.max(WALL.read[kind] ?? 0, names.length)
  for (const name of names) {
    const own = obj[name]
    if (NO_INPUT[kind].includes(name)) {
      obj[name] = function (...a) {
        const out = own.apply(this, a)
        return out && typeof out.then === 'function' ? out.then(walled) : walled(out)
      }
      continue
    }
    obj[name] = function (...a) {
      const by = caller()
      if (by && by.file !== ACTS_FILE) {
        WALL.refused++
        throw new Error(`the checker's input goes only through check/acts.mjs: ${kind}.${name} called at ${by.file.replace(PACKAGE, '')}:${by.line}`)
      }
      return own.apply(this, a)
    }
  }
  return obj
}
const walled = (v) => (Array.isArray(v) ? v.map(wall) : wall(v))

/** Walls a page the check opened and the input objects it holds. */
export function wallPage(page) {
  wall(page)
  for (const k of ['keyboard', 'mouse', 'touchscreen']) wall(page[k])
  return page
}

/** One line for a run's end: what the wall read, and its closed list, each counted from itself. */
export const wallLine = () => {
  const kinds = Object.keys(WALL.read)
  const read = kinds.reduce((n, k) => n + WALL.read[k], 0)
  const listed = Object.values(NO_INPUT).reduce((n, l) => n + new Set(l).size, 0)
  return `the input wall: ${read} methods read from the library's own page-side objects (${kinds.map((k) => `${k} ${WALL.read[k]}`).join(', ')}); the closed list of those that make no input holds ${listed}; every other one only through check/acts.mjs`
}
