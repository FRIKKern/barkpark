import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { lintPartCss, PLACE_VARIABLES } from '../build/css-lint.mjs'
import { SLOTS } from '../check/placement.mjs'
import { EXTRA, KEYFRAMES, PHONE, PHONE_ONLY } from '../build/vocabulary.mjs'
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
    'bitmap whose url holds a semicolon': 'a { background-image: url(data:image/png;base64,iVBORw0KGgo); }',
    'quoted svg whose url holds a semicolon and its own colour': "a { background-image: url(\"data:image/svg+xml;utf8,<svg fill='black'/>\"); }",
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
    ['mix-blend-mode', 'a { mix-blend-mode: screen; }'],
    ['clip-path', 'a { clip-path: inset(50%); }'],
    ['mask-image', 'a { mask-image: linear-gradient(transparent, transparent); }'],
    ['text-indent', 'a { text-indent: -999px; }'],
    ['visibility', 'a { visibility: hidden; }'],
    ['-webkit-text-fill-color', 'a { -webkit-text-fill-color: var(--ui-background); }'],
    ['background-clip', 'a { background-clip: text; }'],
    ['zoom', 'a { zoom: 0.1; }'],
    ['text-decoration-thickness', 'a { text-decoration-thickness: 0.9em; }'],
    ['text-shadow', 'a { text-shadow: 0 0 2px currentColor; }'],
  ]) {
    it(`refuses ${prop}, and nothing in a part can excuse it`, () => {
      expect(lintPartCss(css).join('\n')).toMatch(new RegExp(`line 1: ${prop} is outside part\\.css's vocabulary`))
      expect(lintPartCss(css, { [prop]: 'the reason, in one line' }).join('\n')).toMatch(/outside part\.css's vocabulary/)
    })
  }

  it('takes a property beyond the vocabulary only at the values EXTRA gives it', () => {
    expect(EXTRA).toEqual({ filter: ['none'] })
    expect(lintPartCss('a { filter: none; }')).toEqual([])
    expect(lintPartCss('a { filter: opacity(0.1); }').join()).toMatch(/line 1: filter: opacity\(0\.1\); part\.css may only set filter to none/)
  })

  it('refuses any escape, and keyframes of its own (a part names the shared ones in base.css)', () => {
    expect(lintPartCss(String.raw`@\6d edia (min-width: 1600px) { a { gap: 1px; } }`).join()).toMatch(/line 1: a backslash/)
    expect(lintPartCss(String.raw`a { fil\000074er: blur(2px); }`).join()).toMatch(/line 1: a backslash/)
    expect(lintPartCss('/* a \\ in a comment */ a { gap: 1px; }')).toEqual([])
    expect(lintPartCss('@keyframes x { to { color: var(--ui-primary); } }').join()).toMatch(/line 1: @keyframes x: a part defines no keyframes/)
    expect(lintPartCss('} a { box-shadow: none; } @layer bark-parts {').join()).toMatch(/line 1: a \} with no \{ before it/)
    expect(lintPartCss('a { gap: 1px;').join()).toMatch(/a \{ is never closed/)
  })

  it('lets only layout and type change at phone width', () => {
    const r = '@media (max-width: 600px) { [data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); } }'
    expect(lintPartCss(r).join()).toMatch(/--bark-button-fg inside @media \(max-width: 600px\): only layout and type/)
    expect(lintPartCss('@media (max-width: 600px) { a { color: var(--ui-x); } }').join()).toMatch(/color inside @media/)
    expect(lintPartCss('@media (max-width: 600px) { a { flex-direction: column; padding: 0.5rem; } }')).toEqual([])
    for (const p of ['color', 'background', 'border-color', 'opacity', 'box-shadow', 'text-decoration-color']) expect(PHONE_ONLY.has(p)).toBe(false)
  })

  it('shares keyframes from base.css that only turn their element', () => {
    const base = readFileSync(join(import.meta.dirname, '..', 'css', 'base.css'), 'utf8')
    const defined = [...base.matchAll(/@keyframes\s+([\w-]+)\s*\{((?:[^{}]|\{[^{}]*\})*)\}/g)]
    expect(defined.map((m) => m[1]).sort()).toEqual([...KEYFRAMES].sort())
    for (const m of defined) for (const d of m[2].matchAll(/([\w-]+)\s*:/g)) expect(['rotate', 'transform']).toContain(d[1])
  })

  it('takes content only as "" or none, and no thickness through the text-decoration shorthand', () => {
    for (const ok of ['a::after { content: ""; }', "a::after { content: ''; }", 'a::after { content: none; }']) expect(lintPartCss(ok)).toEqual([])
    expect(lintPartCss('a::after { content: "Cancel"; }').join()).toMatch(/line 1: content: "Cancel"; part\.css may only set content to "" or none/)
    expect(lintPartCss('a::after { content: attr(title); }').join()).toMatch(/may only set content/)
    expect(lintPartCss('a { text-decoration: underline; }')).toEqual([])
    expect(lintPartCss('a { text-decoration: line-through 0.9em; }').join()).toMatch(/line 1: text-decoration: line-through 0\.9em sets a thickness/)
  })

  it('takes a font size only from a variable that holds a readable size', () => {
    expect(lintPartCss('a { font-size: 0; }').join()).toMatch(/line 1: font-size .*var\(--bark-/)
    expect(lintPartCss('a { font-size: 12px; }').join()).toMatch(/line 1: font-size/)
    expect(lintPartCss('a { font: 0/0 a; }').join()).toMatch(/line 1: font is outside/)
    expect(lintPartCss('a { --bark-a-text: 0; font-size: var(--bark-a-text); }').join()).toMatch(/line 1: --bark-a-text .*0\.75rem or more/)
    expect(lintPartCss('a { --bark-a-text: 0.875rem; font-size: var(--bark-a-text); }')).toEqual([])
  })

  it('reads, apart from the skin, only a place UI SDK writes on a piece (check/placement.mjs SLOTS), with no fallback', () => {
    expect(lintPartCss('a { left: var(--active-tab-left); width: var(--segmented-control-indicator-width); }')).toEqual([])
    expect(lintPartCss('a { left: var(--active-tab-lefts); }').join()).toMatch(/line 1: left reads --active-tab-lefts/)
    expect(lintPartCss('a { left: var(--anchor-width); }').join()).toMatch(/line 1: left reads --anchor-width/)
    expect(lintPartCss('a { left: var(--active-tab-left, 0); }').join()).toMatch(/line 1: left gives --active-tab-left a fallback/)
    for (const prop of ['color', 'background', 'border-color', 'fill', 'box-shadow'])
      expect(lintPartCss(`a { ${prop}: var(--active-tab-left); }`).join(), prop).toMatch(new RegExp(`line 1: ${prop} reads --active-tab-left, a place UI SDK writes on a piece; a colour reads only`))
  })
  it('takes the places it allows from check/placement.mjs SLOTS itself: every custom property a slot names, and no other', () => {
    expect([...PLACE_VARIABLES].sort()).toEqual(SLOTS.flatMap((s) => s.writes.map((w) => w.property)).filter((p) => p.startsWith('--')).sort())
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

// The forms a part sheet is written in, so its text reads one way in the lint, in the check's text reader and in
// the browser (build/css-lint.mjs sheetForms). Outside them, each is refused by name; inside them, nothing is.
describe('the forms a part sheet is written in', () => {
  const refuses = {
    'a url( with no quoted string straight after it': ['a { --i: url(data:image/svg+xml,%3Csvg/%3E); }', /line 1: url\( with no quoted string straight after it/],
    'a url( with a space before its string': ['a { --i: url( "data:image/svg+xml,%3Csvg/%3E"); }', /line 1: url\( with no quoted string/],
    'a string that runs past the end of its line': ['a {\n  --y: "a\n; }', /line 2: a string runs past the end of its line/],
    'a comment inside a value': ['a { gap: 0 /* x */; }', /line 1: a comment inside a selector, a condition or a value/],
    'a comment inside a selector': ['a /* x */ b { gap: 0; }', /line 1: a comment inside a selector, a condition or a value/],
    'a comment never closed': ['a { gap: 0; } /* x', /line 1: a comment is never closed/],
    'a backslash outside a string': [String.raw`a\:b { gap: 0; }`, /line 1: a backslash/],
  }
  for (const [what, [css, re]] of Object.entries(refuses)) it(`refuses ${what}`, () => expect(lintPartCss(css).join('\n')).toMatch(re))

  it('reads a /* inside a quoted string or a quoted url( as no comment, and passes comments between declarations and rules', () => {
    expect(lintPartCss('/* top */\na { /* first */ gap: 0; /* after */ }\n/* between */\nb { gap: 0; }')).toEqual([])
    expect(lintPartCss(`a { --i: url("data:image/svg+xml,%3Csvg fill='currentColor'/%3E/*"); } b { color: #fff; } c { --j: url("*/"); }`).join('\n')).toMatch(/color uses a hex colour \(#fff\)/)
  })
})
