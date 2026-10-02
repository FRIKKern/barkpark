// A starter page that calls notFound() must answer HTTP 404, not 200.
//
// Next streams a route that sits under a loading.tsx Suspense boundary: it
// sends the 200 status and the skeleton before the page resolves. When the
// page then calls notFound(), Next can only swap in the not-found UI and a
// robots noindex meta, because the status is already on the wire. Live, on a
// scaffolded blog starter with the shared root app/loading.tsx,
// /posts/<missing> and /tags/<missing> answered 200 (a soft 404). With the
// boundary removed they answer 404.
//
// The invariant: in every composed starter (_shared + starter tree), no
// loading.tsx sits in a page's own directory or in any of its ancestors up to
// app/ when that page calls notFound().
import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { AVAILABLE_TEMPLATES, SHARED_TEMPLATE_DIR } from '../src/constants'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const TEMPLATES_DIR = path.resolve(HERE, '..', 'templates')

async function walk(dir: string): Promise<string[]> {
  let entries
  try {
    entries = await fs.readdir(dir, { withFileTypes: true })
  } catch {
    return []
  }
  const out: string[] = []
  for (const e of entries) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) out.push(...(await walk(p)))
    else out.push(p)
  }
  return out
}

/** App-relative paths ('posts/[slug]/page.tsx') of the composed starter. */
async function composedAppFiles(template: string): Promise<Map<string, string>> {
  const files = new Map<string, string>()
  for (const root of [SHARED_TEMPLATE_DIR, template]) {
    const appDir = path.join(TEMPLATES_DIR, root, 'app')
    for (const abs of await walk(appDir)) {
      files.set(path.relative(appDir, abs).split(path.sep).join('/'), abs)
    }
  }
  return files
}

describe('starter notFound() routes answer a real 404', () => {
  for (const template of AVAILABLE_TEMPLATES) {
    it(`${template}: no loading.tsx above a page that calls notFound()`, async () => {
      const files = await composedAppFiles(template)
      const notFoundPages: string[] = []
      for (const [rel, abs] of files) {
        if (!/(^|\/)page\.tsx$/.test(rel)) continue
        if (/\bnotFound\s*\(/.test(await fs.readFile(abs, 'utf8'))) notFoundPages.push(rel)
      }
      // The walk must find the slug routes, or the check below is vacuous.
      expect(notFoundPages.length).toBeGreaterThan(0)

      const offenders: string[] = []
      for (const page of notFoundPages) {
        const segs = page.split('/').slice(0, -1)
        for (let i = segs.length; i >= 0; i--) {
          const loading = [...segs.slice(0, i), 'loading.tsx'].join('/')
          if (files.has(loading)) offenders.push(`${page} under app/${loading}`)
        }
      }
      expect(offenders).toEqual([])
    })
  }
})
