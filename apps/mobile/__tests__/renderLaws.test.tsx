// FOUR RENDER LAWS, pinned where they can actually fail (mob-lm-s4, charter
// D74/D75). Each of these was a rule the code KNEW and the suite did not: the
// renderer happened to obey it, so deleting the rule cost nothing. That is the
// same failure mode this epic's law names on the app side — a claim nobody
// reads back — applied to the renderers themselves.
//
//   1. THE STAT BAR (react blocks/dataviz.ts statHtml is canonical, Go stat.go
//      agrees): the track exists whenever max > 0 REGARDLESS of value, and the
//      fill is a strict numeric parse of value else 0, clamped 0..1. Mobile
//      dropped the track at value 0, had no LOWER clamp (a latent negative
//      width, armed the moment value is read through a wider parse), and read
//      pre-formatted display strings leniently ("1.24M" painted 62%).
//   2. LEGEND_ROLES as an ALLOWLIST, asserted ordered-equal to
//      design/status-manifest.json. apps/mobile appears NOWHERE in
//      scripts/status-manifest-check.sh (only react's inline.tsx and web's
//      component-projections.ts), so mobile's hand-copied ladder has had NO
//      drift gate at all. This is that gate.
//   3. DEGRADE_ONLY DERIVED from a marker on the renderers, set-equal in both
//      directions — a third degrade card cannot register silently.
//   4. seriesColors pairwise-distinct with a stable prefix — the assertable
//      half of D74. The apparatus-colour defect is pinned as TODAY'S behaviour
//      here, deliberately, because D74 cut the colour choice.
//
// Its own file by the D49 territory law.
import type { ReactElement, ReactNode } from 'react'

import {
  BLOCK_RENDERERS,
  DEGRADE_ONLY,
  isDegradeCard,
  renderBlockNative,
  type BlockCtx,
} from '../src/papers/portabledoc/blocks'
import { LEGEND_ROLES, STATUS_ROLES } from '../src/papers/portabledoc/blocks/core-doc'
import { seriesColors } from '../src/papers/portabledoc/blocks/dataviz'
import { dark, light, type Theme } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const paper: BlockCtx = { theme: light }

/* ── the walker (the datavizNatives harness, styles-only) ──────────────────── */

type Styles = Record<string, unknown>[]

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function walkNode(node: ReactNode, acc: Styles): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') return
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (!isElement(node)) return
  const props = node.props as Record<string, unknown>
  const raw = props.style
  if (raw !== undefined) {
    const parts = Array.isArray(raw) ? raw : [raw]
    acc.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
  }
  walkNode(props.children as ReactNode, acc)
}

function styles(block: unknown, ctx: BlockCtx = paper): Styles {
  const acc: Styles = []
  walkNode(renderBlockNative(block, ctx, 0), acc)
  return acc
}

/** The 4pt accent FILL inside the stat track (the track itself is
 * border-coloured, so this picks out exactly the painted widths). */
function barWidths(block: unknown): unknown[] {
  return styles(block)
    .filter((s) => s.height === 4 && s.backgroundColor === light.accent)
    .map((s) => s.width)
}

/** The 4pt border-coloured TRACK — present iff the bar exists at all. */
function trackCount(block: unknown): number {
  return styles(block).filter((s) => s.height === 4 && s.backgroundColor === light.border).length
}

/* ── 1. the stat bar ───────────────────────────────────────────────────────── */

describe('law 1 — the stat bar exists on max, and its width is a CLAMPED strict ratio', () => {
  // Each row names the mutant it kills, so a future edit that "simplifies" the
  // expression has to argue with a specific consequence rather than a number.
  const cases: { name: string; value: unknown; max: unknown; width: string; mutant: string }[] = [
    {
      name: 'a NEGATIVE value floors at zero instead of painting a negative width',
      value: '-5',
      max: '10',
      width: '0%',
      mutant: 'drop the lower clamp → width:"-50%", a View that paints nothing and lies about why',
    },
    {
      name: 'a ZERO value keeps the track and paints an empty bar (the react law)',
      value: '0',
      max: '10',
      width: '0%',
      mutant: 'gate the bar on a positive value again → the whole track disappears',
    },
    {
      name: 'half of max is half a bar',
      value: '5',
      max: '10',
      width: '50%',
      mutant: 'any denominator swap',
    },
    {
      name: 'TWICE max saturates at full instead of overflowing the track',
      value: '20',
      max: '10',
      width: '100%',
      mutant: 'drop the upper clamp → width:"200%"',
    },
    {
      name: 'a PRE-FORMATTED display value is not a quantity — "1.24M" is 0%, matching react',
      value: '1.24M',
      max: '2',
      width: '0%',
      mutant: 'read value with parseFloat again → 1.24/2 = 62%, a bar invented from a label',
    },
  ]

  for (const c of cases) {
    it(c.name, () => {
      const block = { type: 'stat', value: c.value, max: c.max, label: 'x' }
      expect(trackCount(block)).toBe(1)
      expect(barWidths(block)).toEqual([c.width])
    })
  }

  it('numeric values obey the same law as their string twins', () => {
    expect(barWidths({ type: 'stat', value: 0, max: 10 })).toEqual(['0%'])
    expect(barWidths({ type: 'stat', value: -5, max: 10 })).toEqual(['0%'])
    expect(barWidths({ type: 'stat', value: 5, max: 10 })).toEqual(['50%'])
  })

  it('NO max means no track at all — the bar is opt-in by data, never a fake 0%', () => {
    for (const max of [undefined, '', '0', 0, -3, 'lots']) {
      const block = max === undefined ? { type: 'stat', value: '7' } : { type: 'stat', value: '7', max }
      expect(trackCount(block)).toBe(0)
      expect(barWidths(block)).toEqual([])
    }
  })

  it('an empty value still renders NOTHING — the card needs a number to be about', () => {
    expect(renderBlockNative({ type: 'stat', value: '', max: '10' }, paper, 0)).toBeNull()
  })

  it('model.ts num() is UNCHANGED — the fix is local to the stat renderer', () => {
    // num()'s above-zero law is correct for `max` (a zero max has no bar to
    // denominate) and for table cell spans. Rewriting it would have moved those
    // callers too, so the strictness lives at the stat call site instead. This
    // pins the boundary: num still refuses zero and negatives.
    const { num } = jest.requireActual<typeof import('../src/papers/portabledoc/model')>(
      '../src/papers/portabledoc/model',
    )
    expect(num('0')).toBeUndefined()
    expect(num(0)).toBeUndefined()
    expect(num('-5')).toBeUndefined()
    expect(num(-5)).toBeUndefined()
    expect(num('10')).toBe(10)
  })
})

/* ── 2. the legend allowlist, gated against the manifest ───────────────────── */

interface ManifestRole {
  role: string
  glyph: string
  spinner: boolean
  label: string
  meaning: string
}

function manifestRoles(): ManifestRole[] {
  const fs = jest.requireActual<typeof import('node:fs')>('node:fs')
  const path = jest.requireActual<typeof import('node:path')>('node:path')
  const raw = fs.readFileSync(
    path.join(__dirname, '..', '..', '..', 'design', 'status-manifest.json'),
    'utf8',
  )
  return (JSON.parse(raw) as { roles: ManifestRole[] }).roles
}

// The ONE sanctioned glyph divergence, exempted BY NAME rather than by a
// tolerant comparison. The manifest gives `progress` glyph:"" + spinner:true
// because the web animates Braille frames from a CSS ::before. RN has no such
// hook, so mobile paints the STATIC frame it already ships for in_progress
// everywhere else. Realizing a spinner as a static frame is the honest native
// reading; a BLANK glyph on a phone would be a hole in the legend.
const GLYPH_EXEMPT: Record<string, string> = { progress: '◐' }

describe('law 2 — LEGEND_ROLES is an ALLOWLIST, ordered-equal to the status manifest', () => {
  it('names exactly the manifest ladder, in the manifest ORDER, with unknown held out', () => {
    expect(LEGEND_ROLES.map((r) => r.role)).toEqual(manifestRoles().map((r) => r.role))
    expect(LEGEND_ROLES.map((r) => r.role)).not.toContain('unknown')
  })

  it('every legend row carries the manifest label, spinner flag and glyph', () => {
    const manifest = manifestRoles()
    LEGEND_ROLES.forEach((row, i) => {
      const want = manifest[i]!
      expect({ role: row.role, label: row.label, spinner: row.spinner }).toEqual({
        role: want.role,
        label: want.label,
        spinner: want.spinner,
      })
      const exempt = GLYPH_EXEMPT[row.role]
      if (exempt === undefined) {
        expect(`${row.role}:${row.glyph}`).toBe(`${want.role}:${want.glyph}`)
      } else {
        // The exemption is NARROW: it only licenses a static frame standing in
        // for a CSS-animated blank. If the manifest ever ships a real glyph for
        // this role, or drops the spinner flag, this reds and the exemption
        // must be re-argued rather than silently widened.
        expect({ manifestGlyph: want.glyph, spinner: want.spinner }).toEqual({
          manifestGlyph: '',
          spinner: true,
        })
        expect(row.glyph).toBe(exempt)
      }
    })
  })

  it('unknown is the SINGLE extra mobile resolves beyond the manifest', () => {
    const manifest = new Set(manifestRoles().map((r) => r.role))
    const extras = STATUS_ROLES.map((r) => r.role).filter((r) => !manifest.has(r))
    // A tenth hand-added role would land here — and under the old blocklist it
    // would have walked straight into the cross-surface legend key instead.
    expect(extras).toEqual(['unknown'])
    expect(STATUS_ROLES).toHaveLength(LEGEND_ROLES.length + 1)
  })
})

/* ── 3. DEGRADE_ONLY, derived ──────────────────────────────────────────────── */

describe('law 3 — DEGRADE_ONLY is DERIVED from a marker on the registered renderers', () => {
  it('still names exactly the two degrade cards, and each one IS registered', () => {
    expect([...DEGRADE_ONLY].sort()).toEqual(['asciicast', 'video'])
    for (const type of DEGRADE_ONLY) expect(BLOCK_RENDERERS[type]).toBeDefined()
  })

  it('set-equality holds in BOTH directions across the whole register', () => {
    // → : nothing in the set is unmarked (the set cannot name a type whose
    //     renderer is an ordinary render — that would be a stale literal).
    // ← : nothing marked is outside the set, so a THIRD degrade card cannot
    //     register silently and quietly stop being subtracted at turn level.
    for (const [type, render] of Object.entries(BLOCK_RENDERERS)) {
      expect(`${type}:${String(isDegradeCard(render))}`).toBe(`${type}:${String(DEGRADE_ONLY.has(type))}`)
    }
    const marked = Object.entries(BLOCK_RENDERERS)
      .filter(([, r]) => isDegradeCard(r))
      .map(([t]) => t)
    expect(marked.sort()).toEqual([...DEGRADE_ONLY].sort())
  })

  it('an UNMARKED renderer is not a degrade card — the marker is opt-in, never a default', () => {
    // The non-vacuity leg: if isDegradeCard answered true for everything (or
    // for nothing), the direction test above would still pass shape-wise on one
    // side. These two pin the discriminator itself.
    expect(isDegradeCard(BLOCK_RENDERERS.paragraph)).toBe(false)
    expect(isDegradeCard(BLOCK_RENDERERS.image)).toBe(false)
    expect(isDegradeCard(undefined)).toBe(false)
    expect(isDegradeCard(BLOCK_RENDERERS.video)).toBe(true)
  })
})

/* ── 4. seriesColors ───────────────────────────────────────────────────────── */

describe('law 4 — seriesColors is pairwise-distinct with a stable prefix (D74)', () => {
  // D74(ii), recorded so nobody may claim this fixed a rendering bug: the chart
  // renderer slices `series` to FOUR before asking for colours, so n>4 is
  // UNREACHABLE in production. Those rows are a defensive pin, nothing more.
  const REACHABLE_MAX = 4

  it('the chart really does slice to four — the unreachability above is checked, not asserted by hand', () => {
    const fs = jest.requireActual<typeof import('node:fs')>('node:fs')
    const path = jest.requireActual<typeof import('node:path')>('node:path')
    const src = fs.readFileSync(
      path.join(__dirname, '..', 'src', 'papers', 'portabledoc', 'blocks', 'dataviz.tsx'),
      'utf8',
    )
    expect(src).toContain(`.slice(0, ${REACHABLE_MAX})`)
  })

  it('never paints two series the same colour, n=1..8, in BOTH palettes', () => {
    for (const theme of [light, dark] as Theme[]) {
      for (let n = 1; n <= 8; n++) {
        const out = seriesColors(theme, n)
        expect(out).toHaveLength(n)
        expect(`n=${n}: ${new Set(out).size}`).toBe(`n=${n}: ${n}`)
      }
    }
  })

  it('is a STABLE PREFIX — adding a series never recolours the ones already drawn', () => {
    for (const theme of [light, dark] as Theme[]) {
      for (let n = 1; n < 8; n++) {
        expect(seriesColors(theme, n + 1).slice(0, n)).toEqual(seriesColors(theme, n))
      }
    }
  })

  it('invents no colour — every entry is a token theme.ts actually ships', () => {
    for (const theme of [light, dark] as Theme[]) {
      const owned = new Set(Object.values(theme).filter((v) => typeof v === 'string'))
      for (const c of seriesColors(theme, 8)) expect(owned.has(c)).toBe(true)
    }
  })

  it('PINS TODAY’S DEFECT: series 2 wears theme.textMuted — the chart’s own axis colour', () => {
    // NOT an endorsement. theme.success is byte-identical to theme.accent in
    // both palettes, so series 2 falls back to textMuted, which is also the
    // tick and baseline ink — a data series wearing the apparatus colour, and
    // it paints at n=2. Closing it needs a fifth theme token chosen by eye;
    // charter D74 CUT that choice for want of a visual reviewer and ruled the
    // defect be pinned VISIBLY rather than hidden behind an invented hex.
    // When a fifth token lands, THIS test is the row that must be rewritten —
    // which is exactly the point of pinning it.
    for (const theme of [light, dark] as Theme[]) {
      expect(theme.success).toBe(theme.accent)
      expect(seriesColors(theme, 2)).toEqual([theme.accent, theme.textMuted])
      expect(seriesColors(theme, 2)[1]).toBe(theme.textMuted)
    }
  })

  it('the first FOUR — the only ones a chart can reach — are byte-unchanged', () => {
    for (const theme of [light, dark] as Theme[]) {
      expect(seriesColors(theme, REACHABLE_MAX)).toEqual([
        theme.accent,
        theme.textMuted,
        theme.warn,
        theme.danger,
      ])
    }
  })
})
