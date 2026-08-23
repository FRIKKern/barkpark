// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `form` / `questionnaire` / `field-number` block emitters — the JS twin of
// forms.ex at style=:article. Render-only: one `<fieldset>` per question,
// semantic controls per the grill.js input types, no `<script>`/action/method.
// `questionnaire` is a pure alias of `form`, differentiated only by the
// container class. `field-number` (B085) is the labelled numeric definition
// row (compose.ex field_number_text twin) — see its section below.

import { type Block, escapeHtml, escapeAttr, str, asList, isMap } from '../inline'

type Emit = (block: Block) => string

function scaleBound(v: unknown, def: number): number {
  if (typeof v === 'number' && Number.isInteger(v)) return v
  if (typeof v === 'string') {
    const n = Number.parseInt(v, 10)
    return Number.isNaN(n) ? def : n
  }
  return def
}

function choiceGroup(id: string, labels: string[], inputType: string): string {
  return labels
    .map(
      (label) =>
        `<label class="bp-form-opt"><input type="${inputType}" name="${escapeAttr(id)}" value="${escapeAttr(label)}"> <span>${escapeHtml(label)}</span></label>`,
    )
    .join('')
}

function radioGroup(id: string, labels: string[]): string {
  return choiceGroup(id, labels, 'radio')
}

function controlHtml(type: string, id: string, q: Record<string, unknown>): string {
  switch (type) {
    case 'yesno':
      return radioGroup(id, ['Yes', 'No'])
    case 'single':
      return radioGroup(id, asList(q.options).map((o) => str(o)))
    case 'multi':
      return choiceGroup(id, asList(q.options).map((o) => str(o)), 'checkbox')
    case 'scale': {
      const scale = isMap(q.scale) ? q.scale : {}
      const min = scaleBound(scale.min, 1)
      let max = scaleBound(scale.max, 5)
      // Cap the ladder span at 101 rungs (render-time DoS guard, forms.ex).
      max = Math.min(max, min + 100)
      const labels: string[] = []
      if (max >= min) for (let i = min; i <= max; i++) labels.push(String(i))
      return radioGroup(id, labels)
    }
    default:
      // text + unknown → a textarea (never crash).
      return `<textarea name="${escapeAttr(id)}" rows="3"></textarea>`
  }
}

function mutedLine(text: unknown, prefix: string): string {
  if (typeof text !== 'string' || text === '') return ''
  return `<p class="bp-form-note">${escapeHtml(prefix)}${escapeHtml(text)}</p>`
}

function questionHtml(q: unknown): string {
  if (!isMap(q)) return ''
  const id = str(q.id)
  const prompt = str(q.prompt)
  const type = str(q.type) || 'text'
  const legend = `<legend>${escapeHtml(prompt)}</legend>`
  const rationale = mutedLine(q.rationale, '')
  const recommendation = mutedLine(q.recommendation, 'Recommendation: ')
  const control = `<div class="bp-form-opts">${controlHtml(type, id, q)}</div>`
  // FAIL-CLOSED type-class slug (defense-in-depth, charter D23/D26 pattern —
  // mirrors core.ts apiEndpoint's methodSlug): escapeAttr already made attribute
  // breakout impossible, but an unslugified `type` with a space would inject an
  // extra class token (CSS-selector/style pollution). Only lowercase [a-z0-9-]
  // survives; an empty slug drops the modifier class entirely. The legit type
  // vocabulary (yesno/single/multi/scale/text) is pure [a-z], so goldens are
  // byte-identical. NOTE: the Elixir twin (render/forms.ex) still escape-onlys
  // its type class — this surface deliberately fails closed harder.
  const typeSlug = type.toLowerCase().replace(/[^a-z0-9-]/g, '')
  const typeClass = typeSlug === '' ? '' : ` bp-form-q--${typeSlug}`
  return `<fieldset class="bp-form-question${typeClass}">${legend}${rationale}${recommendation}${control}</fieldset>`
}

const form: Emit = (b) => {
  const kind = str(b.kind) || 'grill'
  const kindClass = kind === 'questionnaire' ? 'bp-form-questionnaire' : 'bp-form-grill'
  const questions = asList(b.questions).map(questionHtml).join('')
  return `<section class="bp-form ${kindClass}">${questions}</section>`
}

// `questionnaire` aliases `form` with the kind defaulting to "questionnaire".
const questionnaire: Emit = (b) =>
  form({ ...b, type: 'form', kind: b.kind ?? 'questionnaire' } as Block)

// ── field-number (B085) — the JS twin of compose.ex field_number_text/1 and
// pdrender fieldNumberRenderer (internal/pdrender/fields.go). A labelled
// definition row in the article bp-field grid: dim mono label beside the
// formatted `value` plus an optional trailing `unit`. An absent or
// uncoercible value renders the honest "—" empty state (the field-reference
// precedent) with NO unit suffix. `min`/`max`/`step` are Edit-mode control
// bounds — never read here.

// The article definition row compose.ex field_row_article/2 emits — byte-shape
// parity with the Elixir renderer's bp-field grid (gui-premium w2). Value
// coercion mirrors field_number_value/1: numbers pass through; a string must
// parse as a FULL decimal (Float.parse with an empty rest) — partial parses
// and garbage fall to NaN, and every non-finite value (including a regex-passing
// overflow like "1e999") renders the "—" empty state with no unit suffix.
// Integer values and whole floats drop the decimal point; fractions keep the
// shortest round-trip decimal — String(n) is JS's Float.to_string twin.
// (Kept deliberately compact: this emitter rides the size-limit budget.)
const fieldNumber: Emit = (b) => {
  const v = b.value
  const t = typeof v === 'string' ? v.trim() : ''
  const n = typeof v === 'number' ? v : /^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(t) ? Number(t) : NaN
  const unit = str(b.unit).trim()
  const text = Number.isFinite(n) ? String(n) + (unit && ' ' + unit) : '—'
  return `<div class="bp-field"><span class="bp-field__l">${escapeHtml(str(b.label))}</span><div class="bp-field__v"><span>${escapeHtml(text)}</span></div></div>`
}

export const formsEmitters: Record<string, Emit> = {
  form,
  questionnaire,
  'field-number': fieldNumber,
}
