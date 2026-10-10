// forms family (charter D49) — `form` + `questionnaire` (D46a).
//
// RENDER-ONLY ON EVERY SURFACE, by contract: the web emitter emits <fieldset>s
// with no <script>, action or submit (react forms.ts:4-7) and the TUI renders a
// static control representation (form.go:10-18). The reader sees the form's
// SHAPE; answering is not a read-path capability on any surface, so the mobile
// leg ships zero inputs — a TextInput here would be the first surface to
// promise a submit that does not exist.
//
// One bordered card per question: a bold prompt, then BOTH context lines when
// present — the bare `rationale` and the "Recommendation: "-prefixed
// `recommendation` (react forms.ts:70-71 / form.go:52-59; a surface that folds
// them into one loses the distinction between why-we-ask and what-we-advise) —
// then the static control keyed by `type`.
//
// THREE RECORDED DIVERGENCES from the web twin, all toward the honest-ceiling
// doctrine and all taken from the TUI:
//
//   1. A `scale` whose span exceeds 100 rungs SUMMARIZES as "min … max"
//      (scaleLadder's guard) rather than the web's clamp-and-enumerate to 101
//      rungs. 101 stacked radio rows on a phone is a hostile render, and the
//      summary is what the terminal already shows.
//   2. An option-LESS `single`/`multi` falls back to a real control (Yes/No
//      radios, one "Option" checkbox — formControl's arms) rather than the
//      web's empty <div>. A control that renders nothing is a silent hole; the
//      question's shape must survive missing options.
//   3. A `scale` with max < min draws the "[ … ]" catch-all (form.go:137-139)
//      rather than the web/Elixir empty control (forms.ts:50 / forms.ex:96) —
//      same reason as 2: an inverted range is malformed input, not a reason to
//      render a hole where a question was.
//
// Metro TDZ law (D49): this module imports renderBlockNative ONLY — never
// BLOCK_RENDERERS.
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { chromeWord } from '../chrome'
import { asList, isMap, str, type Block } from '../model'
import type { BlockCtx, Render } from '../register'

/** react forms.ts scaleBound: an integer number, or a base-10 parse of a
 * string, else the default. A float or junk keeps the default. */
function scaleBound(v: unknown, def: number): number {
  if (typeof v === 'number' && Number.isInteger(v)) return v
  if (typeof v === 'string') {
    const n = Number.parseInt(v, 10)
    return Number.isNaN(n) ? def : n
  }
  return def
}

/** The ladder span guard (scaleLadder's `maxLadder`): past 100 rungs the ladder
 * is summarized rather than drawn. Attacker-controlled `scale.max` can
 * otherwise drive an unbounded row allocation at render time. */
const MAX_LADDER = 100

/** The static control text for one question, keyed by `type` — the mobile
 * stand-in for the live <input>/<textarea> markup:
 *
 *   yesno / single → "( ) Label"  unchecked radio rows
 *   multi          → "[ ] Label"  unchecked checkbox rows
 *   scale          → "1 2 3 4 5"  the min..max ladder, or a "min … max" summary
 *   text / unknown → "[ … ]"      the textarea placeholder
 *
 * Unknown types degrade to the placeholder — render-only, never a crash, the
 * catch-all both twins carry. Returns the lines to STACK: choice controls get
 * one row per option (the terminal joins them on one line; a phone has no
 * horizontal room), everything else is a single line. */
function controlLines(q: Record<string, unknown>): string[] {
  const options = (): string[] => asList(q.options).map((o) => str(o))
  switch (str(q.type)) {
    case 'yesno':
      return ['( ) Yes', '( ) No']
    case 'single': {
      const opts = options()
      return (opts.length === 0 ? ['Yes', 'No'] : opts).map((o) => `( ) ${o}`)
    }
    case 'multi': {
      const opts = options()
      return (opts.length === 0 ? ['Option'] : opts).map((o) => `[ ] ${o}`)
    }
    case 'scale': {
      const spec = isMap(q.scale) ? q.scale : {}
      const min = scaleBound(spec.min, 1)
      const max = scaleBound(spec.max, 5)
      if (max < min) return ['[ … ]']
      if (max - min > MAX_LADDER) return [`${min} … ${max}`]
      const rungs: string[] = []
      for (let n = min; n <= max; n++) rungs.push(String(n))
      return [rungs.join(' ')]
    }
    default:
      return ['[ … ]']
  }
}

function contextLine(text: unknown, prefix: string, ctx: BlockCtx, key: string): ReactNode {
  if (typeof text !== 'string' || text === '') return null
  return (
    <Text key={key} style={{ ...scale.sm, color: ctx.theme.textMuted }}>
      {prefix + text}
    </Text>
  )
}

function questionCard(q: unknown, ctx: BlockCtx, key: number): ReactNode {
  if (!isMap(q)) return null
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        backgroundColor: ctx.theme.surface,
        gap: 4,
      }}
    >
      <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text }}>{str(q.prompt)}</Text>
      {contextLine(q.rationale, '', ctx, 'why')}
      {contextLine(q.recommendation, 'Recommendation: ', ctx, 'rec')}
      <View style={{ marginTop: 4, gap: 2 }}>
        {controlLines(q).map((line, i) => (
          <Text key={i} style={{ ...scale.base, color: ctx.theme.textMuted }}>
            {line}
          </Text>
        ))}
      </View>
    </View>
  )
}

const form: Render = (b, ctx, key) => {
  const cards = asList(b.questions)
    .map((q, i) => questionCard(q, ctx, i))
    .filter((c) => c !== null)
  if (cards.length === 0) {
    // An empty form renders HONESTLY rather than vanishing (formRenderer's
    // "(empty form)" box). A form block that draws nothing reads as a render
    // bug; a labeled empty box reads as an empty form.
    return (
      <View
        key={key}
        style={{
          borderWidth: 1,
          borderColor: ctx.theme.border,
          borderRadius: 8,
          padding: 12,
          marginVertical: 8,
        }}
      >
        <Text style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted }}>(empty form)</Text>
      </View>
    )
  }
  return (
    <View key={key} style={{ marginVertical: 8, gap: 8 }}>
      {cards}
    </View>
  )
}

// `questionnaire` is a PURE ALIAS of `form` on this surface — but note WHICH
// twin that follows. The TUI registers both types to the SAME formRenderer and
// draws no kind badge, so mobile matches the TUI exactly. The web differs by
// more than a class name: forms.ts:79 picks `bp-form-questionnaire`, and
// paper-surface.css `.bp-form-questionnaire::before { content: "Questionnaire" }`
// renders that class as a VISIBLE badge. So the web shows a kind label mobile
// deliberately drops (and mobile likewise ignores `kind` on a plain `form`
// block, which the web would badge). Following the TUI here is the deliberate
// call: a badge repeating the block type is apparatus, not content, and the
// terminal already judged it not worth a row.
//
// It stays a distinct function rather than a second key
// onto `form` because the registry's alias tripwire enumerates function
// IDENTITIES: this is an alias of behavior, not of implementation, exactly the
// shape the web twin chose (a delegating Emit).
const questionnaire: Render = (b, ctx, key) => form(b, ctx, key)

/* ── field-number (B085) — the mobile leg of the cross-surface fields row ─────
 *
 * Twin of compose.ex field_number_text/1, react forms.ts fieldNumber and
 * pdrender fieldNumberRenderer (pbw-fix-field-number-react): a labelled
 * definition row — dim label, then the formatted `value` plus an optional
 * trailing `unit`. An absent or uncoercible value renders the honest "—"
 * empty state (the field-reference precedent) with NO unit suffix.
 * `min`/`max`/`step` are Edit-mode control bounds — never read here. */

/** compose.ex field_number_value/1: numbers pass through; a string must parse
 * as a FULL decimal (Float.parse with empty rest) — partial parses and junk
 * coerce to null, never to NaN output. */
function fieldNumberValue(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v
  if (typeof v === 'string') {
    const t = v.trim()
    if (/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(t)) {
      const n = Number(t)
      if (Number.isFinite(n)) return n
    }
  }
  return null
}

/** Integer values and whole floats drop the decimal point; fractions keep the
 * shortest round-trip decimal — String(n) is JS's Float.to_string twin. */
function fieldNumberText(b: Record<string, unknown>): string {
  const n = fieldNumberValue(b.value)
  if (n === null) return '—'
  const unit = str(b.unit).trim()
  return unit === '' ? String(n) : `${String(n)} ${unit}`
}

const fieldNumber: Render = (b, ctx, key) => (
  <View key={key} style={{ flexDirection: 'row', alignItems: 'baseline', gap: 8, marginVertical: 4 }}>
    <Text style={{ ...scale.sm, color: ctx.theme.textMuted }}>{str(b.label)}</Text>
    <Text style={{ ...scale.sm, color: ctx.theme.text }}>{fieldNumberText(b)}</Text>
  </View>
)

/* ── schema field blocks (task-7375ba22758155fa) — the mobile leg of
 * compose.ex's field rows and react fields.ts ──────────────────────────────
 *
 * The same labelled definition row as field-number: dim label, then the
 * value as plain chrome text (no prose measure, so register-blind like
 * field-number). Empty values read "—". field-reference / codelist show a
 * server-stashed `_ref_title` / `_code_label` when present. field-color draws
 * its swatch only for a strict hex literal; field-image names its URL rather
 * than fetching a preview inside a definition row. */

/** composite_scalar/1: a sub-value as one display string (maps in key order). */
function fieldScalar(v: unknown, ctx: BlockCtx): string {
  if (v === null || v === undefined) return '—'
  if (typeof v === 'boolean') return chromeWord(ctx.locale, v ? 'Yes' : 'No')
  if (Array.isArray(v)) return v.map((x) => fieldScalar(x, ctx)).join(', ')
  if (isMap(v)) {
    return Object.keys(v)
      .sort()
      .map((k) => `${k}: ${fieldScalar(v[k], ctx)}`)
      .join(', ')
  }
  return typeof v === 'number' ? String(v) : str(v)
}

const fieldRow = (b: Block, ctx: BlockCtx, key: number, value: ReactNode): ReactNode => (
  <View key={key} style={{ flexDirection: 'row', alignItems: 'baseline', gap: 8, marginVertical: 4 }}>
    <Text style={{ ...scale.sm, color: ctx.theme.textMuted }}>{str(b.label)}</Text>
    {value}
  </View>
)

const fieldText = (b: Block, ctx: BlockCtx, key: number, text: string): ReactNode =>
  fieldRow(b, ctx, key, <Text style={{ ...scale.sm, color: ctx.theme.text }}>{text.trim() ? text : '—'}</Text>)

/** Sub-rows (composite subfields, localizedText languages): `label: value`. */
const fieldSubs = (b: Block, ctx: BlockCtx, key: number, pairs: Array<[unknown, unknown]>): ReactNode => (
  <View key={key} style={{ marginVertical: 4, gap: 2 }}>
    <Text style={{ ...scale.sm, color: ctx.theme.textMuted }}>{str(b.label)}</Text>
    {pairs.map(([label, k], i) => (
      <Text key={i} style={{ ...scale.sm, color: ctx.theme.text }}>
        {`${str(label)}: ${fieldScalar(isMap(b.value) ? b.value[str(k)] : undefined, ctx)}`}
      </Text>
    ))}
  </View>
)

const plainField: Render = (b, ctx, key) => fieldText(b, ctx, key, str(b.value))

/** A resolver-stashed display, else the stored datum, else "—". */
const shownField = (b: Block, stash: string): string => (str(b.value) === '' ? '—' : str(b[stash]) || str(b.value))

const fieldRenderers: Record<string, Render> = {
  // Three distinct functions, not one shared reference: the registry's alias
  // tripwire (charter D31) reads a shared function as a type alias.
  'field-string': (b, ctx, key) => plainField(b, ctx, key),
  'field-slug': (b, ctx, key) => plainField(b, ctx, key),
  'field-text': (b, ctx, key) => plainField(b, ctx, key),
  'field-boolean': (b, ctx, key) => fieldText(b, ctx, key, chromeWord(ctx.locale, b.value === true ? 'Yes' : 'No')),
  'field-select': (b, ctx, key) => {
    const hit = asList(b.options).find((o) => isMap(o) && o.value === b.value)
    return fieldText(b, ctx, key, isMap(hit) ? str('label' in hit ? hit.label : hit.value) : str(b.value))
  },
  'field-datetime': (b, ctx, key) => fieldText(b, ctx, key, str(b.value).replace(/T/g, ' ')),
  'field-color': (b, ctx, key) => {
    const hex = str(b.value)
    if (hex === '') return fieldText(b, ctx, key, '')
    const safe = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(hex) ? hex : 'transparent'
    return fieldRow(
      b,
      ctx,
      key,
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
        <View style={{ width: 12, height: 12, borderRadius: 6, backgroundColor: safe }} />
        <Text style={{ ...scale.sm, color: ctx.theme.text, fontFamily: 'monospace' }}>{hex}</Text>
      </View>,
    )
  },
  'field-reference': (b, ctx, key) => fieldText(b, ctx, key, shownField(b, '_ref_title')),
  'field-image': (b, ctx, key) => {
    const v = str(b.value).trim()
    let src = v
    if (v.startsWith('{')) {
      try {
        const u = (JSON.parse(v) as { url?: unknown }).url
        if (typeof u === 'string' && u) src = u
      } catch {
        /* not JSON: the string itself */
      }
    }
    return fieldText(b, ctx, key, src || chromeWord(ctx.locale, 'No image'))
  },
  composite: (b, ctx, key) =>
    fieldSubs(
      b,
      ctx,
      key,
      asList(b.fields).map((f) => {
        const name = isMap(f) ? f.name : ''
        return [isMap(f) && f.title != null && f.title !== false ? f.title : name, name]
      }),
    ),
  arrayOf: (b, ctx, key) => {
    const els = b.value == null ? [] : Array.isArray(b.value) ? b.value : [b.value]
    return fieldText(b, ctx, key, els.map((e, i) => `${i + 1}. ${fieldScalar(e, ctx)}`).join('\n'))
  },
  codelist: (b, ctx, key) => fieldText(b, ctx, key, shownField(b, '_code_label')),
  localizedText: (b, ctx, key) =>
    fieldSubs(
      b,
      ctx,
      key,
      asList(b.languages).map((l) => [l, l]),
    ),
}

export const formsRenderers: Record<string, Render> = {
  form,
  questionnaire,
  'field-number': fieldNumber,
  ...fieldRenderers,
}
