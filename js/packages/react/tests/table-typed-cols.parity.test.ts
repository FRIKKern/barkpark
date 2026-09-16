// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the table `cols` contract (task-500de02cedf113ff).
//
// THREE engines render typed table columns and they read ONE contract file —
// `api/test/support/fixtures/table-col-types.json`:
//
//   Go      internal/pdrender/richblocks.go   parseColTypes / colRightAlign /
//           deltaCell / sparkCell — tested by richblocks_col_contract_test.go
//   Elixir  api/lib/barkpark/portable_doc/render/compose.ex (+ walk.ex table/3)
//           tested by .../render/table_typed_cols_test.exs
//   JS      js/packages/react/src/blocks/table.ts — tested HERE
//
// The React leg was the one that LAGGED: table.ts emitted a bare
// `<td class="bp-table__td">` for every cell, no matter what `cols` said.
//
// MIRROR RULE: the type set, the right-aligned subset and the delta glyphs are
// READ from that fixture below — never re-typed here. A hand-copied expected
// list is a tautology: it agrees with itself while the engines drift.
//
// DRIFT PROOF (both directions):
//   • change `delta_glyphs.up` in the fixture  → the delta cases red HERE
//     (and in the Elixir suite), because the expectation is the fixture's value.
//   • remove the alignment class / the glyph / the sparkline from table.ts
//     → the alignment, delta and spark cases red respectively, each naming which.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { renderPortableDocument, type Block } from '../src/PortableDoc'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/table-col-types.json',
  import.meta.url,
)

const contract = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as {
  types: string[]
  right_aligned: string[]
  delta_glyphs: Record<'up' | 'down' | 'flat', string>
}

const cols = (types: string[]) => types.map((type) => ({ type }))

function article(block: Record<string, unknown>): string {
  return renderPortableDocument([block as unknown as Block])
}

describe('table `cols` contract (shared fixture)', () => {
  it('reads the one contract file the other two engines read', () => {
    // A guard on the READ itself: an empty/renamed fixture must not make every
    // for-loop below vacuously green.
    expect(contract.types).toContain('text')
    expect(contract.right_aligned.length).toBeGreaterThan(0)
    expect(Object.keys(contract.delta_glyphs).sort()).toEqual(['down', 'flat', 'up'])
  })

  // ── alignment ─────────────────────────────────────────────────────────────
  it('right-aligns exactly the fixture’s right_aligned types, and nothing else', () => {
    for (const type of contract.types) {
      const html = article({ type: 'table', cols: cols([type]), rows: [['1']] })
      const aligned = html.includes('class="bp-table__td bp-table__td--num"')
      expect(aligned, `${type} column alignment`).toBe(contract.right_aligned.includes(type))
    }
  })

  it('right-aligns the HEADER of a right-aligned column too, so the label sits over it', () => {
    const type = contract.right_aligned[0]
    const html = article({
      type: 'table',
      head: ['Label', 'Count'],
      cols: cols(['text', type]),
      rows: [['Errors', '1204']],
    })
    expect(html).toContain('<th class="bp-table__th">')
    expect(html).toContain('<th class="bp-table__th bp-table__th--num">')
  })

  it('leaves a num column’s BODY on the legacy text render (alignment only)', () => {
    const html = article({ type: 'table', cols: cols(['num']), rows: [['1204']] })
    expect(html).toContain('<td class="bp-table__td bp-table__td--num"><span>1204</span></td>')
    expect(html).not.toContain('<svg')
    for (const glyph of Object.values(contract.delta_glyphs)) {
      if (glyph !== '-') expect(html).not.toContain(glyph)
    }
  })

  // ── delta ─────────────────────────────────────────────────────────────────
  it('prefixes a delta cell with the fixture’s direction glyph and drops the sign', () => {
    const g = contract.delta_glyphs
    const html = article({
      type: 'table',
      cols: cols(['text', 'delta']),
      rows: [
        ['up', 4.2],
        ['down', -4.2],
        ['flat', 0],
      ],
    })
    const cell = (body: string) =>
      `<td class="bp-table__td bp-table__td--num"><span>${body}</span></td>`
    expect(html, 'delta up glyph').toContain(cell(`${g.up} 4.2`))
    expect(html, 'delta down glyph — magnitude loses its sign').toContain(cell(`${g.down} 4.2`))
    expect(html, 'delta flat glyph').toContain(cell(`${g.flat} 0`))
    // the glyph carries the direction with ZERO colour
    expect(html).not.toContain('color:')
  })

  it('falls back to the legacy body for a delta cell that is not a number', () => {
    const html = article({ type: 'table', cols: cols(['delta']), rows: [['n/a']] })
    expect(html).toContain('<td class="bp-table__td bp-table__td--num"><span>n/a</span></td>')
    expect(html).not.toContain(contract.delta_glyphs.up)
    expect(html).not.toContain(contract.delta_glyphs.down)
  })

  // ── spark ─────────────────────────────────────────────────────────────────
  it('renders a spark series as ONE inline sparkline SVG, not literal spans', () => {
    expect(contract.types, 'spark is part of the contract type set').toContain('spark')
    const html = article({
      type: 'table',
      cols: cols(['text', 'spark']),
      rows: [['latency', [1, 2, 3, 4]]],
    })
    expect(html).toContain('<td class="bp-table__td bp-table__td--spark"><svg class="bp-table__spark"')
    // the geometry is the Elixir/Go primitive's, pinned by the Elixir suite
    expect(html).toContain('<polyline points="0,24 40,16.7 80,9.3 120,2"/>')
    // the failure this replaces: four numbers dumped as four literal spans
    expect(html).not.toContain('<span>1</span>')
    expect(html).not.toContain('<span>4</span>')
  })

  it('reuses the stat sparkline primitive — same geometry, its own class', () => {
    const series = [1, 2, 3, 4]
    const table = article({ type: 'table', cols: cols(['spark']), rows: [[series]] })
    const stat = article({ type: 'stat', value: '1', spark: series })
    const points = /<polyline points="([^"]+)"\/>/.exec(table)?.[1]
    expect(points).toBeTruthy()
    expect(stat).toContain(`<polyline points="${points}"/>`)
    expect(stat).toContain('<svg class="bp-stat__spark"')
  })

  it('falls back to the legacy body for a spark cell with no coercible numbers', () => {
    const html = article({ type: 'table', cols: cols(['spark']), rows: [['not a series']] })
    expect(html).toContain(
      '<td class="bp-table__td bp-table__td--spark"><span>not a series</span></td>',
    )
    expect(html).not.toContain('<svg')
  })

  // ── cols ABSENT / unknown / out-of-range ⇒ the legacy bytes ────────────────
  it('renders a cols-ABSENT table byte-identically to before the spec existed', () => {
    const rows = [
      ['Uptime', '99.9%'],
      ['Errors', '3'],
    ]
    expect(article({ type: 'table', head: ['Metric', 'Value'], rows })).toBe(
      '<table role="presentation" class="bp-table">' +
        '<thead><tr><th class="bp-table__th"><span>Metric</span></th>' +
        '<th class="bp-table__th"><span>Value</span></th></tr></thead><tbody>' +
        '<tr><td class="bp-table__td"><span>Uptime</span></td>' +
        '<td class="bp-table__td"><span>99.9%</span></td></tr>' +
        '<tr><td class="bp-table__td"><span>Errors</span></td>' +
        '<td class="bp-table__td"><span>3</span></td></tr></tbody></table>',
    )
  })

  it('degrades an UNKNOWN column type, and any index past `cols`, to text', () => {
    expect(contract.types, 'the fixture type set is CLOSED — "wat" is not in it').not.toContain(
      'wat',
    )
    const unknown = article({ type: 'table', cols: cols(['wat']), rows: [['x']] })
    expect(unknown).toContain('<td class="bp-table__td"><span>x</span></td>')

    const short = article({ type: 'table', cols: cols(['num']), rows: [['1', '2']] })
    expect(short).toContain('<td class="bp-table__td bp-table__td--num"><span>1</span></td>')
    expect(short).toContain('<td class="bp-table__td"><span>2</span></td>')
  })
})
