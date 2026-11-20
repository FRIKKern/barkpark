// The stamp of what the pictures in docs/images/ show. build/pictures.mjs
// writes it beside them when it retakes them; a fast test computes it again
// from the checkout and fails when the two differ, so a picture that no longer
// matches the code is red by name.
//
// The pictures show one part's section of the showroom (PICTURED), never the
// whole page, so the stamp covers only what draws that section: the part's own
// folder, the sheet, the base styles, the page code that lays a section out,
// the page's controls, the UI SDK version, and the picture script itself. Another part's folder is
// not in it, so adding a part leaves the pictures true. The check's own code is
// not in it either: the pictures show the lights of the run they were taken
// after, and the showroom says when a light rests on code that changed.
import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { partsDir as defaultParts } from './parts.mjs'
import { root, tokensPath, uiSdkVersion } from './showroom.mjs'

export const PICTURED = 'button'
export const stampPath = join(root, 'docs', 'images', 'pictures.stamp')

const SHARED = ['css/base.css', 'build/page.mjs', 'build/showroom.mjs', 'build/showroom.css', 'build/controls.mjs', 'build/sheet-waits.mjs', 'build/pictures.mjs']

/** Every file the stamp reads, as [name, path]: the pictured part's folder, then the shared files and the sheet. */
export function stampedFiles(partsDir = defaultParts) {
  const dir = join(partsDir, PICTURED)
  const own = readdirSync(dir).filter((f) => !f.startsWith('.')).sort().map((f) => [`parts/${PICTURED}/${f}`, join(dir, f)])
  return [...own, ...SHARED.map((f) => [f, join(root, f)]), [relative(root, tokensPath), tokensPath]]
}

export function pictureStamp({ partsDir = defaultParts, version = uiSdkVersion } = {}) {
  const h = createHash('sha256').update(`ui-sdk ${version}\n`)
  for (const [name, path] of stampedFiles(partsDir)) h.update(`${name}\n`).update(readFileSync(path)).update('\n')
  return h.digest('hex').slice(0, 16)
}
