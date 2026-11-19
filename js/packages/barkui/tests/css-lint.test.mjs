import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { lintPartCss } from '../build/css-lint.mjs'
import { PHONE } from '../build/vocabulary.mjs'
import { discoverParts } from '../build/parts.mjs'

const parts = discoverParts(join(import.meta.dirname, '..', 'parts'))

describe('every real part.css', () => {
  for (const p of parts) {
    it(`${p.name}/part.css has no colour literal and reads only --ui-* / --bark-*`, () => {
      expect(lintPartCss(readFileSync(join(p.dir, 'part.css'), 'utf8'), p.json.allow)).toEqual([])
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

  // R4: part.css is written in a small vocabulary; anything else is named in part.json with a reason.
  for (const [prop, css] of [
    ['filter', 'a { filter: opacity(0.1); }'],
    ['mix-blend-mode', 'a { mix-blend-mode: screen; }'],
    ['clip-path', 'a { clip-path: inset(50%); }'],
    ['mask-image', 'a { mask-image: linear-gradient(transparent, transparent); }'],
    ['text-indent', 'a { text-indent: -999px; }'],
    ['visibility', 'a { visibility: hidden; }'],
    ['-webkit-text-fill-color', 'a { -webkit-text-fill-color: var(--ui-background); }'],
    ['background-clip', 'a { background-clip: text; }'],
    ['zoom', 'a { zoom: 0.1; }'],
  ]) {
    it(`refuses ${prop} unless part.json names it with a reason`, () => {
      expect(lintPartCss(css).join('\n')).toMatch(new RegExp(`line 1: ${prop} is outside part\\.css's vocabulary.*part\\.json "allow"`))
      expect(lintPartCss(css, { [prop]: 'the reason, in one line' })).toEqual([])
    })
  }

  it('takes a font size only from a variable that holds a readable size', () => {
    expect(lintPartCss('a { font-size: 0; }').join()).toMatch(/line 1: font-size .*var\(--bark-/)
    expect(lintPartCss('a { font-size: 12px; }').join()).toMatch(/line 1: font-size/)
    expect(lintPartCss('a { font: 0/0 a; }').join()).toMatch(/line 1: font is outside/)
    expect(lintPartCss('a { --bark-a-text: 0; font-size: var(--bark-a-text); }').join()).toMatch(/line 1: --bark-a-text .*0\.75rem or more/)
    expect(lintPartCss('a { --bark-a-text: 0.875rem; font-size: var(--bark-a-text); }')).toEqual([])
  })

  // R2: every view part.css can target is one the check renders.
  it('allows @media only for reduced motion (motion properties inside) and the named phone breakpoint', () => {
    expect(lintPartCss('@media (prefers-reduced-motion: reduce) { a { transition: none; animation: none; scroll-behavior: auto; } }')).toEqual([])
    expect(lintPartCss(`@media ${PHONE} { a { gap: 0; } }`)).toEqual([])
    expect(lintPartCss('@media (prefers-reduced-motion: no-preference) {\n a { color: var(--ui-background); } }').join()).toMatch(/line 2: color inside @media \(prefers-reduced-motion.*only transition, animation and scroll-behavior/)
    for (const css of ['@media (max-width: 500px) { a { gap: 0; } }', '@media print { a { gap: 0; } }', '@container (width < 300px) { a { gap: 0; } }', '@supports (display: grid) { a { gap: 0; } }'])
      expect(lintPartCss(css).join(), css).toMatch(/line 1: @(media|container|supports) .*not a view the check renders/)
  })
})
