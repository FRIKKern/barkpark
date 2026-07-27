// math family (charter D49) — `equation`, rendered T1 NATIVE (charter D45):
// no WebView, no KaTeX, no CDN, no new dependency. The tokenizer and the
// recursive-descent parser below are a TRANSLITERATION of
// js/packages/react/src/blocks/math.ts — same 43-entry macro table, same
// operator set, same grammar, same honest fallback — with one substitution: the
// parser builds an ATOM TREE instead of a MathML string, and the tree renders
// to React Native views. MathML's own element names are the tree's vocabulary,
// so the two legs stay diffable line for line.
//
// WHY NOT THE OTHER TWIN. internal/pdrender/equation.go is a REGEX REWRITER,
// not a parser, and it is run-proven mathematically wrong on the commonest
// input there is: `\frac{a+b}{c}` rewrites to a form that loses the numerator's
// grouping. A regex cannot balance braces, so no amount of patching gets it to
// nested `\frac`. Transliterating it would have imported that bug into a third
// surface. The parser is ~120 lines and correct; that is the whole argument.
//
// THE INHERITED CEILING (unchanged, deliberately not exceeded): `\sqrt` is a
// SYMBOL in the macro table, not a radical over its argument, and there are no
// matrices, no \left/\right sizing, no \text{}. Every macro outside the table
// renders as its raw TeX source — never a fabricated symbol. Going past the
// twins here would make mobile the only surface whose math disagrees.
//
// Metro TDZ law (D49): this module imports renderBlockNative ONLY — never
// BLOCK_RENDERERS. (It imports neither: an equation has no child blocks.)
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { str } from '../model'
import type { BlockCtx, Render } from '../register'

/* ── the macro table — byte-identical to react math.ts MACROS (43 entries) ──── */

export const MACROS: Record<string, string> = {
  '\\alpha': 'α',
  '\\beta': 'β',
  '\\gamma': 'γ',
  '\\delta': 'δ',
  '\\epsilon': 'ε',
  '\\theta': 'θ',
  '\\lambda': 'λ',
  '\\mu': 'μ',
  '\\pi': 'π',
  '\\sigma': 'σ',
  '\\phi': 'φ',
  '\\omega': 'ω',
  '\\Delta': 'Δ',
  '\\Gamma': 'Γ',
  '\\Sigma': 'Σ',
  '\\Omega': 'Ω',
  '\\infty': '∞',
  '\\sum': '∑',
  '\\int': '∫',
  '\\prod': '∏',
  '\\partial': '∂',
  '\\nabla': '∇',
  '\\cdot': '·',
  '\\times': '×',
  '\\div': '÷',
  '\\pm': '±',
  '\\mp': '∓',
  '\\leq': '≤',
  '\\geq': '≥',
  '\\neq': '≠',
  '\\approx': '≈',
  '\\equiv': '≡',
  '\\to': '→',
  '\\rightarrow': '→',
  '\\leftarrow': '←',
  '\\in': '∈',
  '\\notin': '∉',
  '\\subset': '⊂',
  '\\cup': '∪',
  '\\cap': '∩',
  '\\forall': '∀',
  '\\exists': '∃',
  '\\sqrt': '√',
}

const OPERATORS = new Set(['+', '-', '=', '*', '/', '(', ')', '<', '>', ','])

/* ── tokenizer (math.ts tokenize/1, verbatim) ───────────────────────────────── */

type Token =
  | { kind: 'macro'; name: string }
  | { kind: 'lbrace' }
  | { kind: 'rbrace' }
  | { kind: 'caret' }
  | { kind: 'underscore' }
  | { kind: 'char'; value: string }

function tokenize(tex: string): Token[] {
  const tokens: Token[] = []
  let i = 0
  while (i < tex.length) {
    const c = tex[i]
    if (c === undefined) break
    if (/\s/.test(c)) {
      i++
      continue
    }
    if (c === '\\') {
      const m = /^\\[a-zA-Z]+/.exec(tex.slice(i))
      if (m) {
        tokens.push({ kind: 'macro', name: m[0] })
        i += m[0].length
        continue
      }
    }
    if (c === '{') {
      tokens.push({ kind: 'lbrace' })
      i++
      continue
    }
    if (c === '}') {
      tokens.push({ kind: 'rbrace' })
      i++
      continue
    }
    if (c === '^') {
      tokens.push({ kind: 'caret' })
      i++
      continue
    }
    if (c === '_') {
      tokens.push({ kind: 'underscore' })
      i++
      continue
    }
    tokens.push({ kind: 'char', value: c })
    i++
  }
  return tokens
}

/* ── the atom tree — the MathML row this leg builds instead of a string ─────── */

/** One parsed math atom. The `kind` names ARE the MathML element the web twin
 * emits at the same point in the grammar, so the two parsers stay diffable:
 * `sym` is <mi>/<mn>/<mo>, `raw` is the honest <mtext> fallback, `row` is
 * <mrow>, `frac` is <mfrac>, `script` is <msup>/<msub>/<msubsup>, and `none` is
 * the empty production the twin represents as `''`. */
export type MathAtom =
  | { kind: 'sym'; text: string; mathml: 'mi' | 'mn' | 'mo' }
  | { kind: 'raw'; text: string }
  | { kind: 'row'; items: MathAtom[] }
  | { kind: 'frac'; numer: MathAtom; denom: MathAtom }
  | { kind: 'script'; base: MathAtom; sup?: MathAtom; sub?: MathAtom }
  | { kind: 'none' }

/** The empty production. It is its OWN kind rather than an empty `row` because
 * the twin's script attachment turns on string truthiness, and there the two
 * cases differ: `x^` produces `''` (falsy → NO msup at all) while `x^{}`
 * produces `<mrow></mrow>` (truthy → an msup with an empty script). An empty
 * row would collapse that distinction and this leg would grow a script the web
 * does not draw. */
const NONE: MathAtom = { kind: 'none' }

/** The truthiness test math.ts gets for free from strings: only the empty
 * production is absent. An empty `{}` GROUP is present. */
function present(a: MathAtom): boolean {
  return a.kind !== 'none'
}

interface Cursor {
  tokens: Token[]
  pos: number
}

function peek(c: Cursor): Token | undefined {
  return c.tokens[c.pos]
}

// Parses one base atom (a group, a macro, or a single char run of the same
// class). Digit runs collapse into one <mn>.
function parseAtom(c: Cursor): MathAtom {
  const t = peek(c)
  if (!t) return NONE

  if (t.kind === 'lbrace') {
    c.pos++
    const inner = parseRow(c)
    if (peek(c)?.kind === 'rbrace') c.pos++
    return inner
  }

  if (t.kind === 'macro') {
    c.pos++
    if (t.name === '\\frac') {
      const numer = parseGroup(c)
      const denom = parseGroup(c)
      return { kind: 'frac', numer, denom }
    }
    const sym = MACROS[t.name]
    if (sym !== undefined) return { kind: 'sym', text: sym, mathml: 'mi' }
    // Honest fallback: an unrecognized macro renders as its raw TeX source,
    // never a fabricated symbol.
    return { kind: 'raw', text: t.name }
  }

  if (t.kind === 'char') {
    if (/[0-9]/.test(t.value)) {
      let digits = ''
      while (peek(c)?.kind === 'char' && /[0-9.]/.test((peek(c) as { value: string }).value)) {
        digits += (c.tokens[c.pos] as { value: string }).value
        c.pos++
      }
      return { kind: 'sym', text: digits, mathml: 'mn' }
    }
    c.pos++
    return { kind: 'sym', text: t.value, mathml: OPERATORS.has(t.value) ? 'mo' : 'mi' }
  }

  // A stray caret/underscore/rbrace with nothing to bind to — consume it so
  // the parser always makes progress.
  c.pos++
  return NONE
}

// parseGroup reads one `{...}` group (or, missing braces, a single atom —
// TeX's own tolerance for `x^2` without braces around the `2`).
function parseGroup(c: Cursor): MathAtom {
  if (peek(c)?.kind === 'lbrace') return parseAtom(c)
  return parseAtom(c)
}

// parseRow reads atoms until a closing brace or end of input, attaching any
// immediately-following ^/_ as a script wrapper around the base.
function parseRow(c: Cursor): MathAtom {
  const items: MathAtom[] = []
  while (c.pos < c.tokens.length && peek(c)?.kind !== 'rbrace') {
    let base = parseAtom(c)
    let sup: MathAtom | undefined
    let sub: MathAtom | undefined
    while (peek(c)?.kind === 'caret' || peek(c)?.kind === 'underscore') {
      const t = c.tokens[c.pos] as Token
      c.pos++
      const script = parseGroup(c)
      // An ABSENT script (`x^` at end of input) attaches nothing, exactly as the
      // twin's falsy `''` does — see NONE.
      if (!present(script)) continue
      if (t.kind === 'caret') sup = script
      else sub = script
    }
    if (sup !== undefined || sub !== undefined) base = { kind: 'script', base, sup, sub }
    items.push(base)
  }
  return { kind: 'row', items }
}

/** Parse one TeX math source string to its atom row (the texToMathMlRow twin).
 * Exported so the transliteration is pinnable without walking an element
 * tree — a grammar regression shows up in the TREE, not only in the pixels. */
export function texToMathAtoms(tex: string): MathAtom {
  return parseRow({ tokens: tokenize(tex), pos: 0 })
}

/* ── rendering ──────────────────────────────────────────────────────────────── */

// The three type steps an equation renders at. `display` and `inline` are the
// two the block's own `display` flag chooses between; `script` is the ONE
// reduced step every super/subscript renders at — a two-level ceiling, so a
// script inside a script does not keep shrinking toward illegibility.
const STEPS = { display: scale.lg, inline: scale.md, script: scale.xs } as const
type MathStep = keyof typeof STEPS

/** The vertical shift that raises a superscript / drops a subscript. Expressed
 * as MARGIN inside an alignItems:'center' row rather than as a lineHeight
 * offset: React Native has no vertical-align, and a nested-Text lead tweak
 * behaves differently on the two platforms, while a margin in a centered row
 * is the same geometry everywhere. */
const SCRIPT_SHIFT = 6

function renderAtom(a: MathAtom, ctx: BlockCtx, step: MathStep, key: number | string): ReactNode {
  switch (a.kind) {
    case 'sym':
      return (
        <Text
          key={key}
          style={{
            ...STEPS[step],
            color: ctx.theme.text,
            // <mi> is italic by MathML convention — a variable must not read as
            // an operator. Numbers and operators stay upright.
            fontStyle: a.mathml === 'mi' ? 'italic' : 'normal',
          }}
        >
          {a.text}
        </Text>
      )
    case 'raw':
      // The unrecognized macro. Muted and upright, so the reader can SEE that
      // this run is un-typeset source rather than a symbol we invented.
      return (
        <Text key={key} style={{ ...STEPS[step], color: ctx.theme.textMuted }}>
          {a.text}
        </Text>
      )
    case 'none':
      return null
    case 'row':
      return (
        <View key={key} style={{ flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center' }}>
          {a.items.map((it, i) => renderAtom(it, ctx, step, i))}
        </View>
      )
    case 'frac':
      // <mfrac>: numerator over denominator with a 1px rule between. The rule
      // stretches to the wider of the two rows (alignSelf stretch inside a
      // center-aligned column), which is what makes a nested frac read.
      return (
        <View key={key} style={{ alignItems: 'center', marginHorizontal: 3 }}>
          {renderAtom(a.numer, ctx, step, 'n')}
          <View
            style={{
              height: 1,
              alignSelf: 'stretch',
              backgroundColor: ctx.theme.text,
              marginVertical: 2,
            }}
          />
          {renderAtom(a.denom, ctx, step, 'd')}
        </View>
      )
    case 'script':
      // <msup>/<msub>/<msubsup>: the scripts nest at the reduced step in their
      // own column beside the base — sup above, sub below, both when both.
      return (
        <View key={key} style={{ flexDirection: 'row', alignItems: 'center' }}>
          {renderAtom(a.base, ctx, step, 'b')}
          <View style={{ marginLeft: 1 }}>
            {a.sup !== undefined ? (
              <View style={{ marginBottom: SCRIPT_SHIFT }}>{renderAtom(a.sup, ctx, 'script', 'up')}</View>
            ) : null}
            {a.sub !== undefined ? (
              <View style={{ marginTop: SCRIPT_SHIFT }}>{renderAtom(a.sub, ctx, 'script', 'dn')}</View>
            ) : null}
          </View>
        </View>
      )
  }
}

const equation: Render = (b, ctx, key) => {
  const tex = str(b.tex).trim()
  if (tex === '') {
    // The web twin's bp-equation--empty arm, in words: an equation block with
    // no source says so rather than drawing an empty box.
    return (
      <Text key={key} style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted }}>
        equation — no tex source
      </Text>
    )
  }
  // `display === true` exactly (math.ts): a truthy string does not promote an
  // inline equation to a centered display one.
  const display = b.display === true
  return (
    <View
      key={key}
      style={{
        marginVertical: display ? 14 : 6,
        alignItems: display ? 'center' : 'flex-start',
      }}
    >
      {renderAtom(texToMathAtoms(tex), ctx, display ? 'display' : 'inline', 0)}
    </View>
  )
}

export const mathRenderers: Record<string, Render> = { equation }
