// The built page prints no task id in its visible text. A page or a picture
// that shows one goes false the day the task closes; ids live in the data
// (build/sheet-waits.mjs) and may sit on an element as an attribute.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { discoverParts, partsDir } from '../build/parts.mjs'
import { SHEET_WAITS } from '../build/sheet-waits.mjs'
import { buildShowroom } from '../build/showroom.mjs'

/** What a reader sees: the page without scripts, styles, comments and tags, with entities read. */
export const visibleText = (html) =>
  html
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&')

const TASK_ID = /task-[0-9a-f]{6,}/

describe('the built page', () => {
  it('prints no task id in its visible text, with every wait on the sheet printed', async () => {
    const at = mkdtempSync(join(tmpdir(), 'barkui-visible-'))
    const waits = SHEET_WAITS.map((w) => ({ ...w, now: w.needs - 1 }))
    const parts = Object.fromEntries(discoverParts(partsDir).map((p) => [p.name, { hash: p.hash, measures: { waits } }]))
    writeFileSync(join(at, 'proof.json'), JSON.stringify({ ranAt: '2026-01-01T00:00:00Z', browser: 'B', foundation: 'f', parts }))
    try {
      await buildShowroom({ out: join(at, 'out'), proof: join(at, 'proof.json'), quiet: true })
      const html = readFileSync(join(at, 'out', 'index.html'), 'utf8')
      expect(html).toContain('waiting on the sheet')
      expect(visibleText(html).match(TASK_ID)?.[0] ?? null).toBeNull()
    } finally {
      rmSync(at, { recursive: true, force: true })
    }
  }, 30000)

  it('reads an id in text as visible and one in an attribute as not', () => {
    expect(visibleText('<p data-task="task-6617f9ae509c43d9">a (task-6617f9ae509c43d9)</p>')).toMatch(TASK_ID)
    expect(visibleText('<p data-task="task-6617f9ae509c43d9">a</p>')).not.toMatch(TASK_ID)
  })
})
