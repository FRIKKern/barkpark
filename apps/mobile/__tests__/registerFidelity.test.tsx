// THE REGISTER-FIDELITY TRIPWIRE (charter D50).
//
// One dispatcher renders the same block tree in two typographic voices: the
// reader's serif `paper` register and the transcript's sans `chat` register. D50
// exists because the failure mode here is SILENT in both directions:
//
//   * A LEAK. `ingress` and `pullquote` painted `fontFamily:'serif'` in the chat
//     register — a printed-page face inside a chat answer. Every per-type test
//     was green: each asserted the block rendered, none asked in which voice.
//   * A DROP. A container that recursed with a re-minted `ctx` literal instead
//     of forwarding `ctx` wholesale would silently reset every nested block to
//     the default register, and no per-block test could see it either, because
//     each block renders correctly — just in the wrong voice.
//
// So this suite asks the questions the per-family suites structurally cannot,
// and it asks them of EVERY registered type rather than of a chosen sample.
//
// THE MECHANISM, measured rather than assumed (arm 0 below). The two registers
// differ in exactly two things: prose runs carry `fontFamily:'serif'` in paper
// and no face at all in chat, and the three heading steps take different sizes.
// Nothing else. That is what makes the arms below meaningful: a type is
// register-SENSITIVE precisely when it routes text through `bodyText(ctx)` or
// `spec(ctx).heading[n]`, and register-BLIND when every string it paints sits on
// a fixed `scale.*` chrome rung. Blindness is therefore a real, checkable
// property of a renderer — not a shrug.
//
// THE INSTRUMENT'S ONE BLIND SPOT, stated because a mutation found it rather
// than a reading. `roles.readingBody` and `roles.chatBody` are BOTH 16/26 and
// differ only in `fontFamily`, so the entire observable difference between the
// registers on a body run is the face. A renderer that calls `bodyText(ctx)` and
// then overrides `fontFamily` — which a mono cell legitimately does — reads the
// register and paints identically in both. This suite measures PAINT, so it
// classifies that renderer as blind, and that is the correct call: a difference
// no pixel can show is not a difference. What it means in practice is that arm 3
// cannot be used to prove a renderer "consults the register"; it proves only
// that the register CHANGES something. Arm 2 is the one that proves propagation,
// and it does so by pinning the child's exact style rather than by pinning
// inequality.
import { styleCensus, walk } from './support/walk'
import { MermaidIsland } from '../src/papers/portabledoc/MermaidIsland'
import { BLOCK_RENDERERS, renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { REGISTERS } from '../src/papers/portabledoc/register'
import { light } from '../src/ui/theme'
import { chatCases } from './cases/chat.cases'
import { coreCodeCases } from './cases/core-code.cases'
import { coreContainerCases } from './cases/core-container.cases'
import { coreDocCases } from './cases/core-doc.cases'
import { coreMediaCases } from './cases/core-media.cases'
import { coreProseCases } from './cases/core-prose.cases'
import { datavizCases } from './cases/dataviz.cases'
import { formsCases } from './cases/forms.cases'
import { mathCases } from './cases/math.cases'
import { sheetCases } from './cases/sheet.cases'
import { tableCases } from './cases/table.cases'
import { taskboardCases } from './cases/taskboard.cases'
import type { BlockCase } from './cases/types'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme = light
const paper: BlockCtx = { theme }
const chat: BlockCtx = { theme, register: 'chat' }
const OPAQUE = [MermaidIsland]

/** The same per-family case files the registry ≡ cases pin uses, so this suite
 * covers every registered type by construction: a renderer added without a
 * case already reds in chatRenderers.test.tsx, and once its case exists it is
 * measured here too. Nothing to keep in sync by hand. */
const CASES: BlockCase[] = [
  ...coreProseCases,
  ...coreMediaCases,
  ...coreContainerCases,
  ...coreDocCases,
  ...coreCodeCases,
  ...datavizCases,
  ...formsCases,
  ...mathCases,
  ...sheetCases,
  ...tableCases,
  ...taskboardCases,
  ...chatCases,
]

const PROSE = { type: 'paragraph', text: 'a prose run' }

/** The container types that recurse ARBITRARY child blocks back through the
 * dispatcher — the complete set, taken from the nine `renderBlockNative(` call
 * sites in src/papers/portabledoc/blocks/ (the tenth, code-tabs, injects a
 * synthetic `code` block rather than author children).
 *
 * Each is probed with a prose child, for a reason that matters: a container has
 * no measure of its OWN, so its authored registry case — which mostly carries
 * chrome-only children — makes it look register-blind when its real and only
 * obligation is to PROPAGATE. Measuring these with a prose child is what turns
 * "no style difference" from a false clean bill into the actual question. */
const CONTAINERS: [string, Record<string, unknown>][] = [
  ['section', { type: 'section', blocks: [PROSE] }],
  ['columns', { type: 'columns', columns: [[PROSE]] }],
  ['terminal', { type: 'terminal', children: [PROSE] }],
  ['steps', { type: 'steps', steps: [{ title: 'Step', blocks: [PROSE] }] }],
  ['expandable', { type: 'expandable', summary: 'More', blocks: [PROSE] }],
  ['tabs', { type: 'tabs', tabs: [{ label: 'A', blocks: [PROSE] }] }],
  ['card', { type: 'card', slots: { body: [PROSE] } }],
  ['figure', { type: 'figure', child: PROSE }],
]

/** WHY a type may be register-blind. Blindness is legitimate only when the
 * renderer has no prose measure to carry; each class below names the evidence
 * that this is so, and every allowlisted type is assigned one. */
type Reason =
  /** Every string is apparatus — a mono row label, a digit, an axis tick — on a
   * fixed chrome rung. The per-file ruling is dataviz.tsx's own header (D56). */
  | 'dataviz-apparatus'
  /** Tabular chrome. The reference CSS is the evidence, not a convenience:
   * `.bp-sheet__td` is the MONO face at 0.88rem, `.bp-sheet__th` a 0.78rem
   * uppercase label, `.bp-bcard__t` 0.8rem — all below the prose measure, so
   * there is no body run to carry. Recorded per type in sheet.tsx's header and
   * pinned byte-identical between registers in gridNatives.test.tsx (D46b/c). */
  | 'tabular-chrome'
  /** The content IS code, a path or a diff hunk: the mono face on every surface,
   * in either register. A serif or sans body measure would be WRONG here. */
  | 'mono-apparatus'
  /** A label, a credit line, a kicker, a caption, a stat rung or a board/list
   * row title — chrome the reference surface also sets below the body measure
   * (`.bp-stat__l` 0.72rem, `.bp-legend__n` mono 0.74rem, `.bp-legend__r`
   * 0.82rem, `.bp-toc__item` 0.88–0.92em with mono markers). */
  | 'label-chrome'
  /** Author PROSE painted at a fixed chrome rung rather than through
   * `bodyText(ctx)`. Blind, and honestly a NARROWING rather than a clean
   * ruling: the reference surface inherits its serif face into these runs
   * (`.bp-note__d` 0.92rem, `.bp-footnotes`, `.bp-form-question > legend`
   * 1.02rem), so the PAPER register is arguably owed a serif face here that
   * mobile does not give it. Both registers agree, which is what this suite
   * measures; whether they agree on the right VALUE is filed as
   * task-1a950cceef6599b5, recorded rather than ridden — and if that task rules
   * the serif face IN, these rows must be REMOVED, which the stale-row arm below
   * forces rather than leaves to memory. */
  | 'secondary-prose-narrowing'
  /** Paints no text at all — one 1px rule. D50 names divider as the class. */
  | 'no-text'
  /** The subtree is a WebView whose HTML is assembled in an effect, so it is not
   * a pure function of the block and the walker stops at it by design. */
  | 'opaque-island'
  /** An honest degrade card (D46d): a labeled box stating its ceiling. The label
   * is renderer-owned chrome, never author prose. */
  | 'degrade-card'
  /** Born in the chat register by a server-side writer and only ever read in a
   * transcript (D25/D35/D54). Its whole vocabulary is chat chrome; there is no
   * paper voice for it to have. */
  | 'chat-native'
  /** Math atoms size RELATIVE TO EACH OTHER — a superscript is a fraction of
   * its base, not of the register (D45). The type ladder is internal. */
  | 'own-type-ladder'

/** THE REGISTER_BLIND ALLOWLIST (D50). Every registered type not listed here
 * MUST paint differently in the two registers. Every type listed here must
 * paint IDENTICALLY — a stale row reds just as loudly as a missing one, which
 * is what stops this list from becoming the place drift hides. */
const REGISTER_BLIND: Record<string, Reason> = {
  // ── dataviz (5) — dataviz.tsx header ruling, D56
  chart: 'dataviz-apparatus',
  // route: the track paints as rotated Views; every string is the micro mono
  // meta row / caption chrome — no prose measure to carry (dataviz.tsx §route).
  route: 'dataviz-apparatus',
  'bar-chart': 'dataviz-apparatus',
  heatmap: 'dataviz-apparatus',
  'gauge-list': 'dataviz-apparatus',
  'criteria-progress': 'dataviz-apparatus',

  // ── grids (3) — D46b/c; the CROWN HANDOFF's blocking item. Both sheet and
  // task-board are DELIBERATELY register-blind with the ruling recorded in
  // sheet.tsx's header and a byte-identical pin in gridNatives.test.tsx; a
  // tripwire that demanded a difference here would red on legitimate
  // blindness. `table` is the class D50 itself names.
  sheet: 'tabular-chrome',
  'task-board': 'tabular-chrome',
  table: 'tabular-chrome',

  // ── mono apparatus (3)
  'api-endpoint': 'mono-apparatus',
  diff: 'mono-apparatus',
  filetree: 'mono-apparatus',

  // ── label / row chrome (15)
  action: 'label-chrome',
  // field-number (B085): a labelled numeric definition row — label + value
  // chrome with no prose measure to carry, the `stat` precedent
  // (pbw-fix-field-number-react).
  'field-number': 'label-chrome',
  byline: 'label-chrome',
  eyebrow: 'label-chrome',
  toc: 'label-chrome',
  stat: 'label-chrome',
  stats: 'label-chrome',
  'stat-grid': 'label-chrome',
  'status-legend': 'label-chrome',
  tasks: 'label-chrome',
  'task-list': 'label-chrome',
  pipeline: 'label-chrome',
  stage: 'label-chrome',
  roadmap: 'label-chrome',
  image: 'label-chrome',

  // ── secondary prose at a fixed rung (6) — a recorded NARROWING, filed
  footnote: 'secondary-prose-narrowing',
  note: 'secondary-prose-narrowing',
  notes: 'secondary-prose-narrowing',
  cards: 'secondary-prose-narrowing',
  form: 'secondary-prose-narrowing',
  questionnaire: 'secondary-prose-narrowing',

  // ── the singletons (4)
  divider: 'no-text',
  diagram: 'opaque-island',
  video: 'degrade-card',
  asciicast: 'degrade-card',

  // ── chat natives (6)
  'chat-approval': 'chat-native',
  'chat-plan': 'chat-native',
  'chat-question': 'chat-native',
  'chat-thinking': 'chat-native',
  'chat-todo': 'chat-native',
  'chat-tool-diff': 'chat-native',

  // ── math (1)
  equation: 'own-type-ladder',
}

function census(block: unknown, ctx: BlockCtx): string {
  return styleCensus(walk(renderBlockNative(block, ctx, 0), OPAQUE))
}

/** The block to measure a type with: its authored registry case, except for the
 * arbitrary-child containers, which are measured with a prose child (see
 * CONTAINERS). */
function probeFor(type: string): Record<string, unknown> | undefined {
  const container = CONTAINERS.find(([name]) => name === type)
  if (container) return container[1]
  return CASES.find((c) => c.type === type)?.block
}

/* ══ arm 0 — what the register actually carries ══════════════════════════════ */

describe('the register mechanism (the ground the arms below stand on)', () => {
  it('differs in EXACTLY one style key on a prose run: the serif face', () => {
    const p = walk(renderBlockNative(PROSE, paper, 0)).styles
    const c = walk(renderBlockNative(PROSE, chat, 0)).styles
    expect(p).toHaveLength(1)
    expect(c).toHaveLength(1)
    const keys = new Set([...Object.keys(p[0] ?? {}), ...Object.keys(c[0] ?? {})])
    const differing = [...keys].filter((k) => p[0]?.[k] !== c[0]?.[k]).sort()
    expect(differing).toEqual(['fontFamily'])
    expect(p[0]?.fontFamily).toBe('serif')
    expect(c[0]?.fontFamily).toBeUndefined()
  })

  it('carries the serif face on the PAPER body token and nowhere in chat', () => {
    // Asserted against the register table itself, so the claim the allowlist
    // reasons from ("blind ⟺ no bodyText/heading measure") is executed rather
    // than believed.
    expect(REGISTERS.paper.body.fontFamily).toBe('serif')
    expect(REGISTERS.chat.body.fontFamily).toBeUndefined()
    for (const level of [1, 2, 3] as const) {
      expect(REGISTERS.paper.heading[level].step.fontSize).not.toBe(
        REGISTERS.chat.heading[level].step.fontSize,
      )
    }
  })
})

/* ══ arm 1 — the leak guard: NO serif anywhere in a chat turn ════════════════ */

describe('arm 1 — the chat register never speaks in the printed-page face', () => {
  it('paints ZERO serif runs in the chat register, across every registered type', () => {
    // No allowlist, and none is possible: a chat answer is speech (D22). This
    // is the measured D50 leak, generalised from the two types that had it to
    // EVERY registered type — including every type a future slice adds, since
    // the corpus is the case files. (This comment used to say "all 66". The
    // number was correct for about four hours: the heading-alias slice took the
    // registry to 70 the same night. Prose is not exempt from "derive, never
    // quote" — a count in a comment rots exactly as fast as one in an
    // assertion, and it rots SILENTLY because no gate reads it.)
    const leaks: string[] = []
    for (const { type, block } of CASES) {
      const styles = walk(renderBlockNative(block, chat, 0), OPAQUE).styles
      if (styles.some((s) => s.fontFamily === 'serif')) leaks.push(type)
    }
    expect(leaks).toEqual([])
  })

  it('still paints serif in the PAPER register — so arm 1 is not vacuously green', () => {
    // The counterweight. If prose stopped carrying serif in paper too, the
    // assertion above would pass for the wrong reason and the reader would
    // silently lose the document voice.
    const serifTypes = CASES.filter(({ block }) =>
      walk(renderBlockNative(block, paper, 0), OPAQUE).styles.some((s) => s.fontFamily === 'serif'),
    ).map((c) => c.type)
    expect(serifTypes).toContain('paragraph')
    expect(serifTypes).toContain('ingress')
    expect(serifTypes).toContain('pullquote')
    expect(serifTypes.length).toBeGreaterThan(3)
  })
})

/* ══ arm 2 — the drop guard: containers propagate the register ═══════════════ */

describe('arm 2 — every container forwards the register to its children', () => {
  it('covers every arbitrary-child container in the tree', () => {
    // The CONTAINERS list is hand-derived from the recursion call sites, so it
    // is the one thing here that can silently fall behind. Each entry must at
    // least still BE a registered type; a renamed or removed container reds.
    for (const [name] of CONTAINERS) expect(BLOCK_RENDERERS[name]).toBeDefined()
    expect(CONTAINERS).toHaveLength(8)
  })

  it('lands the register-correct prose measure on the nested child', () => {
    // The precise question a re-minted `ctx` literal fails: not "did the child
    // render" but "did it render in the voice its ANCESTOR was called with".
    const paperProse = walk(renderBlockNative(PROSE, paper, 0)).styles[0]
    const chatProse = walk(renderBlockNative(PROSE, chat, 0)).styles[0]
    for (const [name, block] of CONTAINERS) {
      const inPaper = walk(renderBlockNative(block, paper, 0), OPAQUE).styles
      const inChat = walk(renderBlockNative(block, chat, 0), OPAQUE).styles
      expect(`${name} in paper`).toBe(`${name} in paper`)
      expect(inPaper).toContainEqual(paperProse)
      expect(inChat).toContainEqual(chatProse)
      // …and the two are not the same tree, which is the same fact stated so
      // that a future paperProse ≡ chatProse regression cannot make both
      // assertions above pass together.
      expect(census(block, paper)).not.toEqual(census(block, chat))
    }
  })
})

/* ══ arm 3 — the fingerprint: every type differs, or is allowlisted ══════════ */

describe('arm 3 — the register fingerprint (D50 REGISTER_BLIND)', () => {
  it('measures EVERY registered type — no type escapes the fingerprint', () => {
    const unprobed = Object.keys(BLOCK_RENDERERS).filter((t) => probeFor(t) === undefined)
    expect(unprobed).toEqual([])
  })

  it('paints differently in the two registers unless allowlisted', () => {
    const blindButNotAllowed: string[] = []
    for (const type of Object.keys(BLOCK_RENDERERS)) {
      if (REGISTER_BLIND[type] !== undefined) continue
      if (census(probeFor(type), paper) === census(probeFor(type), chat)) blindButNotAllowed.push(type)
    }
    // A type landing here is the D50 leak or drop, caught: it renders text that
    // ignores the register. The fix is a `bodyText(ctx)` / `spec(ctx)` run —
    // adding a row to REGISTER_BLIND is the answer ONLY when the renderer
    // genuinely has no prose measure, and that answer owes a Reason and a
    // header note in the family file.
    expect(blindButNotAllowed.sort()).toEqual([])
  })

  it('keeps the allowlist HONEST — every row is still actually blind', () => {
    // The other direction, and the one that makes this a tripwire rather than
    // documentation. A slice that makes sheet or task-board register-aware must
    // revisit the recorded ruling instead of leaving a row that no longer
    // describes the code (the gridNatives pin's own reasoning, generalised).
    const staleRows: string[] = []
    for (const type of Object.keys(REGISTER_BLIND)) {
      if (BLOCK_RENDERERS[type] === undefined) {
        staleRows.push(`${type} (not registered)`)
        continue
      }
      if (census(probeFor(type), paper) !== census(probeFor(type), chat)) {
        staleRows.push(`${type} (now register-aware)`)
      }
    }
    expect(staleRows.sort()).toEqual([])
  })

  it('assigns every allowlisted type one of the recorded reason classes', () => {
    const classes = new Set<Reason>([
      'dataviz-apparatus',
      'tabular-chrome',
      'mono-apparatus',
      'label-chrome',
      'secondary-prose-narrowing',
      'no-text',
      'opaque-island',
      'degrade-card',
      'chat-native',
      'own-type-ladder',
    ])
    for (const [type, reason] of Object.entries(REGISTER_BLIND)) {
      expect(`${type}: ${classes.has(reason)}`).toBe(`${type}: true`)
    }
    // The blind majority is not a shrug: it is what a block vocabulary made
    // mostly of task rows, charts, grids and code apparatus looks like. The
    // types that carry the DOCUMENT are the sensitive ones, and they are the
    // minority by design.
    // The ONE deliberate literal in this suite, and the distinction matters.
    // A cross-surface count (how many types react registers) must never be
    // pinned — it changes under you, as 66→70 proved the same night this landed.
    // This number is different in kind: REGISTER_BLIND is hand-authored IN THIS
    // FILE, so the literal is not a fact about another surface but a speed-bump
    // on my own allowlist — growing it should cost a deliberate edit, because
    // every new row is a RULING that something legitimately ignores the
    // register. It cannot rot from the outside.
    // 43 → 44: field-number's label-chrome ruling (pbw-fix-field-number-react).
    expect(Object.keys(REGISTER_BLIND)).toHaveLength(44)
    // Derived from the map, never a second copy of the literal above: the
    // partition must be total, with no type both blind and sensitive.
    const sensitive = Object.keys(BLOCK_RENDERERS).filter((t) => REGISTER_BLIND[t] === undefined)
    expect(sensitive.length).toBe(Object.keys(BLOCK_RENDERERS).length - Object.keys(REGISTER_BLIND).length)
    for (const t of ['paragraph', 'heading', 'ingress', 'pullquote', 'blockquote', 'list', 'callout']) {
      expect(sensitive).toContain(t)
    }
  })
})
