// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// chat-tool-diff fold budget is DRAWABLE-ONLY (charter D40) — the react leg of
// the four-surface reconcile. The 20-line budget counts diff ROWS: a `gap`
// hunk separator never spends budget (it rides free between drawn hunks) and
// never stays in the summary once the budget is spent (a gap at/past the fold
// belongs to the `<details>` tail it separates). The "+N more lines" footnote
// counts undisplayed DRAWABLE rows only. The adjudicating geometry mirrors the
// generator's `multi_edit_budget_diff` golden variant: 3 all-added hunks of 8
// lines — 24 drawable + 2 gaps, both gaps inside the first 20 raw elements —
// so a raw-element budget would honestly claim "+6 more lines" where the
// ratified reading claims "+4". Word presence is blind to the number; the
// literal footnote is what reds the non-ratified reading.

import { describe, it, expect } from 'vitest'
import { chatEmitters } from '../src/blocks/chat'

const emitToolDiff = chatEmitters['chat-tool-diff']!

const GAP_ROW_STYLE = 'border-top: 1px solid var(--border-muted)'

function hunk(prefix: string, n: number): { old_string: string; new_string: string } {
  return {
    old_string: '',
    new_string: Array.from({ length: n }, (_, i) => `${prefix}${i + 1}`).join('\n'),
  }
}

function splitAtSummary(html: string): { summary: string; tail: string } {
  const idx = html.indexOf('</summary>')
  expect(idx).toBeGreaterThan(-1)
  return { summary: html.slice(0, idx), tail: html.slice(idx) }
}

describe('chat-tool-diff fold — drawable-only budget (charter D40)', () => {
  it('folds the adjudicating 24-drawable / 2-gap multi-edit at +4, never the raw +6', () => {
    const html = emitToolDiff({
      type: 'chat-tool-diff',
      input: {
        file_path: 'lib/barkpark/budget.ex',
        edits: [hunk('reactalpha', 8), hunk('reactbravo', 8), hunk('reactcharlie', 8)],
      },
    })

    expect(html).toContain('… +4 more lines')
    expect(html).not.toContain('+6 more lines')

    // Gaps between DRAWN hunks ride free in the summary; the 20th drawable row
    // (reactcharlie4) is the last one above the fold, the 21st opens the tail.
    const { summary, tail } = splitAtSummary(html)
    expect(summary.split(GAP_ROW_STYLE).length - 1).toBe(2)
    expect(summary).toContain('reactcharlie4')
    expect(summary).not.toContain('reactcharlie5')
    expect(tail).toContain('reactcharlie5')
    expect(tail).toContain('reactcharlie8')
  })

  it('a gap AT the fold belongs to the tail it separates — never the summary', () => {
    // 20-line hunk, then a 4-line hunk: the gap lands exactly when the budget
    // is spent, so it folds with its hunk instead of dangling as chrome.
    const html = emitToolDiff({
      type: 'chat-tool-diff',
      input: {
        file_path: 'lib/barkpark/edge.ex',
        edits: [hunk('edgehead', 20), hunk('edgetail', 4)],
      },
    })

    expect(html).toContain('… +4 more lines')
    const { summary, tail } = splitAtSummary(html)
    expect(summary).not.toContain(GAP_ROW_STYLE)
    expect(tail).toContain(GAP_ROW_STYLE)
    expect(summary).toContain('edgehead20')
    expect(tail).toContain('edgetail1')
  })

  it('a diff of exactly 20 drawable rows + a mid gap claims no overflow', () => {
    const html = emitToolDiff({
      type: 'chat-tool-diff',
      input: {
        file_path: 'lib/barkpark/flat.ex',
        edits: [hunk('flata', 10), hunk('flatb', 10)],
      },
    })

    expect(html).not.toContain('more lines')
    expect(html).not.toContain('<details>')
    expect(html).toContain('flatb10')
    expect(html).toContain(GAP_ROW_STYLE)
  })
})
