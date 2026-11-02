// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect } from 'vitest'
import { chatEmitters } from '../src/blocks/chat'
import { EN } from '../src/blocks/chrome'

const emitToolDiff = chatEmitters['chat-tool-diff']!

const text = 'c\n'.repeat(1500)

function counts(edits: { old_string: string; new_string: string }[]): string {
  const html = emitToolDiff({ type: 'chat-tool-diff', input: { file_path: 'f', edits } }, EN)
  return html.match(/\+\d+<\/span> <span style="color: var\(--danger\);">−\d+/)![0]
}

describe('chat-tool-diff multi-edit cell budget', () => {
  it('shares one budget: an edit past it shows the plain before and after', () => {
    expect(counts([{ old_string: text, new_string: text }, { old_string: text, new_string: text }])).toBe(
      '+1500</span> <span style="color: var(--danger);">−1500',
    )
  })

  it('edits within the budget each get the line diff', () => {
    expect(counts([{ old_string: text, new_string: text }])).toBe('+0</span> <span style="color: var(--danger);">−0')
  })
})
