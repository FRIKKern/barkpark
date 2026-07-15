// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `form` / `questionnaire` block emitter — the JS twin of forms.ex at
// style=:article. Render-only: one `<fieldset>` per question, semantic controls
// per the grill.js input types, no `<script>`/action/method. `questionnaire` is
// a pure alias of `form`, differentiated only by the container class.

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
  const typeClass = ` bp-form-q--${escapeAttr(type)}`
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

export const formsEmitters: Record<string, Emit> = { form, questionnaire }
