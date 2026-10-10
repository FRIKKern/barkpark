// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `form` / `questionnaire` block emitters — the JS twin of forms.ex at
// style=:article. Render-only: one `<fieldset>` per question, semantic
// controls per the grill.js input types, no `<script>`/action/method.
// `questionnaire` is a pure alias of `form`, differentiated only by the
// container class. `field-number` moved to fields.ts with the other schema
// field rows (task-7375ba22758155fa).

import { type Block, escapeHtml, escapeAttr, str, asList, isMap } from '../inline'
import type { RenderCtx } from './chrome'

type Emit = (block: Block, ctx: RenderCtx) => string

function scaleBound(v: unknown, def: number): number {
  if (typeof v === 'number' && Number.isInteger(v)) return v
  if (typeof v === 'string') {
    const n = Number.parseInt(v, 10)
    return Number.isNaN(n) ? def : n
  }
  return def
}

// An option is its own value, or a [value, label] pair when the shown label is
// translated chrome and the submitted value must not move (task-8e96278fc4ee7097).
type Choice = string | [string, string]

function choiceGroup(id: string, labels: Choice[], inputType: string): string {
  return labels
    .map((c) => (Array.isArray(c) ? c : ([c, c] as [string, string])))
    .map(
      ([value, label]) =>
        `<label class="bp-form-opt"><input type="${inputType}" name="${escapeAttr(id)}" value="${escapeAttr(value)}"> <span>${escapeHtml(label)}</span></label>`,
    )
    .join('')
}

function radioGroup(id: string, labels: Choice[]): string {
  return choiceGroup(id, labels, 'radio')
}

function controlHtml(type: string, id: string, q: Record<string, unknown>, ctx: RenderCtx): string {
  switch (type) {
    case 'yesno':
      return radioGroup(id, [
        ['Yes', ctx.t('Yes')],
        ['No', ctx.t('No')],
      ])
    case 'single':
      return radioGroup(
        id,
        asList(q.options).map((o) => str(o)),
      )
    case 'multi':
      return choiceGroup(
        id,
        asList(q.options).map((o) => str(o)),
        'checkbox',
      )
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

function questionHtml(q: unknown, ctx: RenderCtx): string {
  if (!isMap(q)) return ''
  const id = str(q.id)
  const prompt = str(q.prompt)
  const type = str(q.type) || 'text'
  const legend = `<legend>${escapeHtml(prompt)}</legend>`
  const rationale = mutedLine(q.rationale, '')
  const recommendation = mutedLine(q.recommendation, ctx.t('Recommendation: '))
  const control = `<div class="bp-form-opts">${controlHtml(type, id, q, ctx)}</div>`
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

const form: Emit = (b, ctx) => {
  const kind = str(b.kind) || 'grill'
  const kindClass = kind === 'questionnaire' ? 'bp-form-questionnaire' : 'bp-form-grill'
  const questions = asList(b.questions)
    .map((q) => questionHtml(q, ctx))
    .join('')
  return `<section class="bp-form ${kindClass}">${questions}</section>`
}

// `questionnaire` aliases `form` with the kind defaulting to "questionnaire".
const questionnaire: Emit = (b, ctx) =>
  form({ ...b, type: 'form', kind: b.kind ?? 'questionnaire' } as Block, ctx)

export const formsEmitters: Record<string, Emit> = {
  form,
  questionnaire,
}
