// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// equation (B025) — server-side TeX -> MathML, zero client JS. Native <math>
// renders in every modern browser. A bounded, deterministic tokenizer/parser
// (NOT a full TeX engine): \frac{a}{b}, ^/_ super/subscripts, and a fixed
// greek-letter/operator macro table. Anything outside that table degrades
// honestly to an <mtext> of the raw macro — never a fabricated render. This
// is the JS twin of pdrender's texToUnicode (equation.go) and
// data_viz.ex's tex_to_mathml/1, same macro table and grammar.

import { type Block, escapeHtml, str, isMap } from '../inline'

type Emit = (block: Block) => string

const MACROS: Record<string, string> = {
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

interface Cursor {
  tokens: Token[]
  pos: number
}

function peek(c: Cursor): Token | undefined {
  return c.tokens[c.pos]
}

// Parses one base atom (a group, a macro, or a single char run of the same
// class) into its MathML string. Digit runs collapse into one <mn>.
function parseAtom(c: Cursor): string {
  const t = peek(c)
  if (!t) return ''

  if (t.kind === 'lbrace') {
    c.pos++
    const inner = parseRow(c)
    if (peek(c)?.kind === 'rbrace') c.pos++
    return `<mrow>${inner}</mrow>`
  }

  if (t.kind === 'macro') {
    c.pos++
    if (t.name === '\\frac') {
      const num = parseGroup(c)
      const den = parseGroup(c)
      return `<mfrac><mrow>${num}</mrow><mrow>${den}</mrow></mfrac>`
    }
    const sym = MACROS[t.name]
    if (sym !== undefined) return `<mi>${escapeHtml(sym)}</mi>`
    // Honest fallback: an unrecognized macro renders as its raw TeX source,
    // never a fabricated symbol.
    return `<mtext>${escapeHtml(t.name)}</mtext>`
  }

  if (t.kind === 'char') {
    if (/[0-9]/.test(t.value)) {
      let digits = ''
      while (peek(c)?.kind === 'char' && /[0-9.]/.test((peek(c) as { value: string }).value)) {
        digits += (c.tokens[c.pos] as { value: string }).value
        c.pos++
      }
      return `<mn>${escapeHtml(digits)}</mn>`
    }
    c.pos++
    if (OPERATORS.has(t.value)) return `<mo>${escapeHtml(t.value)}</mo>`
    return `<mi>${escapeHtml(t.value)}</mi>`
  }

  // A stray caret/underscore/rbrace with nothing to bind to — consume it so
  // the parser always makes progress.
  c.pos++
  return ''
}

// parseGroup reads one `{...}` group (or, missing braces, a single atom —
// TeX's own tolerance for `x^2` without braces around the `2`).
function parseGroup(c: Cursor): string {
  if (peek(c)?.kind === 'lbrace') return parseAtom(c)
  return parseAtom(c)
}

// parseRow reads atoms until a closing brace or end of input, attaching any
// immediately-following ^/_ as an msup/msub/msubsup wrapper around the base.
function parseRow(c: Cursor): string {
  let out = ''
  while (c.pos < c.tokens.length && peek(c)?.kind !== 'rbrace') {
    let base = parseAtom(c)
    let sup = ''
    let sub = ''
    while (peek(c)?.kind === 'caret' || peek(c)?.kind === 'underscore') {
      const t = c.tokens[c.pos] as Token
      c.pos++
      if (t.kind === 'caret') sup = parseGroup(c)
      else sub = parseGroup(c)
    }
    if (sup && sub) base = `<msubsup><mrow>${base}</mrow><mrow>${sub}</mrow><mrow>${sup}</mrow></msubsup>`
    else if (sup) base = `<msup><mrow>${base}</mrow><mrow>${sup}</mrow></msup>`
    else if (sub) base = `<msub><mrow>${base}</mrow><mrow>${sub}</mrow></msub>`
    out += base
  }
  return out
}

/** Convert one TeX math source string to a MathML row (no outer <math>). */
export function texToMathMlRow(tex: string): string {
  return parseRow({ tokens: tokenize(tex), pos: 0 })
}

const equation: Emit = (block) => {
  const tex = isMap(block) ? str(block.tex).trim() : ''
  if (tex === '') return `<div class="bp-equation bp-equation--empty">equation — no tex source</div>`
  const display = isMap(block) && block.display === true
  const row = texToMathMlRow(tex)
  const displayAttr = display ? ' display="block"' : ''
  return `<div class="bp-equation"><math${displayAttr}>${row}</math></div>`
}

export const mathEmitters: Record<string, Emit> = {
  equation,
}
