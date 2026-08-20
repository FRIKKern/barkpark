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

  /* ── S8 additions: the registers rounds 2-7 settled ──────────────────────
   * Every role below was minted by the S8 call-site migration to PRESERVE a
   * rendered pair the wave had already settled — the nearest chrome step
   * would have moved it by ≥2px, or the element's height IS its line box
   * (a glyph in a fixed hit target, a text input). Naming them is the point:
   * a deliberate outlier belongs in this file, not hand-typed at the call
   * site. The rule for adding more: prove the chrome step moves geometry.
   *
   * THE INTERACTIVE SITES — the rationale, narrowed (S8 review residual,
   * mob-bl-token-guard-residuals AC3). Read literally, "the element's height
   * IS its line box" would cover EVERY glyph and EVERY text input in the app,
   * and three sites do not follow it. They were snapped onto the chrome scale
   * and so gained a lead where RN's platform default had shipped:
   *
   *   ConnectScreen#input       15/21   (single-line paste field)
   *   TaskDetailScreen#input    14/20   (multiline, maxHeight 96)
   *   TabBar#badgeText          11/15   (glyph in an 18pt round badge)
   *
   * So the licence is NOT "interactive elements get roles". It is narrower and
   * it is about EVIDENCE: a preserving role was minted where the wave had a
   * SETTLED, screenshot-reviewed rendering to preserve — the #6126 chat
   * register and the transcript's own chrome (composerInput, the four *Glyph
   * roles). The three sites above were never in that register, so there was
   * no measured pair to preserve and no honest number to invent; snapping them
   * was the conservative move, and their new leads are a real, unverified
   * change. RN's own default lead is device- and OS-dependent, which is why
   * this cannot be settled from a simulator or an AST.
   *
   * The arbiter is the physical-device pass (`mob-hg-device-boot` Part A,
   * Class-B reflow sites). Both outcomes are one line: if a site reflows
   * badly, mint a preserving role here from the MEASURED pair; if it reads
   * fine, the snap stands and this paragraph loses its three rows. Until then
   * the three pairs are pinned by name in __tests__/typeGeometry.test.ts, so
   * neither outcome can arrive by accident.
   */

  /** The transcript's answer measure — readingBody's 16/26 in the system
   * sans. #6126 settled it on the assistant turn; blocks.tsx's chat register
   * renders turn blocks at the same measure (only the face moves). */
  chatBody: { fontSize: 16, lineHeight: 26 },
  /** The transcript heading register (S3): an assistant turn is a few hundred
   * words, so the paper display head would out-shout the screen. All three
   * are the shipped fontSize × 1.3 law, rounded — the same law paperH1/H2/H3
   * follow. Each level answers the admission rule differently, so each is
   * spelled out:
   *
   *   chatH1 does NOT diverge from the chrome scale — 20 × 1.3 IS xl's 26 —
   *     so it earns a NAME but not its own numbers, and is an ALIAS. Writing
   *     `{ fontSize: 20, lineHeight: 26 }` here would have been a duplicated
   *     pair with no licence, exactly what the admission rule forbids.
   *   chatH2 coincides with paperH3's pair (both 18 × 1.3). It keeps its own
   *     numbers under the same divergence licence sectionTitle claims: a
   *     transcript heading and a printed-page heading are different
   *     registers and are free to move apart.
   *   chatH3 DOES diverge: 16 × 1.3 = 20.8 → 21, where the lg step at the
   *     same size carries 22. The heading law and the chrome ladder disagree
   *     by a pixel at 16, and the heading law wins inside a heading.
   */
  chatH1: scale.xl,
  chatH2: { fontSize: 18, lineHeight: 23 },
  chatH3: { fontSize: 16, lineHeight: 21 },
  /** The mono measure of a chat APPARATUS row — a diff line, a todo's active
   * form, a thinking block, an option chip. Deliberately airier than the xs
   * meta step: these rows are read as running text, not as labels. */
  chatApparatus: { fontSize: 12, lineHeight: 18 },

  /** A screen's shelf/section title — the 22 rung the chrome scale skips
   * (the census found 22 only twice, so it never earned a step). Shares its
   * values with paperH2 today and is deliberately a separate name: one is a
   * printed-page heading, the other is app chrome, and they are free to
   * diverge. */
  sectionTitle: { fontSize: 22, lineHeight: 29 },
  /** Reader pullquote — serif, the airiest measure on the page. */
  paperPullquote: { fontSize: 20, lineHeight: 30, fontFamily: 'serif' },
  /** Callout body — a notch under the reading measure, airier than md. */
  calloutBody: { fontSize: 15, lineHeight: 23 },
  /** Fenced code — mono wants more lead than the sm caption it shares a
   * size with. */
  codeBlock: { fontSize: 13, lineHeight: 20 },
  /** Table-of-contents row — here the lead IS the row rhythm. */
  tocRow: { fontSize: 14, lineHeight: 24 },

  /** Glyph roles: text used as an ICON inside a fixed hit target. The lead is
   * the icon box, not a reading lead — snapping these onto the chrome scale
   * moves the glyph off-centre inside its tap target. */
  backGlyph: { fontSize: 26, lineHeight: 28 },
  sendGlyph: { fontSize: 20, lineHeight: 24 },
  stopGlyph: { fontSize: 14, lineHeight: 16 },
  jumpGlyph: { fontSize: 17, lineHeight: 20 },
  /** The chat composer TextInput — its rendered height IS the line box. */
  composerInput: { fontSize: 16, lineHeight: 21 },
} as const

export type TypeRole = keyof typeof roles
