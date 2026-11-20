import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { partsDir } from '../build/parts.mjs'
import { PICTURED, pictureStamp, stampedFiles, stampPath } from '../build/picture-stamp.mjs'

/** A scratch parts folder holding the pictured part, and whatever `more` adds to it. */
function scratch(more = () => {}) {
  const dir = mkdtempSync(join(tmpdir(), 'barkui-pictures-'))
  cpSync(join(partsDir, PICTURED), join(dir, PICTURED), { recursive: true })
  more(dir)
  return dir
}

describe('the pictures in docs/images', () => {
  it('match the code that draws what they show (retake with node build/pictures.mjs after build and check when this fails)', () => {
    expect(readFileSync(stampPath, 'utf8').trim()).toBe(pictureStamp())
  })

  it('stay true when another part is added', () => {
    const one = scratch()
    const two = scratch((dir) => cpSync(join(partsDir, PICTURED), join(dir, 'copy'), { recursive: true }))
    try {
      expect(pictureStamp({ partsDir: two })).toBe(pictureStamp({ partsDir: one }))
      expect(stampedFiles(two).filter(([name]) => name.startsWith('parts/') && !name.startsWith(`parts/${PICTURED}/`))).toEqual([])
    } finally {
      for (const d of [one, two]) rmSync(d, { recursive: true, force: true })
    }
  })

  it('go stale when the pictured part or the UI SDK version changes', () => {
    const one = scratch()
    const changed = scratch((dir) => appendFileSync(join(dir, PICTURED, 'part.css'), '\n/* a change */\n'))
    try {
      expect(pictureStamp({ partsDir: changed })).not.toBe(pictureStamp({ partsDir: one }))
      expect(pictureStamp({ partsDir: one, version: '0.0.0' })).not.toBe(pictureStamp({ partsDir: one }))
    } finally {
      for (const d of [one, changed]) rmSync(d, { recursive: true, force: true })
    }
  })
})
