import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { lintPartCss } from '../build/css-lint.mjs'
import { discoverParts } from '../build/parts.mjs'

const parts = discoverParts(join(import.meta.dirname, '..', 'parts'))

describe('every real part.css', () => {
  for (const p of parts) {
    it(`${p.name}/part.css has no colour literal and reads only --ui-* / --bark-*`, () => {
      expect(lintPartCss(readFileSync(join(p.dir, 'part.css'), 'utf8'))).toEqual([])
    })
  }
})

describe('lintPartCss', () => {
  const bad = {
    hex: 'a { color: #fff; }',
    'long hex': 'a { border: 1px solid #12345678; }',
    rgb: 'a { background: rgb(0 0 0); }',
    rgba: 'a { background: rgba(0, 0, 0, 0.5); }',
    hsl: 'a { color: hsl(0 0% 100%); }',
    oklch: 'a { color: oklch(0.5 0.1 20); }',
    'named colour': 'a { color: red; }',
    'named in shorthand': 'a { border: 1px solid rebeccapurple; }',
    'foreign variable': 'a { color: var(--brand-ink); }',
    'variable fallback literal': 'a { color: var(--ui-primary, #000); }',
  }
  for (const [what, css] of Object.entries(bad)) {
    it(`refuses a ${what}`, () => {
      expect(lintPartCss(css).length).toBeGreaterThan(0)
    })
  }

  it('allows variables, color-mix of variables, keywords and comments that name colours', () => {
    const css = `/* red on #fff is wrong */
      [data-slot="button"] {
        color: var(--ui-foreground);
        background: color-mix(in oklab, var(--ui-primary) 88%, var(--ui-foreground));
        border-color: transparent;
        outline-color: currentColor;
        --bark-button-height: 2rem;
        height: var(--bark-button-height);
      }`
    expect(lintPartCss(css)).toEqual([])
  })
})
