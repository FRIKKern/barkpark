// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE DRAFT CHIP, AS A REGISTRY PREDICATE (task-0310f53709aca6de c2).
//
// PDS-D749: "a draft row must be VISIBLY LABELLED on EVERY reader that can show
// one." A task-snapshot row reaches the emitters carrying `draft: true` on a
// draft-only row and nothing on a published one (TaskResolver.row_from_task/1).
//
// This is NOT a pinned list of today's emitter names — that is how the last
// guard of this kind went stale. It enumerates REGISTERED_TYPES (the registry's
// own export) and asks each emitter one question: when handed a snapshot row,
// does it paint that row's title? If it does, it must paint the DRAFT chip in
// front of it for a draft row, and must NOT paint it for a published row. A new
// emitter that consumes snapshot rows is enrolled the moment it registers.
import { describe, it, expect } from 'vitest'
import { REGISTERED_TYPES, renderBlock } from '../src/blocks/registry'
import type { Block } from '../src/inline'
import { EN } from '../src/blocks/chrome'

const SENTINEL = 'Zq draft sentinel row'
const CHIP = '<span class="bp-draft">DRAFT</span> '

// Geometry is included so a roadmap PLACES the lane (its label is painted either
// way, but a placed lane is the ordinary path).
function row(draft: boolean): Record<string, unknown> {
  const r: Record<string, unknown> = { title: SENTINEL, status: 'ready', left: 0, width: 50 }
  if (draft) r.draft = true
  return r
}

/** The predicate. Returns every registered type that paints a snapshot row's
 * title without honouring the draft contract. Takes the registry as arguments
 * so the arms below can prove it reds and stays quiet on a modified registry. */
export function draftContractViolations(
  types: readonly string[],
  render: (b: Block) => string,
): string[] {
  const bad: string[] = []
  for (const type of types) {
    const drafted = render({ type, snapshot: [row(true)] } as Block)
    if (!drafted.includes(SENTINEL)) continue // does not paint snapshot rows
    const published = render({ type, snapshot: [row(false)] } as Block)
    const chipsDraft = drafted.includes(CHIP + SENTINEL)
    const chipsPublished = published.includes('bp-draft')
    if (!chipsDraft || chipsPublished) bad.push(type)
  }
  return bad
}

describe('draft chip — registry predicate', () => {
  it('every registered emitter that paints a snapshot row honours the draft contract', () => {
    expect(draftContractViolations(REGISTERED_TYPES, (b: Block) => renderBlock(b, EN))).toEqual([])
  })

  it('the predicate is not vacuous: it enrols the task-row emitters on its own', () => {
    const consumers = REGISTERED_TYPES.filter((type) =>
      renderBlock({ type, snapshot: [row(true)] } as Block, EN).includes(SENTINEL),
    ).sort()
    // Not a pin of the list (that is the predicate's job) — a floor, so a
    // refactor that stops painting snapshot titles cannot make it pass empty.
    expect(consumers).toEqual(expect.arrayContaining(['roadmap', 'task-board', 'tasks']))
  })

  it('ARM 1 — REDS when the chip is reverted (renderer with the chip stripped)', () => {
    const reverted = (b: Block) => renderBlock(b, EN).split(CHIP).join('')
    const bad = draftContractViolations(REGISTERED_TYPES, reverted)
    expect(bad).toEqual(expect.arrayContaining(['roadmap', 'task-board', 'tasks', 'task-list']))
  })

  // The two arms below measure the DELTA an edit makes against the real
  // registry's own verdict, so each proves one thing about the predicate and
  // does not re-assert the first case.
  const base = () => draftContractViolations(REGISTERED_TYPES, (b: Block) => renderBlock(b, EN))

  it('ARM 1b — REDS on a NEW emitter that paints snapshot titles without the chip', () => {
    const types = [...REGISTERED_TYPES, 'x-rogue-board']
    const render = (b: Block) => {
      if (b.type !== 'x-rogue-board') return renderBlock(b, EN)
      const rows = (b.snapshot as Array<Record<string, unknown>>) ?? []
      return rows.map((r) => `<i>${String(r.title)}</i>`).join('')
    }
    const added = draftContractViolations(types, render).filter((t) => !base().includes(t))
    expect(added).toEqual(['x-rogue-board'])
  })

  it('ARM 2 — stays QUIET on an unrelated registry edit', () => {
    const types = [...REGISTERED_TYPES, 'x-unrelated-callout']
    const render = (b: Block) =>
      b.type === 'x-unrelated-callout' ? '<div class="bp-callout">static</div>' : renderBlock(b, EN)
    expect(draftContractViolations(types, render)).toEqual(base())
  })

  it('a chip painted on a PUBLISHED row is a violation too', () => {
    const always = (b: Block) => {
      const html = renderBlock(b, EN)
      return html.includes(CHIP) ? html : html.split(SENTINEL).join(CHIP + SENTINEL)
    }
    expect(draftContractViolations(REGISTERED_TYPES, always)).toEqual(
      expect.arrayContaining(['task-board']),
    )
  })
})
