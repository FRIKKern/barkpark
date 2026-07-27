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
// TWO RECORDED DIVERGENCES from the web twin, both toward the honest-ceiling
// doctrine and both taken from the TUI:
//
//   1. A `scale` whose span exceeds 100 rungs SUMMARIZES as "min … max"
//      (scaleLadder's guard) rather than the web's clamp-and-enumerate to 101
//      rungs. 101 stacked radio rows on a phone is a hostile render, and the
//      summary is what the terminal already shows.
//   2. An option-LESS `single`/`multi` falls back to a real control (Yes/No
//      radios, one "Option" checkbox — formControl's arms) rather than the
//      web's empty <div>. A control that renders nothing is a silent hole; the
//      question's shape must survive missing options.
//
// Metro TDZ law (D49): this module imports renderBlockNative ONLY — never
// BLOCK_RENDERERS.
import type { ReactNode } from 'react'
import { Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { asList, isMap, str } from '../model'
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

// `questionnaire` is a PURE ALIAS of `form`: both twins differ only by the
// container's CSS class (react forms.ts:79 picks bp-form-questionnaire; the TUI
// registers both types to the SAME formRenderer), and React Native has no class
// names — so on this surface the alias is TOTAL, the two types render
// byte-identical trees. It stays a distinct function rather than a second key
// onto `form` because the registry's alias tripwire enumerates function
// IDENTITIES: this is an alias of behavior, not of implementation, exactly the
// shape the web twin chose (a delegating Emit).
const questionnaire: Render = (b, ctx, key) => form(b, ctx, key)

export const formsRenderers: Record<string, Render> = { form, questionnaire }
