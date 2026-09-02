// The TAIL renderers (mob-zb-s7-tail-media): form/questionnaire (D46a), the
// native equation (D45), and the two degrade cards video/asciicast (D46d). The
// turn-level DEGRADE_ONLY seam (D47) is pinned where it lives, in
// chatBlocks.test.tsx beside the rest of the two-phase floor.
//
// FOUR law families, each chosen because a plausible edit breaks it silently:
//
//   1. THE PARSER IS THE TWIN'S PARSER. The equation leg is a transliteration
//      of js/packages/react/src/blocks/math.ts, so it is pinned AGAINST that
//      module rather than against a hand-copied expectation: every input below
//      is rendered by BOTH legs and the MathML the web emits is compared with
//      the MathML this leg's atom tree stands for. A grammar drift on either
//      side reds — including the 43-macro table, which is checked entry by
//      entry instead of by a count a copy-paste could keep truthful while
//      corrupting a symbol.
//   2. THE HONEST CEILING. An unknown macro stays raw source; an equation with
//      no tex says so; an option-less control still draws; an empty form is a
//      labeled box. Every one of these is a place a "tidier" edit produces a
//      blank or a fabrication.
//   3. THE VIDEO/ASCIICAST ASYMMETRY. Src-less video renders NOTHING and
//      src-less asciicast renders anyway. That reads as an inconsistency, so it
//      is pinned side by side with its reason.
//   4. NO WEBVIEW, NO CDN (D45). Proven from the module SOURCE, not from its
//      behavior — a KaTeX-backed renderer would pass every render assertion
//      above.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import type { ReactElement, ReactNode } from 'react'
import { Linking } from 'react-native'

// The web twin, imported as the ORACLE for the parser transliteration: this is
// the published package the Next.js surface renders papers with, so the
// comparison is against shipped behavior rather than against a copy of it.
import { renderPortableDocument } from '@barkpark/react'

import { renderBlockNative, resetUnknownBlockLog } from '../src/papers/portabledoc/blocks'
import { MACROS, texToMathAtoms, type MathAtom } from '../src/papers/portabledoc/blocks/math'
import type { BlockCtx } from '../src/papers/portabledoc/register'
import { light, type Theme } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light
const paper: BlockCtx = { theme }
const served: BlockCtx = { theme, serverBase: 'https://bp.test' }

/* ── element walking ────────────────────────────────────────────────────────── */

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

/** A best-effort display name for an element type. Host strings pass through;
 * RN's forwardRef/memo wrappers carry displayName. */
function typeName(t: unknown): string {
  if (typeof t === 'string') return t
  if (typeof t === 'function') return (t as { displayName?: string; name?: string }).displayName ?? t.name
  if (t !== null && typeof t === 'object') {
    const o = t as { displayName?: string; render?: { name?: string }; type?: unknown }
    if (typeof o.displayName === 'string') return o.displayName
    if (o.render !== undefined && typeof o.render.name === 'string') return o.render.name
    if (o.type !== undefined) return typeName(o.type)
  }
  return String(t)
}

interface Walk {
  text: string
  styles: Record<string, unknown>[]
  /** Every element's resolved type name, in tree order. */
  types: string[]
  /** Every prop name seen anywhere in the tree. */
  props: Set<string>
  /** Every image source uri, in tree order. */
  images: string[]
  /** Every onPress handler, in tree order. */
  presses: (() => void)[]
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (!isElement(node)) return
  const name = typeName(node.type)
  acc.types.push(name)
  const props = node.props as Record<string, unknown>
  for (const key of Object.keys(props)) acc.props.add(key)
  if (name === 'Image') {
    const source = props.source as { uri?: string } | undefined
    if (typeof source?.uri === 'string') acc.images.push(source.uri)
  }
  if (typeof props.onPress === 'function') acc.presses.push(props.onPress as () => void)
  const raw = props.style
  if (raw !== undefined) {
    const parts = Array.isArray(raw) ? raw : [raw]
    acc.styles.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
  }
  walkNode(props.children as ReactNode, acc)
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', styles: [], types: [], props: new Set(), images: [], presses: [] }
  walkNode(node, acc)
  return acc
}

function render(block: Record<string, unknown>, ctx: BlockCtx = paper): ReactNode {
  return renderBlockNative(block, ctx, 0)
}

function text(block: Record<string, unknown>, ctx: BlockCtx = paper): string {
  return walk(render(block, ctx)).text
}

/** The prop names in a tree that look like event handlers — the shape a
 * "render-only" claim has to survive. */
function handlers(w: Walk): string[] {
  return [...w.props].filter((p) => /^on[A-Z]/.test(p)).sort()
}

/* ══ 1. form / questionnaire (D46a) ═════════════════════════════════════════ */

const q = (over: Record<string, unknown>): Record<string, unknown> => ({ id: 'q', prompt: 'P?', ...over })
const formOf = (...questions: Record<string, unknown>[]): Record<string, unknown> => ({
  type: 'form',
  questions,
})

describe('form / questionnaire — render-only question cards', () => {
  it('renders the prompt BOLD and both context lines, rationale bare + recommendation prefixed', () => {
    const w = walk(render(formOf(q({ type: 'yesno', rationale: 'WHY WE ASK', recommendation: 'DO THIS' }))))
    expect(w.text).toContain('P?')
    expect(w.text).toContain('WHY WE ASK')
    // The prefix is what distinguishes advice from context. Folding the two
    // lines into one — or dropping either — loses that, and both twins keep it.
    expect(w.text).toContain('Recommendation: DO THIS')
    expect(w.text).not.toContain('Recommendation: WHY WE ASK')
    expect(w.styles.some((s) => s.fontWeight === '700')).toBe(true)
    // Both context lines are DIM; the prompt is not.
    expect(w.styles.filter((s) => s.color === theme.textMuted).length).toBeGreaterThanOrEqual(2)
  })

  it('omits a context line that is absent or empty — never a stray prefix', () => {
    expect(text(formOf(q({ type: 'yesno' })))).not.toContain('Recommendation')
    expect(text(formOf(q({ type: 'yesno', recommendation: '' })))).not.toContain('Recommendation')
    // A non-string rationale is not stringified into the card either.
    expect(text(formOf(q({ type: 'yesno', rationale: 42 })))).not.toContain('42')
  })

  it('draws the static control vocabulary per kind — radios, checkboxes, ladder, placeholder', () => {
    expect(text(formOf(q({ type: 'yesno' })))).toContain('( ) Yes')
    expect(text(formOf(q({ type: 'yesno' })))).toContain('( ) No')
    expect(text(formOf(q({ type: 'single', options: ['Postgres', 'SQLite'] })))).toContain('( ) Postgres')
    expect(text(formOf(q({ type: 'multi', options: ['a', 'b'] })))).toContain('[ ] b')
    expect(text(formOf(q({ type: 'scale', scale: { min: 1, max: 5 } })))).toContain('1 2 3 4 5')
    expect(text(formOf(q({ type: 'text' })))).toContain('[ … ]')
    // The catch-all: an unknown kind degrades to the placeholder, never a crash
    // and never an empty card (both twins' default arm).
    expect(text(formOf(q({ type: 'holograph' })))).toContain('[ … ]')
    expect(text(formOf(q({})))).toContain('[ … ]')
  })

  it('a choice control with NO options still draws one (the TUI arm, not the web empty div)', () => {
    const single = text(formOf(q({ type: 'single' })))
    expect(single).toContain('( ) Yes')
    expect(single).toContain('( ) No')
    expect(text(formOf(q({ type: 'multi' })))).toContain('[ ] Option')
    // Non-string options coerce through `str`, never painted as objects.
    expect(text(formOf(q({ type: 'single', options: [{ nope: 1 }, 'Yep'] })))).not.toContain('object')
  })

  it('SUMMARIZES a scale whose span exceeds 100 rungs instead of drawing them', () => {
    // 101 stacked rows on a phone is the hostile render this guard exists for;
    // scaleLadder makes the same call at the same threshold.
    const wide = text(formOf(q({ type: 'scale', scale: { min: 1, max: 500 } })))
    expect(wide).toContain('1 … 500')
    expect(wide).not.toContain('1 2 3')
    // AT the threshold it still enumerates: span 100 = 101 rungs, the last one
    // drawn. (A guard firing one early would still pass a "> 100 summarizes"
    // test on its own.)
    const edge = text(formOf(q({ type: 'scale', scale: { min: 0, max: 100 } })))
    expect(edge).toContain('100')
    expect(edge).not.toContain('…')
    // An inverted range is the placeholder, not an empty ladder.
    expect(text(formOf(q({ type: 'scale', scale: { min: 9, max: 2 } })))).toContain('[ … ]')
    // Bounds coerce like scaleBound: integer strings count, junk keeps the default.
    expect(text(formOf(q({ type: 'scale', scale: { min: '2', max: '4' } })))).toContain('2 3 4')
    expect(text(formOf(q({ type: 'scale', scale: { min: 1.5, max: 'x' } })))).toContain('1 2 3 4 5')
  })

  it('an EMPTY form is a labeled box, never a vanished block', () => {
    for (const questions of [[], undefined, 'nope', [7, 'x']]) {
      expect(text({ type: 'form', questions })).toContain('(empty form)')
    }
  })

  it('questionnaire is a PURE ALIAS — identical tree, and not an identity alias', () => {
    const questions = [q({ type: 'multi', options: ['a'], rationale: 'r', recommendation: 'x' })]
    const asForm = walk(render({ type: 'form', questions }))
    const asQuestionnaire = walk(render({ type: 'questionnaire', questions }))
    expect(asQuestionnaire.text).toBe(asForm.text)
    expect(asQuestionnaire.styles).toEqual(asForm.styles)
    expect(asQuestionnaire.types).toEqual(asForm.types)
    // The web differentiates the two by a container CLASS; React Native has no
    // class names, so here the alias is total — including the empty arm. It
    // stays a DISTINCT function so the registry's function-identity alias
    // tripwire keeps telling the truth about which keys are the same renderer.
    expect(text({ type: 'questionnaire', questions: [] })).toContain('(empty form)')
  })

  it('renders ZERO controls — no surface promises a submit (react forms.ts:4-7)', () => {
    const w = walk(render(formOf(q({ type: 'text' }), q({ type: 'single', options: ['a'] }))))
    // Text and View only: an input of any kind here would be the first surface
    // to offer an answer control on a read path.
    expect([...new Set(w.types)].sort()).toEqual(['Text', 'View'])
    expect(handlers(w)).toEqual([])
  })
})

/* ══ 2. equation — the native parser (D45) ══════════════════════════════════ */

/** The MathML the web twin emits for one tex source, unwrapped from its
 * <div class="bp-equation"><math>…</math></div> envelope. */
function twinMathMl(tex: string): string {
  const html = renderPortableDocument([{ type: 'equation', tex } as never])
  const m = /<math[^>]*>([\s\S]*)<\/math>/.exec(html)
  if (m === null) throw new Error(`twin emitted no <math> for ${tex}: ${html}`)
  return m[1] as string
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** The MathML this leg's atom tree STANDS FOR — the same tags at the same
 * grammar positions the web emitter uses, so the two can be compared directly.
 *
 * SLOT <mrow>s ARE EMITTED, and that is the whole point (task-ce0b4827a6bff147).
 * This projection used to omit every <mrow>, and a `stripRows` helper deleted
 * them from the twin's side too, on the stated grounds that "mrow carries no
 * meaning". That was FACTUALLY WRONG: <mrow> is the ONLY thing encoding the
 * mfrac numerator/denominator boundary in MathML, because the two slots sit
 * adjacent with no delimiter between them. `<mfrac>` + `a+b` + `c` + `</mfrac>`
 * serialises identically whether the split is (a+b)/(c) or (a+b·c)/(), so the
 * corpus below could not see a slot-boundary drift at all.
 *
 * MEASURED, not argued. With the old helper in place, a parser mutation making
 * a NESTED-frac numerator swallow its denominator — `\frac{\frac{a}{b}}{c}`
 * parsed as `(a/b · c) / ()`, mathematically wrong — passed the ENTIRE mobile
 * suite: 51 suites, 892 tests, all green. The sibling assertion below pins the
 * flagship `\frac{a+b}{c}` tree directly and does catch a mis-split THERE, but
 * it is one hand-written tree for one input; every other frac and script slot
 * in the 21-row corpus was blind.
 *
 * WHERE THE ROWS GO, read off the twin's actual output rather than assumed:
 *   • a TOP-LEVEL row emits no wrapper — the twin renders `x + y = z` flat;
 *   • a nested row (an explicit `{…}` group) emits <mrow>, as the twin does;
 *   • EVERY mfrac and script slot is wrapped, as the twin does — including an
 *     absent denominator, which the twin emits as an empty <mrow>.
 *
 * THERE IS NO RESIDUAL DIFFERENCE, and the comparison below is therefore a RAW
 * string equality — no normalisation on either side. An earlier revision kept a
 * `collapse` helper here (fold an <mrow> whose sole child is an <mrow>) on the
 * stated grounds that "the twin double-wraps a `{…}` group AND wraps it again
 * per slot, so it emits <mrow><mrow>…</mrow></mrow> where this leg emits one
 * level fewer". MEASURED against the BUILT @barkpark/react dist, that was
 * false: this leg double-wraps in exactly the same places, because `slot()`
 * wraps and the nested `row` atom inside it wraps again. `\frac{a}{b}` is
 * <mfrac><mrow><mrow><mi>a</mi></mrow></mrow>… on BOTH legs. All 21 corpus
 * inputs and all 43 macros were byte-identical with the collapse REMOVED —
 * 64/64 — so the helper was an identity function that could only ever start
 * absorbing a real drift (a gained or lost <mrow> nesting level, which is
 * precisely mob-zb-bl-react-mrow-parity's failure mode). It is deleted. Do not
 * reintroduce a normaliser here: if the two legs disagree, that IS the finding.
 */
function atomsToMathMl(a: MathAtom, top = false): string {
  switch (a.kind) {
    case 'sym':
      return `<${a.mathml}>${escapeHtml(a.text)}</${a.mathml}>`
    case 'raw':
      return `<mtext>${escapeHtml(a.text)}</mtext>`
    case 'none':
      return ''
    case 'row': {
      const inner = a.items.map((i) => atomsToMathMl(i)).join('')
      return top ? inner : `<mrow>${inner}</mrow>`
    }
    case 'frac':
      return `<mfrac>${slot(a.numer)}${slot(a.denom)}</mfrac>`
    case 'script': {
      const base = slot(a.base)
      const sup = a.sup === undefined ? '' : slot(a.sup)
      const sub = a.sub === undefined ? '' : slot(a.sub)
      if (a.sup !== undefined && a.sub !== undefined) return `<msubsup>${base}${sub}${sup}</msubsup>`
      if (a.sup !== undefined) return `<msup>${base}${sup}</msup>`
      return `<msub>${base}${sub}</msub>`
    }
  }
}

/** One mfrac/script SLOT. ALWAYS wrapped, exactly as the twin wraps it — an
 * unwrapped slot is the boundary erasure this change exists to end. */
function slot(a: MathAtom): string {
  return `<mrow>${atomsToMathMl(a)}</mrow>`
}

describe('equation — the transliterated parser agrees with the web twin', () => {
  const CORPUS = [
    'x',
    'x + y = z',
    '1234',
    '3.14159',
    'x^2',
    'x_1',
    'x_1^2',
    'x^{2n}',
    '{a+b}',
    '\\frac{a}{b}',
    // THE input equation.go's regex rewriter is run-proven wrong on: a
    // multi-atom numerator. The parser groups it; a regex cannot.
    '\\frac{a+b}{c}',
    '\\frac{\\frac{a}{b}}{c}',
    '\\frac{a}{\\frac{b}{c}}',
    '\\sum_{i=1}^{n} i^2',
    '\\alpha \\beta \\Omega \\infty',
    '\\bogus',
    // The tolerated malformations, where a transliteration most easily drifts.
    '\\frac{a}',
    'a < b > c , d',
    'x^',
    'x^{}',
    '}stray{',
  ]

  it.each(CORPUS.map((t) => [t] as const))('emits the twin’s MathML for %s', (tex) => {
    // BYTE-EXACT, mrow intact, against the BUILT @barkpark/react dist that
    // apps/mobile resolves `@barkpark/react` to. No normalisation on either
    // side — see the note above atomsToMathMl for why there is none left.
    expect(atomsToMathMl(texToMathAtoms(tex), true)).toBe(twinMathMl(tex))
  })

  it('the MULTI-ATOM numerator is a real slot boundary, not a flattened run', () => {
    // THE case equation.go gets wrong, pinned on the TREE as well as through
    // the corpus comparison above. It was written when the corpus could NOT see
    // this — every <mrow> was deleted from both sides, and <mrow> is the only
    // thing encoding the mfrac slot boundary, so a numerator that swallowed the
    // denominator serialised to exactly the same string as a correct split
    // (`<mfrac><mi>a</mi><mo>+</mo><mi>b</mi><mi>c</mi></mfrac>` either way).
    //
    // The corpus CAN see it now (task-ce0b4827a6bff147: slot mrows are emitted
    // and the two sides are compared byte-exact instead of stripped). This
    // assertion is kept anyway, and deliberately: it names the specific tree for
    // the specific input equation.go gets wrong, so a reader learns WHAT the
    // right split is, not merely that two legs agree. The corpus proves
    // agreement; this proves correctness.
    const items = (texToMathAtoms('\\frac{a+b}{c}') as { items: MathAtom[] }).items
    expect(items).toHaveLength(1)
    const frac = items[0] as MathAtom
    expect(frac.kind).toBe('frac')
    expect((frac as { numer: MathAtom }).numer).toEqual({
      kind: 'row',
      items: [
        { kind: 'sym', text: 'a', mathml: 'mi' },
        { kind: 'sym', text: '+', mathml: 'mo' },
        { kind: 'sym', text: 'b', mathml: 'mi' },
      ],
    })
    expect((frac as { denom: MathAtom }).denom).toEqual({
      kind: 'row',
      items: [{ kind: 'sym', text: 'c', mathml: 'mi' }],
    })
  })

  it('the 43-macro table is the twin’s table, entry by entry', () => {
    // A count alone would survive a corrupted symbol; a symbol check alone
    // would survive a dropped entry. Both, plus the pinned size.
    expect(Object.keys(MACROS)).toHaveLength(43)
    for (const [name, symbol] of Object.entries(MACROS)) {
      expect(name.startsWith('\\')).toBe(true)
      // The twin resolves the same macro to the same glyph…
      expect(twinMathMl(name)).toBe(`<mi>${symbol}</mi>`)
      // …and so does this leg, through the real render.
      expect(text({ type: 'equation', tex: name })).toBe(symbol)
    }
  })

  it('an UNKNOWN macro stays raw TeX source — never a fabricated symbol', () => {
    expect(MACROS['\\aleph']).toBeUndefined()
    const w = walk(render({ type: 'equation', tex: '\\aleph' }))
    expect(w.text).toBe('\\aleph')
    // Muted and upright, so the reader can see it is un-typeset source.
    expect(w.styles.some((s) => s.color === theme.textMuted)).toBe(true)
  })

  it('mfrac STACKS with a rule; a nested frac stacks twice', () => {
    const rules = (n: ReactNode): number =>
      walk(n).styles.filter((s) => s.height === 1 && s.backgroundColor === theme.text).length
    expect(rules(render({ type: 'equation', tex: '\\frac{a}{b}' }))).toBe(1)
    expect(rules(render({ type: 'equation', tex: '\\frac{\\frac{a}{b}}{c}' }))).toBe(2)
    // The rule spans the wider row, which is what makes the stack read as a
    // fraction rather than as three centered runs.
    expect(
      walk(render({ type: 'equation', tex: '\\frac{a}{b}' })).styles.some(
        (s) => s.height === 1 && s.alignSelf === 'stretch',
      ),
    ).toBe(true)
    // The tree, independently of the pixels: the outer frac's NUMERATOR is the
    // inner frac, not a flattened sibling.
    const nested = texToMathAtoms('\\frac{\\frac{a}{b}}{c}')
    expect(nested.kind).toBe('row')
    const outer = (nested as { items: MathAtom[] }).items[0] as MathAtom
    expect(outer.kind).toBe('frac')
    const numer = (outer as { numer: MathAtom }).numer
    expect(numer.kind).toBe('row')
    expect((numer as { items: MathAtom[] }).items[0]?.kind).toBe('frac')
    expect((outer as { denom: MathAtom }).denom).toEqual({
      kind: 'row',
      items: [{ kind: 'sym', text: 'c', mathml: 'mi' }],
    })
  })

  it('scripts nest at the REDUCED step; the base keeps the register measure', () => {
    const sizes = (tex: string): number[] =>
      walk(render({ type: 'equation', tex }))
        .styles.map((s) => s.fontSize)
        .filter((n): n is number => typeof n === 'number')
    // Inline base is 15 (scale.md); a script is 12 (scale.xs).
    expect(sizes('x^2')).toContain(15)
    expect(Math.min(...sizes('x^2'))).toBe(12)
    expect(sizes('x')).not.toContain(12)
    // msubsup carries BOTH, stacked around the base.
    const script = (texToMathAtoms('x_1^2') as { items: MathAtom[] }).items[0] as MathAtom
    expect(script.kind).toBe('script')
    expect((script as { sup?: MathAtom }).sup).toBeDefined()
    expect((script as { sub?: MathAtom }).sub).toBeDefined()
    // The superscript is raised and the subscript dropped — the shift is a
    // margin inside a centered row, so it resolves into the styles.
    const w = walk(render({ type: 'equation', tex: 'x_1^2' }))
    expect(w.styles.some((s) => s.marginBottom === 6)).toBe(true)
    expect(w.styles.some((s) => s.marginTop === 6)).toBe(true)
  })

  it('honors display vs inline — measure and alignment both move', () => {
    const disp = walk(render({ type: 'equation', tex: 'x', display: true }))
    const inline = walk(render({ type: 'equation', tex: 'x' }))
    expect(disp.styles.some((s) => s.fontSize === 16)).toBe(true)
    expect(inline.styles.some((s) => s.fontSize === 15)).toBe(true)
    expect(disp.styles.some((s) => s.alignItems === 'center')).toBe(true)
    expect(inline.styles.some((s) => s.alignItems === 'flex-start')).toBe(true)
    // `display === true` exactly, like the twin: a truthy string does not
    // promote an inline equation to a centered display one.
    expect(
      walk(render({ type: 'equation', tex: 'x', display: 'block' })).styles.some((s) => s.fontSize === 15),
    ).toBe(true)
  })

  it('an equation with no tex says so, and identifiers render italic', () => {
    for (const tex of [undefined, '', '   ', null]) {
      expect(text({ type: 'equation', tex })).toBe('equation — no tex source')
    }
    // <mi> is italic by MathML convention; <mo> and <mn> are upright.
    const italics = walk(render({ type: 'equation', tex: 'x + 1' })).styles.filter(
      (s) => s.fontStyle === 'italic',
    )
    expect(italics).toHaveLength(1)
  })

  it('is T1 NATIVE — the module imports no WebView, no KaTeX, no network (D45)', () => {
    // Behavior cannot prove this: a KaTeX-backed renderer would pass every
    // assertion above. The SOURCE can — with the comments stripped first, since
    // this file's own header NAMES the things it forswears.
    const src = readFileSync(
      join(__dirname, '..', 'src', 'papers', 'portabledoc', 'blocks', 'math.tsx'),
      'utf8',
    )
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
    for (const forbidden of [/webview/i, /katex/i, /mathjax/i, /\bcdn\b/i, /https?:\/\//, /\brequire\(/]) {
      expect(code).not.toMatch(forbidden)
    }
    // The whole dependency surface, enumerated: two React modules and three
    // local ones. A fourth import is a decision, so it should show in a diff.
    const imports = [...code.matchAll(/^import[^']*'([^']+)'/gm)].map((m) => m[1])
    expect(imports.sort()).toEqual([
      '../../../ui/typography',
      '../model',
      '../register',
      'react',
      'react-native',
    ])
  })
})

/* ══ 3. video / asciicast — the two degrade cards (D46d) ════════════════════ */

describe('video — a poster-backed degrade card, and NOTHING without a src', () => {
  it('a SRC-LESS video renders nothing at all — the cross-surface parity law', () => {
    // Not a dashed box, not an empty card: the web returns '' and the TUI
    // returns nil, because an asset-less video block is editor scaffolding.
    resetUnknownBlockLog()
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      for (const src of [undefined, '', '   ', null, {}]) {
        expect(render({ type: 'video', src })).toBeNull()
      }
      // …and it is NOT reaching the unknown-block fallback to get there.
      expect(warn).not.toHaveBeenCalled()
    } finally {
      warn.mockRestore()
    }
  })

  it('labels its ceiling: "▶ Video", the caption-track count, the open affordance', () => {
    const base = { type: 'video', src: 'https://x.test/a.mp4' }
    expect(text(base)).toContain('▶ Video')
    expect(text(base)).toContain('· open in browser')
    expect(text(base)).not.toContain('caption track')
    expect(text({ ...base, captions: [{ lang: 'en' }] })).toContain('· 1 caption track')
    expect(text({ ...base, captions: [{ lang: 'en' }, { lang: 'nb' }] })).toContain('· 2 caption tracks')
    // Only MAPS count as tracks (both twins filter): a stray string is not one.
    expect(text({ ...base, captions: ['en', 7] })).not.toContain('caption track')
    // The caption keeps the shared "Figure N." bold run-in.
    expect(text({ ...base, caption: 'Figure 3. the clip' })).toContain('Figure 3.')
  })

  it('resolves the poster through the IMAGE pipeline, root-relative src included', () => {
    const w = walk(render({ type: 'video', src: '/media/files/a.mp4', poster: '/media/files/p.png' }, served))
    expect(w.images).toEqual(['https://bp.test/media/files/p.png'])
    // No poster → no Image, and the card still labels itself.
    expect(walk(render({ type: 'video', src: 'https://x.test/a.mp4' })).images).toEqual([])
    // An unresolvable poster does not take the card down with it.
    expect(walk(render({ type: 'video', src: 'https://x.test/a.mp4', poster: '/p.png' })).images).toEqual([])
  })

  it('taps through to the platform browser via Linking', () => {
    const open = jest.spyOn(Linking, 'openURL').mockImplementation(() => Promise.resolve(true))
    try {
      const w = walk(render({ type: 'video', src: '/media/files/a.mp4' }, served))
      expect(w.presses).toHaveLength(1)
      w.presses[0]?.()
      expect(open).toHaveBeenCalledWith('https://bp.test/media/files/a.mp4')
    } finally {
      open.mockRestore()
    }
  })

  it('an UNOPENABLE src keeps the card but drops the tap and the promise', () => {
    // A relative src with no serverBase, and a hostile scheme. The block exists,
    // so the card stays (linkText's precedent: the label never vanishes) — but
    // "open in browser" would be a lie, so it is withheld along with the tap.
    for (const src of ['/media/files/a.mp4', 'javascript:alert(1)']) {
      const w = walk(render({ type: 'video', src }))
      expect(w.text).toContain('▶ Video')
      expect(w.text).not.toContain('open in browser')
      expect(w.presses).toHaveLength(0)
    }
  })

  it('the unopenable card STATES its ceiling in words, poster or not', () => {
    // Withholding "open in browser" is necessary but not sufficient. With a
    // poster resolved and no label, the card is a ▶ glyph over a 16:9 thumbnail
    // with no Pressable — the play-button idiom with every counter-signal
    // removed, and a tap that silently does nothing. The honest-ceiling doctrine
    // (hardblocks.go:14-20) wants a box that SAYS what it cannot do.
    const posterCase = walk(
      render({ type: 'video', src: 'javascript:alert(1)', poster: 'https://cdn.test/p.png' }),
    )
    expect(posterCase.text).toContain('cannot be opened here')
    expect(posterCase.presses).toHaveLength(0)
    // …and with no poster either, so the label is the arm's property, not the
    // poster's.
    expect(walk(render({ type: 'video', src: 'javascript:alert(1)' })).text).toContain(
      'cannot be opened here',
    )
    // The OPENABLE arm keeps its own words and never borrows this phrase.
    const ok = walk(render({ type: 'video', src: '/media/files/a.mp4' }, served))
    expect(ok.text).toContain('open in browser')
    expect(ok.text).not.toContain('cannot be opened')
  })
})

describe('asciicast — a terminal-tinted card that renders even src-less', () => {
  it('renders WITHOUT a src — the deliberate asymmetry with video', () => {
    // Both twins do this: asciicastRenderer builds its box before it reads src.
    // A cast block is authored ABOUT a recording, so its duration and dimensions
    // are content in their own right; a src-less video block carries nothing.
    const w = walk(render({ type: 'asciicast' }))
    expect(w.text).toContain('▶ Asciicast')
    expect(w.text).not.toContain('open in browser')
    expect(render({ type: 'video' })).toBeNull()
  })

  it('lifts its metadata from the flat keys AND from an asciicast-v2 header', () => {
    expect(text({ type: 'asciicast', duration: 95, cols: 120, rows: 40 })).toContain('1:35 · 120x40')
    // The v2 cast header nests width/height (and sometimes duration).
    expect(text({ type: 'asciicast', header: { width: 80, height: 24, duration: 5 } })).toContain('0:05 · 80x24')
    // Flat keys win; a zero or absent one falls through to the header (attrInt's
    // sentinel defaults behave the same way on the Go side).
    expect(text({ type: 'asciicast', cols: 0, header: { width: 80, height: 24 } })).toContain('80x24')
    // Partial metadata shows what is known and omits the rest — never zeros.
    expect(text({ type: 'asciicast', duration: 61 })).toBe('▶ Asciicast · 1:01')
    expect(text({ type: 'asciicast', cols: 90 })).toBe('▶ Asciicast')
    // Nothing known → no suffix at all.
    expect(text({ type: 'asciicast', src: 'https://x.test/s.cast' })).toBe('▶ Asciicast · open in browser')
  })

  it('is tinted like a terminal and taps out to the browser', () => {
    const open = jest.spyOn(Linking, 'openURL').mockImplementation(() => Promise.resolve(true))
    try {
      const w = walk(render({ type: 'asciicast', src: 'https://x.test/s.cast', caption: 'a session' }))
      expect(w.styles.some((s) => s.backgroundColor === theme.codeBg)).toBe(true)
      expect(w.styles.some((s) => s.color === theme.codeFg)).toBe(true)
      expect(w.styles.some((s) => s.fontFamily === 'monospace')).toBe(true)
      expect(w.text).toContain('a session')
      w.presses[0]?.()
      expect(open).toHaveBeenCalledWith('https://x.test/s.cast')
    } finally {
      open.mockRestore()
    }
  })

  it('neither card FAKES the capability it lacks (the honest-ceiling doctrine)', () => {
    // No player, no scrubber, no autoplay: both cards are labeled boxes that
    // hand off to the platform. The only handler either one carries is the tap.
    for (const block of [
      { type: 'video', src: 'https://x.test/a.mp4', poster: 'https://x.test/p.png' },
      { type: 'asciicast', src: 'https://x.test/s.cast' },
    ]) {
      const w = walk(render(block))
      expect(w.types).not.toContain('WebView')
      expect(handlers(w)).toEqual(['onPress'])
    }
  })
})
