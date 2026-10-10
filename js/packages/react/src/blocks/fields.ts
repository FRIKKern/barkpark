// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Schema field blocks (field-string … field-number, composite, arrayOf,
// codelist, localizedText) — the JS twin of compose.ex's `:article` field
// clauses (task-7375ba22758155fa; field-number since B085). Each renders the
// read-only definition row the Phoenix reader paints: `bp-field` with a
// `bp-field__l` label beside a `bp-field__v` value. Every author string is
// escaped at the leaf; a colour reaches the inline style only as a strict hex
// literal (safe_hex), and an image src goes through safeUrl. `embed` and
// `master-ref` need resolver context and are not here. Kept compact: this file
// rides the size-limit budget.

import { type Block, escapeAttr as ea, escapeHtml as eh, isMap, safeUrl } from '../inline'
import type { RenderCtx } from './chrome'

type Emit = (block: Block, ctx: RenderCtx) => string

// Compose.stringish/1: a string, a finite number or a boolean as text; else "".
const s = (v: unknown): string =>
  typeof v === 'string'
    ? v
    : (typeof v === 'number' && Number.isFinite(v)) || typeof v === 'boolean'
      ? String(v)
      : ''

// field_row_article/2 — `html` is pre-escaped by every caller.
const row = (b: Block, html: string) =>
  `<div class="bp-field"><span class="bp-field__l">${eh(s(b.label))}</span><div class="bp-field__v">${html}</div></div>`

// field_row(b, text, :article) — a blank value reads as an em-dash.
const text = (b: Block, t: string) => row(b, `<span>${eh(t.trim() ? t : '—')}</span>`)

const NONE = '<span class="bp-field__none">—</span>'
const val = (b: Block) => s(b.value)

// A resolver-stashed display (`_ref_title`, `_code_label`), else the stored
// datum, else an em-dash.
const shown = (b: Block, key: string) => (val(b) === '' ? '—' : s(b[key]) || val(b))

// composite_scalar/1: a sub-value as one display string. Maps join in key
// order, as an Elixir map iterates.
const scalar = (v: unknown, ctx: RenderCtx): string =>
  v == null
    ? '—'
    : typeof v === 'boolean'
      ? ctx.t(v ? 'Yes' : 'No')
      : Array.isArray(v)
        ? v.map((x) => scalar(x, ctx)).join(', ')
        : isMap(v)
          ? Object.keys(v)
              .sort()
              .map((k) => `${k}: ${scalar(v[k], ctx)}`)
              .join(', ')
          : s(v)

// One `bp-field__sub` row per [label, value]; `value` reads from the block's map.
const subs = (b: Block, pairs: unknown[][], ctx: RenderCtx) =>
  row(
    b,
    pairs
      .map(
        ([label, key]) =>
          `<div class="bp-field__sub"><b>${eh(s(label))}</b><span>${eh(scalar(isMap(b.value) ? b.value[s(key)] : undefined, ctx))}</span></div>`,
      )
      .join(''),
  )

// media_field_url/1: a bare URL (v1) or JSON `{"url","assetId"}` (v2).
function media(v: unknown): string {
  const t = typeof v === 'string' ? v.trim() : s(v)
  if (t.startsWith('{')) {
    try {
      const u = (JSON.parse(t) as { url?: unknown }).url
      if (typeof u === 'string' && u) return u
    } catch {
      /* not JSON: the string itself */
    }
  }
  return t
}

const plain: Emit = (b) => text(b, val(b))

export const fieldEmitters: Record<string, Emit> = {
  'field-string': plain,
  'field-slug': plain,
  'field-text': plain,
  'field-boolean': (b, ctx) => text(b, ctx.t(b.value === true ? 'Yes' : 'No')),
  'field-select': (b) => {
    const hit = (Array.isArray(b.options) ? b.options : []).find(
      (o) => isMap(o) && o.value === b.value,
    )
    // Map.get(opt, "label", Map.get(opt, "value", "")): a present key wins even when null.
    return text(b, isMap(hit) ? s('label' in hit ? hit.label : hit.value) : val(b))
  },
  'field-datetime': (b) =>
    text(b, typeof b.value === 'string' ? b.value.replace(/T/g, ' ') : val(b)),
  // field_number_text/1: numbers pass through; a string must be a FULL decimal;
  // anything else (and a non-finite value) is the "—" state with no unit.
  'field-number': (b) => {
    const v = b.value
    const t = typeof v === 'string' ? v.trim() : ''
    const n = typeof v === 'number' ? v : /^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(t) ? Number(t) : NaN
    const unit = s(b.unit).trim()
    return text(b, Number.isFinite(n) ? String(n) + (unit && ' ' + unit) : '—')
  },
  'field-color': (b) => {
    const hex = val(b)
    const safe = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(hex) ? hex : 'transparent'
    return row(
      b,
      hex
        ? `<i class="bp-field__swatch" style="background:${safe}"></i><span class="bp-field__mono">${eh(hex)}</span>`
        : NONE,
    )
  },
  'field-reference': (b) => row(b, `<span>${eh(shown(b, '_ref_title'))}</span>`),
  'field-image': (b, ctx) => {
    const src = media(b.value ?? '')
    return row(
      b,
      src
        ? `<img class="bp-field__img" src="${ea(safeUrl(src))}" alt="${ea(s(b.label))}">`
        : `<span class="bp-field__none">${eh(ctx.t('No image'))}</span>`,
    )
  },
  composite: (b, ctx) =>
    subs(
      b,
      (Array.isArray(b.fields) ? b.fields : []).map((f) => {
        const name = isMap(f) ? (f.name ?? '') : ''
        return [isMap(f) && f.title != null && f.title !== false ? f.title : name, name]
      }),
      ctx,
    ),
  arrayOf: (b, ctx) => {
    const els = b.value == null ? [] : Array.isArray(b.value) ? b.value : [b.value]
    return row(
      b,
      els.length
        ? `<ol class="bp-field__list">${els.map((e) => `<li>${eh(scalar(e, ctx))}</li>`).join('')}</ol>`
        : NONE,
    )
  },
  codelist: (b) => text(b, shown(b, '_code_label')),
  localizedText: (b, ctx) =>
    subs(
      b,
      (Array.isArray(b.languages) ? b.languages : []).map((l) => [l, l]),
      ctx,
    ),
}
