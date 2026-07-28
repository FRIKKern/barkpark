// StreamSkeleton — the forming-block placeholder (mob-rt-s6-stream-skeleton).
//
// This suite has to work harder than "it renders", for three reasons that are
// specific to this component:
//
//   1. IT IS A COPY-PASTE MAGNET. Seven labels, six shapes, all built out of the
//      same <Bar>. A shape that silently renders its neighbour's arrangement is
//      the single most likely defect here and it is INVISIBLE to any assertion
//      that only checks "something rendered". So every kind is pinned by its
//      distinguishing structure — bar COUNT plus the measured widths/heights,
//      read back out of the tree — and the numbers asserted are the web's
//      (chat_live.ex:3859-3907), not this file's opinion.
//   2. THE VOCABULARY IS THE SERVER'S. `skeleton_label/1` returns exactly seven
//      strings and falls back to "block". An eighth label on the phone is a word
//      the server can never send, so the set is pinned EXACTLY (both directions:
//      no missing label, no extra one) rather than spot-checked.
//   3. NOTHING ELSE WOULD CATCH A LEAKED DRIVER. This is the app's first
//      Animated.loop. A loop that is never stopped keeps running after the block
//      it described has settled — one leak per turn, no crash, no red anywhere.
//      The teardown is therefore pinned directly: Animated.loop is spied, and
//      the driver it handed the component must have `.stop()` called on unmount.
//
// The last test reads the component's own SOURCE, because "no hand-typed colour
// or type size" is a property of the file, not of one render: the package's
// ESLint guard whitelists token member access on fontSize/lineHeight but says
// nothing about hex colours, so this closes the other half.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import { Animated, Text } from 'react-native'
import { act, create, type ReactTestInstance, type ReactTestRenderer } from 'react-test-renderer'

import {
  SKELETON_BAND_TEST_ID,
  SKELETON_BAR_TEST_ID,
  SKELETON_LABELS,
  SKELETON_ROW_TEST_ID,
  StreamSkeleton,
  skeletonLabel,
} from '../src/chat/StreamSkeleton'

/* ── harness ────────────────────────────────────────────────────────────────── */

type Style = Record<string, unknown>

function flatten(raw: unknown): Style {
  const parts = Array.isArray(raw) ? raw : [raw]
  return Object.assign({}, ...parts.filter(Boolean).map((p) => (typeof p === 'object' ? p : {}))) as Style
}

function mount(props: { kind: string; prose?: string }): ReactTestRenderer {
  let r!: ReactTestRenderer
  act(() => {
    r = create(<StreamSkeleton {...props} />)
  })
  return r
}

/** The dashed skeleton box for a kind — found by the testID the server's own
 * label produces, which is why finding it AT ALL is part of the proof. */
function box(r: ReactTestRenderer, label: string): ReactTestInstance {
  return r.root.findByProps({ testID: `rendering ${label}` })
}

/** HOST nodes carrying `testID` under `scope`. findAllByProps matches the
 * composite wrappers too (Animated.View is a forwardRef around a host View), so
 * a raw count would double or triple; a host node has a string `type`. */
function hosts(scope: ReactTestInstance, testID: string): ReactTestInstance[] {
  return scope
    .findAllByProps({ testID }, { deep: true })
    .filter((n) => typeof n.type === 'string')
}

function bars(scope: ReactTestInstance): Style[] {
  return hosts(scope, SKELETON_BAR_TEST_ID).map((n) => flatten(n.props.style))
}

/** The measured bars of the skeleton for `kind`. */
function shapeBars(kind: string): Style[] {
  const r = mount({ kind })
  const out = bars(box(r, skeletonLabel(kind)))
  act(() => r.unmount())
  return out
}

/** The shape's arranging container — the band. */
function shapeBand(kind: string): Style {
  const r = mount({ kind })
  const found = hosts(box(r, skeletonLabel(kind)), SKELETON_BAND_TEST_ID)
  expect(found).toHaveLength(1)
  const style = flatten(found[0]!.props.style)
  act(() => r.unmount())
  return style
}

/* ── 1. the vocabulary is the server's, exactly ─────────────────────────────── */

describe('the seven-label vocabulary mirrors skeleton_label/1', () => {
  it('is exactly the seven strings the server can return', () => {
    expect([...SKELETON_LABELS]).toEqual(['diagram', 'chart', 'stats', 'table', 'callout', 'code', 'block'])
    expect(new Set(SKELETON_LABELS).size).toBe(7)
  })

  it('maps every known kind to itself', () => {
    for (const label of SKELETON_LABELS) expect(skeletonLabel(label)).toBe(label)
  })

  it('falls back to "block" for anything else — never empty, never a throw', () => {
    for (const stray of ['', 'mermaid', 'Chart', 'sheet', 'tasks', 'undefined']) {
      expect(skeletonLabel(stray)).toBe('block')
    }
  })

  it('carries testID and accessibilityLabel "rendering LABEL" on every kind', () => {
    for (const label of SKELETON_LABELS) {
      const r = mount({ kind: label })
      const node = box(r, label)
      expect(node.props.accessibilityLabel).toBe(`rendering ${label}`)
      act(() => r.unmount())
    }
  })

  it('labels an unknown kind "block" and still draws a shape', () => {
    const r = mount({ kind: 'flux-capacitor' })
    expect(() => box(r, 'block')).not.toThrow()
    expect(bars(box(r, 'block')).length).toBeGreaterThan(0)
    // and it does NOT invent a label out of the kind it was handed
    expect(r.root.findAllByProps({ testID: 'rendering flux-capacitor' })).toHaveLength(0)
    act(() => r.unmount())
  })

  it('writes the label into visible text as "rendering LABEL…"', () => {
    const r = mount({ kind: 'chart' })
    const texts = r.root.findAllByType(Text).map((t) => JSON.stringify(t.props.children))
    expect(texts.some((t) => t.includes('rendering') && t.includes('chart'))).toBe(true)
    act(() => r.unmount())
  })
})

/* ── 2. per-kind structure — a copy-pasted shape dies here ──────────────────── */

describe('every kind has its own arrangement, ported from the web', () => {
  it('chart = 6 bars, width 22, heights 40/62/30/52/44/58, bottom-aligned in a 64 band', () => {
    const b = shapeBars('chart')
    expect(b).toHaveLength(6)
    expect(b.map((s) => s.height)).toEqual([40, 62, 30, 52, 44, 58])
    expect(b.map((s) => s.width)).toEqual([22, 22, 22, 22, 22, 22])

    const band = shapeBand('chart')
    expect(band.height).toBe(64)
    expect(band.alignItems).toBe('flex-end')
    expect(band.gap).toBe(6)
  })

  it('stats = 3 equal 52-tall tiles, gap 8', () => {
    const b = shapeBars('stats')
    expect(b).toHaveLength(3)
    expect(b.map((s) => s.height)).toEqual([52, 52, 52])
    expect(b.map((s) => s.flex)).toEqual([1, 1, 1])
    // the discriminator against chart: equal heights, no fixed width
    expect(b.every((s) => s.width === undefined)).toBe(true)
  })

  it('table = 3 rows of 3 cells, 14 tall, gap 5', () => {
    const b = shapeBars('table')
    expect(b).toHaveLength(9)
    expect(new Set(b.map((s) => s.height))).toEqual(new Set([14]))

    const r = mount({ kind: 'table' })
    const rows = hosts(box(r, 'table'), SKELETON_ROW_TEST_ID)
    expect(rows).toHaveLength(3)
    for (const row of rows) {
      expect(hosts(row, SKELETON_BAR_TEST_ID)).toHaveLength(3)
      expect(flatten(row.props.style).gap).toBe(5)
    }
    act(() => r.unmount())
  })

  it('diagram = 88x34 box, a 2-tall flex connector, 88x34 box in a 56 band', () => {
    const b = shapeBars('diagram')
    expect(b).toHaveLength(3)
    const [left, link, right] = b as [Style, Style, Style]
    expect([left.width, left.height]).toEqual([88, 34])
    expect([right.width, right.height]).toEqual([88, 34])
    expect([link.flex, link.height]).toEqual([1, 2])

    const band = shapeBand('diagram')
    expect(band.height).toBe(56)
    expect(band.gap).toBe(10)
  })

  it('callout = a 3-wide full-height spine plus lines at 40% and 85%', () => {
    const b = shapeBars('callout')
    expect(b).toHaveLength(3)
    const [spine] = b as [Style, Style, Style]
    expect(spine.width).toBe(3)
    expect(spine.alignSelf).toBe('stretch')
    expect(spine.height).toBeUndefined()
    expect(b.slice(1).map((s) => s.width)).toEqual(['40%', '85%'])
    expect(b.slice(1).map((s) => s.height)).toEqual([12, 12])
  })

  it('code, block and an unknown kind ALL take the generic 70/90/55 lines', () => {
    // The web has no dedicated code shape; that parity is deliberate.
    for (const kind of ['code', 'block', 'wormhole']) {
      const b = shapeBars(kind)
      expect({ kind, widths: b.map((s) => s.width) }).toEqual({ kind, widths: ['70%', '90%', '55%'] })
      expect({ kind, heights: b.map((s) => s.height) }).toEqual({ kind, heights: [12, 12, 12] })
    }
  })

  it('no two kinds share a shape signature', () => {
    const sig = (kind: string) => JSON.stringify(shapeBars(kind).map((s) => [s.width, s.height, s.flex]))
    const signatures = ['diagram', 'chart', 'stats', 'table', 'callout', 'block'].map(sig)
    expect(new Set(signatures).size).toBe(6)
  })

  it('the bars are never text — no Text node lives inside a shape', () => {
    for (const label of SKELETON_LABELS) {
      const r = mount({ kind: label })
      // exactly ONE Text in the whole skeleton: the "rendering …" label
      expect({ label, texts: box(r, label).findAllByType(Text) }).toEqual({
        label,
        texts: [expect.anything()],
      })
      act(() => r.unmount())
    }
  })
})

/* ── 3. prose sits ABOVE the skeleton ───────────────────────────────────────── */

describe('prose', () => {
  it('renders above the skeleton, outside the dashed box, when non-empty', () => {
    const r = mount({ kind: 'chart', prose: 'Here is the quarterly split.' })
    const texts = r.root.findAllByType(Text)
    const rendered = texts.map((t) => JSON.stringify(t.props.children))
    const proseIdx = rendered.findIndex((t) => t.includes('quarterly split'))
    const labelIdx = rendered.findIndex((t) => t.includes('rendering'))
    expect(proseIdx).toBeGreaterThanOrEqual(0)
    // ABOVE: it precedes the skeleton label in tree order …
    expect(proseIdx).toBeLessThan(labelIdx)
    // … and OUTSIDE: it is not a descendant of the dashed box.
    const inside = box(r, 'chart')
      .findAllByType(Text)
      .map((t) => JSON.stringify(t.props.children))
    expect(inside.some((t) => t.includes('quarterly split'))).toBe(false)
    act(() => r.unmount())
  })

  it('is absent when omitted, empty, or whitespace-only', () => {
    for (const prose of [undefined, '', '   \n ']) {
      const r = mount({ kind: 'table', prose })
      expect(r.root.findAllByType(Text)).toHaveLength(1) // the label alone
      act(() => r.unmount())
    }
  })
})

/* ── 4. the driver is stopped on unmount ────────────────────────────────────── */

describe('the pulse loop does not leak', () => {
  afterEach(() => {
    jest.restoreAllMocks()
  })

  function spyLoop() {
    const stop = jest.fn()
    const start = jest.fn()
    const spy = jest
      .spyOn(Animated, 'loop')
      .mockImplementation(
        () => ({ start, stop, reset: jest.fn() }) as unknown as Animated.CompositeAnimation,
      )
    return { spy, start, stop }
  }

  it('starts exactly one loop per skeleton and stops it on unmount', () => {
    const { spy, start, stop } = spyLoop()
    const r = mount({ kind: 'chart' })
    expect(spy).toHaveBeenCalledTimes(1)
    expect(start).toHaveBeenCalledTimes(1)
    expect(stop).not.toHaveBeenCalled()

    act(() => r.unmount())
    expect(stop).toHaveBeenCalledTimes(1)
  })

  it('leaves nothing running after N mount/unmount cycles — the per-turn leak', () => {
    const { spy, stop } = spyLoop()
    for (let i = 0; i < 5; i++) {
      const r = mount({ kind: 'diagram' })
      act(() => r.unmount())
    }
    expect(spy).toHaveBeenCalledTimes(5)
    expect(stop).toHaveBeenCalledTimes(5)
  })

  it('pulses the BARS and not the label — one shared driver on every bar', () => {
    // The HOST node flattens opacity to the driver's current number, so the
    // proof reads the composite Animated.View the component actually wrote.
    const r = mount({ kind: 'stats' })
    const composites = box(r, 'stats')
      .findAllByProps({ testID: SKELETON_BAR_TEST_ID }, { deep: true })
      .filter((n) => typeof n.type !== 'string')
    const driven = composites
      .map((n) => flatten(n.props.style).opacity)
      .filter((o) => o instanceof Animated.Value)
    expect(driven).toHaveLength(3)
    // ONE Animated.Value, shared — three drivers would be three leaks.
    expect(new Set(driven).size).toBe(1)
    // the label is plain text, never pulsed
    for (const t of box(r, 'stats').findAllByType(Text)) {
      expect(flatten(t.props.style).opacity).toBeUndefined()
    }
    act(() => r.unmount())
  })
})

/* ── 5. no hand-typed colour or type size in the source ─────────────────────── */

describe('every colour and type size comes from a token', () => {
  const source = readFileSync(join(__dirname, '..', 'src', 'chat', 'StreamSkeleton.tsx'), 'utf8')
  // The header comment cites registry.tsx:43-64 and the HEEx line numbers, so
  // the scan runs over CODE only — a doc line is not a rendered value.
  const code = source
    .split('\n')
    .filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l))
    .join('\n')

  it('has no hex, rgb() or hsl() colour literal', () => {
    expect(code.match(/#[0-9a-fA-F]{3,8}\b/g)).toBeNull()
    expect(code.match(/\b(?:rgba?|hsla?)\s*\(/g)).toBeNull()
  })

  it('sets no fontSize/lineHeight by hand — only the guard\'s whitelist shape', () => {
    const hits = code.match(/\b(?:fontSize|lineHeight)\s*:/g)
    expect(hits).toBeNull()
  })

  it('reaches its colours through the theme, and its type through the scale', () => {
    expect(code).toContain("from '../ui/theme'")
    expect(code).toContain("from '../ui/typography'")
    expect(code).toMatch(/\.\.\.scale\.(xs|base)/)
  })

  it('adds no dependency — imports only react, react-native and app modules', () => {
    const specifiers = [...code.matchAll(/from '([^']+)'/g)].map((m) => m[1] ?? '')
    for (const s of specifiers) {
      expect({ s, ok: s === 'react' || s === 'react-native' || s.startsWith('../') || s.startsWith('./') }).toEqual({
        s,
        ok: true,
      })
    }
  })
})
