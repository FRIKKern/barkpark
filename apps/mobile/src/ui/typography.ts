// Typography tokens — stage 1 of the mobile type system (t3code wave,
// /papers/t3code-upgrade-premium-tokens ratified call #11; charter D21 S1).
//
// The 8-step chrome scale below is CENSUS-DERIVED: it absorbs ~93% of the
// fontSize literals the app already ships WITHOUT moving them (fontSize 15
// and 11 are mobile's 2nd and 5th most-used sizes and stay first-class —
// the Unified Aesthetic manifest lacks both, which is exactly why joining
// the manifest now would repaint shipped taste; stage 2 captures these
// values verbatim as a per-surface family once taste settles).
//
// Every step pairs fontSize with an explicit lineHeight — the census found
// ~103 of 124 sites setting none, silently shipping the platform default.
//
// Weight is deliberately NOT tokenized: the app's weights are few, local
// and legible at the call site ('600' for emphasis, '700' for headings).
//
// STAGE-1 LAW: this file defines tokens ONLY. Call-site migration is a
// separate slice (S8: the 12-file migration, then the ESLint literal ban) —
// do not migrate screens as a side effect of touching this file.

export interface TypeStep {
  fontSize: number
  lineHeight: number
}

/** The 8-step chrome scale: micro 11/15 → display 26/32. */
export const scale = {
  micro: { fontSize: 11, lineHeight: 15 },
  xs: { fontSize: 12, lineHeight: 16 },
  sm: { fontSize: 13, lineHeight: 18 },
  base: { fontSize: 14, lineHeight: 20 },
  md: { fontSize: 15, lineHeight: 21 },
  lg: { fontSize: 16, lineHeight: 22 },
  xl: { fontSize: 20, lineHeight: 26 },
  display: { fontSize: 26, lineHeight: 32 },
} as const satisfies Record<string, TypeStep>

export type ScaleStep = keyof typeof scale

/** Named roles for the deliberate outliers — the sizes that are a design
 * decision, not a rung on the chrome ladder. Serif roles carry their
 * fontFamily; paper headings follow the ×1.3 lineHeight law (rounded). */
export const roles = {
  /** Paper reading body — the serif measure the native reader ships. */
  readingBody: { fontSize: 16, lineHeight: 26, fontFamily: 'serif' },
  /** The user chat bubble (the #6126 register). */
  userBubble: { fontSize: 16, lineHeight: 23 },
  /** Paper headings: lineHeight = fontSize × 1.3, rounded. */
  paperH1: { fontSize: 26, lineHeight: 34 },
  paperH2: { fontSize: 22, lineHeight: 29 },
  paperH3: { fontSize: 18, lineHeight: 23 },
  /** Paper ingress/lede — serif, airier than readingBody. */
  paperIngress: { fontSize: 19, lineHeight: 30, fontFamily: 'serif' },
  /** Stat-block value figure. */
  statValue: { fontSize: 24, lineHeight: 30 },
  /** Login-screen brand wordmark. */
  brandWordmark: { fontSize: 34, lineHeight: 40 },
  /** Device-flow pairing code. */
  deviceCode: { fontSize: 30, lineHeight: 36 },
} as const

export type TypeRole = keyof typeof roles
