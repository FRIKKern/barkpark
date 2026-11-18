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
    'capitalised property': 'a { Color: #fff; }',
    'capitalised background': 'a { BACKGROUND: #ffffff; }',
    'hex inside a url': "a { background-image: url(\"data:image/svg+xml,%3Csvg fill='%23ff0000'/%3E\"); }",
    'skin rule': '[data-skin="fjord"] a { background: var(--ui-muted); }',
    'old skin rule': '[data-bp-theme=ember] a { color: var(--ui-foreground); }',
    'scheme rule': '[data-color-scheme="dark"] a { color: var(--ui-foreground); }',
    'theme rule': '[data-theme="dark"] a { color: var(--ui-foreground); }',
    'scheme media query': '@media (prefers-color-scheme: dark) { a { color: var(--ui-foreground); } }',
    'tint made in the part': 'a { background: color-mix(in oklab, var(--ui-primary) 88%, var(--ui-foreground)); }',
    'own focus ring': 'a:focus-visible { border-color: var(--ui-ring-border); }',
    'own outline': 'a { outline: 2px solid var(--ui-ring); }',
    'url image': 'a { background-image: url("photo.png"); }',
    'data svg with its own colour': "a { background-image: url(\"data:image/svg+xml,%3Csvg fill='black'/%3E\"); }",
  }
  for (const [what, css] of Object.entries(bad)) {
    it(`refuses a ${what}`, () => {
      expect(lintPartCss(css).length).toBeGreaterThan(0)
    })
  }

  it('allows variables, keywords and comments that name colours or skins', () => {
    const css = `/* red on #fff in [data-skin="x"] is wrong */
      [data-slot="button"] {
        color: var(--ui-foreground);
        background: var(--bark-primary-hover);
        border-color: transparent;
        fill: currentColor;
        --bark-button-icon: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='currentColor'/%3E");
        --bark-button-height: 2rem;
        height: var(--bark-button-height);
      }`
    expect(lintPartCss(css)).toEqual([])
  })
})
