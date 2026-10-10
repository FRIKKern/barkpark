// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE UNPLACED ROADMAP (task-e8e80abb16460f44). A live-query roadmap row carries
// title/status/priority and no schedule field, so the clamp used to paint every
// lane as the same left:0%;width:100% bar. The Elixir View emitter (#19533)
// renders an explicit cannot-place state instead; this is the JS twin, using the
// same two strings (ROADMAP_UNPLACED_COPY / ROADMAP_LANE_UNPLACED_COPY, which an
// Elixir test pins against components.ex).
import { describe, it, expect } from 'vitest'
import { renderBlock } from '../src/blocks/registry'
import { ROADMAP_UNPLACED_COPY, ROADMAP_LANE_UNPLACED_COPY } from '../src/blocks/core'
import { EN } from '../src/blocks/chrome'

const FULL_BAR = 'style="left:0%;width:100%"'

describe('roadmap — cannot-place state', () => {
  it('all-unplaced: a live-query roadmap shows the notice and lists the items, with no bars', () => {
    const html = renderBlock({
      type: 'roadmap',
      snapshot: [
        { title: 'Wire the harness', status: 'ready', priority: '1' },
        { title: 'Render the board', status: 'in_progress', priority: '0' },
      ],
    }, EN)
    expect(html.startsWith(`<div class="bp-tasks bp-tasks--empty">${ROADMAP_UNPLACED_COPY}</div>`)).toBe(true)
    expect(html).not.toContain('bp-rm__bar')
    expect(html).not.toContain(FULL_BAR)
    // The items survive, through the task-list emitter.
    expect(html).toContain('<div class="bp-tasks">')
    expect(html).toContain('<span class="bp-trow__t">Wire the harness</span>')
    expect(html).toContain('<span class="bp-trow__t">Render the board</span>')
  })

  it('partial geometry: only the geometry-less lane is marked, the placed lane keeps its bar', () => {
    const html = renderBlock({
      type: 'roadmap',
      snapshot: [
        { title: 'Placed', status: 'ready', left: 10, width: 30 },
        { title: 'Unplaced', status: 'ready' },
      ],
    }, EN)
    expect(html).not.toContain(ROADMAP_UNPLACED_COPY)
    expect(html).toContain('style="left:10%;width:30%"')
    expect(html).toContain(
      `<div class="bp-rm__lane bp-rm__lane--unplaced"><span class="bp-rm__lbl">Unplaced</span><div class="bp-rm__track"><span class="bp-rm__unplaced">${ROADMAP_LANE_UNPLACED_COPY}</span></div></div>`,
    )
    expect(html.match(/bp-rm__bar /g)?.length).toBe(1)
    expect(html).not.toContain(FULL_BAR)
  })

  it('author-pct control: a fully authored roadmap is unchanged (no unplaced class, no notice)', () => {
    const html = renderBlock({
      type: 'roadmap',
      snapshot: [
        { title: 'Foundation', status: 'done', phase_row: true, left: 0, width: 40 },
        { title: 'Ship the board', status: 'in_progress', left: 40, width: 35 },
      ],
      scale: ['Q1', 'Q2'],
    }, EN)
    expect(html).not.toContain('unplaced')
    expect(html).not.toContain(ROADMAP_UNPLACED_COPY)
    expect(html).toContain('<div class="bp-rm__lane bp-rm__lane--phase"><span class="bp-rm__lbl">Foundation</span>')
    expect(html.match(/bp-rm__bar /g)?.length).toBe(2)
  })

  it('a numeric-looking STRING is not author geometry (the Elixir is_number/1 rule)', () => {
    const html = renderBlock({ type: 'roadmap', snapshot: [{ title: 'S', status: 'ready', left: '40' }] }, EN)
    expect(html).toContain(ROADMAP_UNPLACED_COPY)
  })
})
