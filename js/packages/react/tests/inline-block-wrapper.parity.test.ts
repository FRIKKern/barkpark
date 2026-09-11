// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The JS leg of the BLOCK-WRAPPER-IN-AN-INLINE-ARRAY parity lock
// (task-3fd604e7c89d6150, sibling of task-9cab47ce042ccdfb / PR #15701).
//
// Three engines walk a run of inline nodes and they all read ONE fixture file —
// `api/test/support/fixtures/inline-block-wrapper.json`:
//
//   Elixir  api/lib/barkpark/portable_doc/render/inline.ex  `unwrap_block_wrappers/1`
//           tested by api/test/barkpark/portable_doc/render/inline_block_wrapper_parity_test.exs
//   JS      js/packages/react/src/inline.tsx                `unwrapBlockWrappers`
//           tested HERE
//   Go      internal/pdrender/inline.go                     `unwrapBlockWrappers`
//           tested by internal/pdrender/inline_block_wrapper_parity_test.go
//
// ONE file, not three generated mirrors — a mirror set drifts the moment one
// side is regenerated and the others are not, which is exactly the bug this row
// exists to close: the Elixir engine shipped the unwrap on 2026-09-03 while this
// SDK and the Go TUI reader stayed blank on the same published papers.
//
// DRIFT PROOF: drop the `unwrapBlockWrappers` call from `renderInlines` in
// src/inline.tsx and the seven wrapper-shaped cases red HERE while the Elixir
// and Go legs stay green.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { renderInlines, unwrapBlockWrappers } from '../src/inline'

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/inline-block-wrapper.json',
  import.meta.url,
)

interface Case {
  name: string
  nodes: unknown[]
  text: string
}

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as { cases: Case[] }

/** The VISIBLE text of the emitted HTML. The Go leg strips ANSI and the Elixir
 * leg folds the Pd tree, so all three compare the SAME string. Every fixture
 * case is deliberately free of HTML-significant characters so tag-stripping is
 * lossless here. */
const visible = (html: string) => html.replace(/<[^>]*>/g, '')

describe('a block-level node nested in an inline array (shared fixture)', () => {
  it('carries every recorded case (a shrunken fixture cannot pass vacuously)', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(13)
  })

  for (const c of fixture.cases) {
    it(`renderInlines: ${c.name}`, () => {
      expect(visible(renderInlines(c.nodes))).toBe(c.text)
    })
  }

  it('at least seven cases DEPEND on the unwrap (the mutation control)', () => {
    // The pre-fix walk, reproduced here: without the unwrap the wrapper-shaped
    // cases must lose their prose. If this count drops, the assertions above
    // were passing for some other reason.
    const depends = fixture.cases.filter((c) => {
      if (c.text === '') return false
      const unwrapped = unwrapBlockWrappers(c.nodes)
      return unwrapped !== c.nodes
    })
    expect(depends.length).toBeGreaterThanOrEqual(7)
  })
})

describe('the unwrap is bounded exactly as the Elixir original', () => {
  it('does not fire on an EMPTY content list', () => {
    const nodes = [{ type: 'paragraph', content: [] }]
    expect(unwrapBlockWrappers(nodes)).toBe(nodes)
  })

  it('does not fire when content is not a list', () => {
    const nodes = [{ type: 'paragraph', content: 'not a list' }]
    expect(unwrapBlockWrappers(nodes)).toBe(nodes)
  })

  it('does not fire on a children-keyed inline node', () => {
    const nodes = [{ type: 'strong', children: [{ type: 'text', value: 'x' }] }]
    expect(unwrapBlockWrappers(nodes)).toBe(nodes)
  })

  it('unwraps ONE level only — the inner wrapper survives wrapped', () => {
    const inner = { type: 'paragraph', content: [{ type: 'text', value: 'deep' }] }
    const out = unwrapBlockWrappers([{ type: 'paragraph', content: [inner] }])
    expect(out).toEqual([inner])
  })

  it('leaves a MARK node’s own children alone', () => {
    // The run walk must not leak into renderInlineChildren: a wrapper nested
    // under a mark stays blank in all three engines until a row rules otherwise.
    const nodes = [
      {
        type: 'strong',
        children: [{ type: 'paragraph', content: [{ type: 'text', value: 'under a mark' }] }],
      },
    ]
    expect(visible(renderInlines(nodes))).toBe('')
  })
})
