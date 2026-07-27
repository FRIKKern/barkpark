// THE CROWN FLOOR (charter D51): every block type in the generator-owned
// cross-surface parity corpus renders on mobile, in BOTH typographic registers,
// with zero unknown-block degrades — asserted in CI, over the real fixtures, on
// every mobile PR.
//
// WHY THIS CORPUS AND NOT A SHOWCASE PAPER. D51 rejected the "106-block
// showcase" as the proof: it misses 28 of the registered keys, so a suite built
// on it would be green while a third of the registry was broken — vacuous by
// construction. `api/test/support/fixtures/pd-parity/` is the corpus that
// already exists for exactly this purpose: one generator-owned file per type
// (`mix barkpark.portable_doc.gen_pd_parity` is its sole writer), carrying the
// frozen Elixir :article HTML plus the input that produced it. The canonical JS
// renderer is already proven shape-equal to these; consuming the same `input`
// makes mobile the third surface measured against one artifact instead of
// against a hand-written mobile-only fixture that could drift to fit.
//
// THE FIXTURE SHAPE LAW, and the trap it closes. Each file is
// `{_comment, expectedHtml, input, shape, type}` where `input` is ONE block map
// — NOT `{blocks: […]}`. A harness that iterated `j.blocks` would find
// undefined in all 60 files, skip every one, and pass. So the shape is asserted
// per file before anything is rendered, and the corpus size is pinned from
// below: this suite cannot report success over an empty or truncated corpus.
//
// Read from disk rather than imported: `readdirSync` means a NEW fixture is
// covered the moment the generator writes it, with no import list to forget.
// mobile.yml's paths block includes the fixture directory so a regen runs this
// gate.
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

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
import { walk } from './support/walk'
import { MermaidIsland } from '../src/papers/portabledoc/MermaidIsland'
import {
  BLOCK_RENDERERS,
  renderBlockNative,
  resetUnknownBlockLog,
  type BlockCtx,
} from '../src/papers/portabledoc/blocks'
import { light } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme = light
/** The two registers D51 requires the floor to hold in. One dispatcher renders
 * both, so a type that paints in the reader and blows up in a chat turn is a
 * live possibility — hence every fixture is driven twice. */
const REGISTERS: [string, BlockCtx][] = [
  ['paper', { theme }],
  ['chat', { theme, register: 'chat' }],
]

/** Component types the walker counts without descending into: MermaidIsland
 * renders a WebView whose HTML is assembled in an effect, so its subtree is not
 * a pure function of the block. Counting it IS the paint proof for `diagram`. */
const OPAQUE = [MermaidIsland]

interface Fixture {
  type: string
  input: Record<string, unknown>
  /** The whole parsed file — kept so the shape law can be asserted about the
   * FILE's own keys, which is where the trap lives. */
  raw: Record<string, unknown>
  file: string
}

const FIXTURE_DIR = join(__dirname, '..', '..', '..', 'api', 'test', 'support', 'fixtures', 'pd-parity')

/** The corpus floor: one fixture per CANONICAL type, which is fewer than the
 * registry holds because the authoring-drift spellings share their canonical
 * type's fixture. Pinned from BELOW, never at equality — the generator adding a
 * type must not red this line, and neither must a slice adding an alias, while a
 * path typo, a moved directory or a half-written corpus (each of which would
 * otherwise pass silently) must. Deliberately NOT stated as a ratio to the
 * registry size: that arithmetic is what broke when h1/h2/h3/ordered-list
 * landed mid-branch. */
const MIN_FIXTURES = 60

function loadFixtures(): Fixture[] {
  const files = readdirSync(FIXTURE_DIR).filter((f) => f.endsWith('.golden.json'))
  return files.map((file) => {
    const parsed = JSON.parse(readFileSync(join(FIXTURE_DIR, file), 'utf8')) as Record<string, unknown>
    return {
      type: String(parsed.type),
      input: parsed.input as Record<string, unknown>,
      raw: parsed,
      file,
    }
  })
}

const FIXTURES = loadFixtures()

/** The authored per-family cases, used ONLY to drive the types the generator
 * gives no fixture (the authoring-drift spellings). Concatenated from the same
 * files chatRenderers.test.tsx pins against the registry, so this list cannot
 * fall behind a new renderer. */
const ALL_CASES: BlockCase[] = [
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

describe('the pd-parity corpus is the shape this suite believes it is', () => {
  it('found a REAL corpus — never reports success over an empty directory', () => {
    expect(FIXTURES.length).toBeGreaterThanOrEqual(MIN_FIXTURES)
  })

  it('carries ONE block under `input`, never a {blocks: […]} wrapper (D51 shape law)', () => {
    for (const { file, type, input, raw } of FIXTURES) {
      // THE TRAP, asserted about the FILE: a harness written against
      // `j.blocks` finds undefined in all 60 files, renders nothing, and
      // passes. `input` is the only block-bearing key, and there is no
      // `blocks` sibling to reach for by mistake.
      expect(`${file}: has input=${'input' in raw} has blocks=${'blocks' in raw}`).toBe(
        `${file}: has input=true has blocks=false`,
      )
      // …and `input` is ONE block map, not an array of them.
      expect(`${file}: ${typeof input} array=${Array.isArray(input)}`).toBe(`${file}: object array=false`)
      expect(input).not.toBeNull()
      // The one block's own type agrees with the file's declared type, so
      // iterating files IS iterating types. (A container block legitimately
      // carries its OWN `blocks` key — `expandable` does — which is why the
      // trap above is asserted one level up and not here.)
      expect(`${file}: ${String(input.type)}`).toBe(`${file}: ${type}`)
    }
  })

  it('leaves NO registered type unmeasured — fixture-covered, or driven here', () => {
    // The generator emits one fixture per CANONICAL type, so the authoring-drift
    // spellings (bulletList, quote, h1/h2/h3, ordered-list, …) legitimately have
    // none. What must never happen is a registered type that no corpus measures
    // at all.
    //
    // This assertion used to ENUMERATE the fixture-less types, and that was the
    // wrong shape: `mob-zb-bl-heading-alias-drift` landed h1/h2/h3/ordered-list
    // on all four surfaces while this branch was in flight and the literal red
    // on the merge ref — a maintenance chore masquerading as a guarantee, which
    // is exactly what D48 says a count must never be. So the set is DERIVED, and
    // the guarantee is the stronger one: every fixture-less type has an authored
    // case AND is rendered here, in both registers, right now.
    const covered = new Set(FIXTURES.map((f) => f.type))
    const fixtureless = Object.keys(BLOCK_RENDERERS)
      .filter((t) => !covered.has(t))
      .sort()
    const cased = new Set(ALL_CASES.map((c) => c.type))
    expect(fixtureless.filter((t) => !cased.has(t))).toEqual([])

    resetUnknownBlockLog()
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      for (const type of fixtureless) {
        const block = ALL_CASES.find((c) => c.type === type)?.block
        for (const [name, ctx] of REGISTERS) {
          const out = walk(renderBlockNative(block, ctx, 0), OPAQUE)
          expect(`${type}/${name}: ${out.text}`).not.toContain('Unsupported block')
          expect(`${type}/${name} painted`).toBe(
            out.text.trim() === '' && out.styles.length === 0 && out.opaque === 0
              ? `${type}/${name} BLANK`
              : `${type}/${name} painted`,
          )
        }
      }
      expect(warn.mock.calls.map((c) => String(c[0]))).toEqual([])
    } finally {
      warn.mockRestore()
    }
  })

  it('keeps the corpus itself covering the canonical vocabulary', () => {
    // The counterweight to deriving the set above: if the corpus shrank, every
    // type would migrate into the fixture-less arm and still be "measured",
    // which would quietly turn the cross-surface floor into a mobile-only one.
    // So the number of types the CORPUS covers is pinned from below too.
    expect(new Set(FIXTURES.map((f) => f.type)).size).toBeGreaterThanOrEqual(MIN_FIXTURES)
  })

  it('registers a renderer for every type in the corpus', () => {
    const unregistered = FIXTURES.filter((f) => BLOCK_RENDERERS[f.type] === undefined).map((f) => f.type)
    expect(unregistered).toEqual([])
  })
})

describe('CROWN FLOOR — zero unknown blocks across the corpus, in both registers', () => {
  it('renders all 60 fixture inputs with NO unknown-block degrade', () => {
    resetUnknownBlockLog()
    // The dispatcher logs once per unrecognised type. The spy is the SECOND,
    // independent witness: the visible text assertion below could in principle
    // be defeated by a renderer that swallowed the fallback, but nothing
    // reaches unknownBlock without passing through this warn.
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      for (const { type, input } of FIXTURES) {
        for (const [name, ctx] of REGISTERS) {
          const out = walk(renderBlockNative(input, ctx, 0), OPAQUE)
          expect(`${type}/${name}: ${out.text}`).not.toContain('Unsupported block')
          expect(`${type}/${name}: ${out.text}`).not.toContain('invalid block')
        }
      }
      expect(warn.mock.calls.map((c) => String(c[0]))).toEqual([])
    } finally {
      warn.mockRestore()
    }
  })

  it('PAINTS something for every fixture in both registers — never a silent empty node', () => {
    // The other half of "no unknown blocks". A renderer that returned `null`
    // for a well-formed block would satisfy every assertion above while
    // showing the reader nothing at all — the silent hole this wave exists to
    // abolish, and a strictly worse failure than the labeled box because it
    // leaves no trace. Paint = visible text, OR a styled element (a divider is
    // one 1px rule and no text), OR an opaque island.
    const blank: string[] = []
    for (const { type, input } of FIXTURES) {
      for (const [name, ctx] of REGISTERS) {
        const out = walk(renderBlockNative(input, ctx, 0), OPAQUE)
        if (out.text.trim() === '' && out.styles.length === 0 && out.opaque === 0) {
          blank.push(`${type}/${name}`)
        }
      }
    }
    // No exemptions are claimed. D51 reserves one — a src-less `video`, which
    // renders nothing by cross-surface law — but the generator's video fixture
    // HAS a src, so the corpus never exercises it and the floor holds with no
    // carve-out at all. The law itself is pinned separately below rather than
    // hidden inside an exemption nobody would ever read.
    expect(blank).toEqual([])
  })

  it('renders the status-legend from its OWN vocabulary — the input is data-free', () => {
    // `status-legend.golden.json`'s input is `{type: "status-legend"}` and
    // nothing else: the eight rows are the RENDERER's, on every surface. So a
    // text assertion against the input would be vacuous, and the only honest
    // question is whether mobile's table matches the reference's.
    const legend = FIXTURES.find((f) => f.type === 'status-legend')
    expect(legend?.input).toEqual({ type: 'status-legend' })
    for (const [, ctx] of REGISTERS) {
      const out = walk(renderBlockNative(legend?.input, ctx, 0), OPAQUE)
      for (const role of [
        'open',
        'ready',
        'in progress',
        'blocked',
        'done',
        'cancelled',
        'considering',
        'researching',
      ]) {
        expect(out.text).toContain(role)
      }
      // The two thought-state rows are the ones a stale copy drops: the TUI's
      // board still resolves 5 roles and silently loses these
      // (mob-zb-bl-tui-board-thought-lanes). Their presence here is what proves
      // mobile took the CURRENT manifest and not the stale set.
      expect(out.text).toContain('a candidate being weighed')
      expect(out.text).toContain('under active investigation')
    }
  })

  it('honours the src-less video parity law — renders NOTHING, not a card', () => {
    // react's `video` returns '' and videoRenderer returns nil for a src-less
    // block: an asset-less video is editor scaffolding. Mobile agrees. This is
    // asserted OUTSIDE the corpus loop because the fixture carries a src — so
    // the law is covered by a test rather than by an exemption in a list.
    for (const [, ctx] of REGISTERS) {
      expect(renderBlockNative({ type: 'video' }, ctx, 0)).toBeNull()
      expect(renderBlockNative({ type: 'video', src: '   ' }, ctx, 0)).toBeNull()
      // …and the same block WITH a src does paint its labeled card, so the
      // assertion above is about the missing src and not about video being
      // broken outright.
      const out = walk(renderBlockNative({ type: 'video', src: 'https://x.y/a.mp4' }, ctx, 0), OPAQUE)
      expect(out.text).toContain('Video')
    }
  })
})
