// THE CROSS-SURFACE REGISTRY TRIPWIRE (charter D48).
//
// What this file guarantees: mobile's block registry covers every type the
// CANONICAL renderer covers, and it says so by asking the canonical renderer
// itself — at test runtime, in this process — rather than by comparing two hand-
// maintained lists. The sibling pin in chatRenderers.test.tsx keeps mobile's
// registry ≡ its authored cases; that one is internally consistent and would
// stay green forever while the canonical registry grew a type mobile never
// learned. This is the pin that reds when @barkpark/react adds a renderer.
//
// WHY A DEEP RELATIVE SOURCE IMPORT, DELIBERATELY.
//   * `REGISTERED_TYPES` is not re-exported from the package entry, so
//     `@barkpark/react` cannot reach it. Reaching past the entry into
//     `src/blocks/registry` is the point, not an accident.
//   * SOURCE, not `dist/`: the built package is a CI artifact of a separate
//     job. Importing the artifact would make this tripwire green whenever the
//     build was stale, which is the exact failure it exists to catch.
//   * The relative path is what makes the coupling VISIBLE to a reader and to
//     `.github/workflows/mobile.yml`, whose paths block now includes
//     `js/packages/react/src/**` so a canonical-registry change RUNS this gate
//     instead of landing misattributed on the next mobile PR.
//   * Typecheck coupling is real and wanted: react's own tsconfig is at least
//     as strict as mobile's, so `pnpm typecheck` compiles that file under
//     mobile's settings and a type-level break surfaces here too.
//
// The count is DERIVED, never quoted. D48's counting rule: the number is
// `Object.keys(DISPATCH).length` at the instant the test runs, and every rival
// count in the wave's papers (Go-76, Elixir-75, 79-vs-83) was a regex artifact.
// A literal here would have to be edited by every slice that adds a renderer,
// which is how a tripwire becomes a chore and then a lie.
import { BLOCK_RENDERERS, DEGRADE_ONLY } from '../src/papers/portabledoc/blocks'
import { REGISTERED_TYPES } from '../../../js/packages/react/src/blocks/registry'

// react's registry module pulls in the whole emitter tree. Nothing in it
// touches react-native, but mobile's `blocks` barrel does, and the WebView
// TurboModule throws at import time under jest-expo unless it is mocked (8
// precedents in this suite).
jest.mock('react-native-webview', () => ({ WebView: () => null }))

/** Canonical types mobile deliberately does NOT register.
 *
 * EMPTY, and that emptiness is the wave's headline result: the 23 types that
 * degraded to the labeled unknown-block box at the start of this wave are all
 * natively rendered now, including the four that were proposed for a degrade
 * ruling (sheet, task-board, form, questionnaire — D46 ruled them native with
 * recorded narrowings) and the two that genuinely degrade (video, asciicast —
 * which are REGISTERED degrade cards, so they belong in the registry, not
 * here; see DEGRADE_ONLY below).
 *
 * A row added here is a RULING and must carry its reason in this comment and in
 * the charter. Silence is the thing this wave abolished: an unrendered type
 * either has a recorded ruling or it reds. */
const EXCLUSIONS: ReadonlySet<string> = new Set([])

/** Types mobile registers that the canonical renderer does not.
 *
 * EMPTY today. This is not a loophole — an unrecorded extra key still reds
 * below. It exists because mobile is legitimately allowed to run AHEAD of the
 * canonical registry on the authoring-drift aliases: `mob-zb-bl-heading-alias-
 * drift` records that h1/h2/h3 and ordered-list are unknown-boxed on EVERY
 * surface today (20 live blocks), and whichever surface fixes that first will
 * hold keys the others lack for as long as it takes the rest to catch up. When
 * that slice lands on mobile, its four keys go here WITH the task slug — and
 * the row is the standing reminder that react and Elixir still owe the same
 * fix. */
const MOBILE_AHEAD: ReadonlySet<string> = new Set([])

const canonical = [...REGISTERED_TYPES].sort()
const mobile = Object.keys(BLOCK_RENDERERS).sort()

describe('cross-surface registry parity (charter D48)', () => {
  it('imported the CANONICAL registry, not an empty module', () => {
    // The vacuous-green guard. A moved file, a renamed export or a bundler
    // resolving this to a stub would leave every assertion below trivially
    // true; a subset test over an empty set passes. So the corpus is proven
    // non-trivial before it is trusted.
    expect(Array.isArray(REGISTERED_TYPES)).toBe(true)
    expect(REGISTERED_TYPES.length).toBeGreaterThan(50)
    expect(new Set(canonical).size).toBe(canonical.length)
    // Two spot types from opposite ends of react's DISPATCH assembly — one
    // from coreEmitters, one from the last family spread in. If the import
    // ever resolved to some other module that happened to export a string
    // array, these are what catch it.
    expect(canonical).toContain('paragraph')
    expect(canonical).toContain('equation')
  })

  it('registers EVERY canonical type — react ∖ EXCLUSIONS ⊆ mobile', () => {
    const missing = canonical.filter((t) => !mobile.includes(t) && !EXCLUSIONS.has(t))
    expect(missing).toEqual([])
  })

  it('registers NOTHING the canonical registry lacks — mobile ∖ react ⊆ MOBILE_AHEAD', () => {
    const extra = mobile.filter((t) => !canonical.includes(t) && !MOBILE_AHEAD.has(t))
    expect(extra).toEqual([])
  })

  it('keeps both allowance sets HONEST — no stale row survives its reason', () => {
    // An EXCLUSIONS row for a type mobile actually renders, or a MOBILE_AHEAD
    // row for a type react has since adopted, is a ruling that outlived its
    // fact. Either one reds here, which is what stops the allowance sets from
    // silently becoming the place drift goes to hide.
    for (const t of EXCLUSIONS) {
      expect(mobile).not.toContain(t)
      expect(canonical).toContain(t)
    }
    for (const t of MOBILE_AHEAD) {
      expect(mobile).toContain(t)
      expect(canonical).not.toContain(t)
    }
  })

  it('proves the wave: the EXCLUSIONS ledger is EMPTY — zero unknown blocks by construction', () => {
    expect([...EXCLUSIONS]).toEqual([])
    // The two honest degrade cards are REGISTERED types, not exclusions: a
    // block of either draws its labeled card wherever the document path is
    // taken. D47's subtraction happens one level up, at TURN level, and this
    // asserts the two facts do not get conflated.
    for (const t of DEGRADE_ONLY) {
      expect(mobile).toContain(t)
      expect(EXCLUSIONS.has(t)).toBe(false)
    }
  })

  it('agrees with the sibling registry ≡ cases pin on the SAME set', () => {
    // chatRenderers.test.tsx pins Object.keys(BLOCK_RENDERERS) ≡ authored
    // cases. Both suites must be talking about one registry, so a future
    // refactor that gave the barrel a second export surface cannot make the
    // two pins drift apart while both stay green.
    expect(mobile.length).toBe(new Set(mobile).size)
    expect(mobile.length).toBe(canonical.length - EXCLUSIONS.size + MOBILE_AHEAD.size)
  })
})
