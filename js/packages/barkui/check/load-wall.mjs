// The load wall: the check starts with this file (node --import ./check/load-wall.mjs <script>), and from then on the
// browser library is loaded only for check/acts.mjs, and for the library's own files as they load each other. Any
// other file that asks for it, by import, by a dynamic import or by require, is refused by name before the library
// loads. check/acts.mjs's launch refuses to start a browser in a run that did not start with this file.
import { registerHooks } from 'node:module'
import { fileURLToPath } from 'node:url'

/** Marks a run that started with the load wall. */
export const LOAD_WALL = Symbol.for('barkui.check.loadWall')
const ACTS = new URL('./acts.mjs', import.meta.url).href
const LIBRARY = /^playwright(-core)?(\/|$)/
/** The library's own files: they load each other. */
const OWN = /\/node_modules\/(\.pnpm\/[^/]+\/node_modules\/)?playwright(-core)?\//

/** Why `parentURL` may not load `specifier`, or null when it may. */
export function refusedLoad(specifier, parentURL) {
  if (!LIBRARY.test(specifier) || parentURL === ACTS || OWN.test(parentURL ?? '')) return null
  const from = parentURL?.startsWith('file:') ? fileURLToPath(parentURL) : String(parentURL)
  return `the browser library is loaded only by check/acts.mjs: ${from} asks for ${specifier}`
}

if (!globalThis[LOAD_WALL]) {
  registerHooks({
    resolve(specifier, context, next) {
      // PLANT: the load wall refuses nothing.
      return next(specifier, context)
    },
  })
  globalThis[LOAD_WALL] = true
}
