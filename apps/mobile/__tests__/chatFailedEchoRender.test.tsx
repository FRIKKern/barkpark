// THE RENDER ARM of "an unconfirmed send must not paint as delivered"
// (mob-lm-s3, criterion 1).
//
// The reducer half is proven in chatSendTruth.test.ts: a rejected POST comes
// back through `sendFailed` and marks the echo. That is the MODEL. This file
// answers the only question a user can ask — does the bubble on screen still
// look like a delivered message? — because a `failed` flag nothing paints is
// the same defect wearing a boolean.
//
// Asserted as RELATIONSHIPS, never as hexes: the failed bubble must not carry
// the delivered fill, it must carry a border the delivered one does not, its
// words must survive intact, and it must say "not sent" in TEXT (colour alone
// is not a message) and to a screen reader. A theme retune keeps all of that
// true; collapsing the two paints into one reds every line.
import type { ReactNode } from 'react'
import { isValidElement } from 'react'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

import {
  TranscriptRow,
  chatBlockCtx,
  localRows,
  type Row,
  type RowCtx,
  type TranscriptRowProps,
} from '../src/screens/ChatSessionScreen'
import { light as theme } from '../src/ui/theme'

interface Walk {
  text: string
  styles: Record<string, unknown>[]
  labels: string[]
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (!isValidElement(node)) return
  const p = node.props as Record<string, unknown>
  if (typeof p.accessibilityLabel === 'string') acc.labels.push(p.accessibilityLabel)
  if (p.style !== undefined) {
    const parts = Array.isArray(p.style) ? p.style : [p.style]
    acc.styles.push(Object.assign({}, ...parts.filter((x) => !!x)) as Record<string, unknown>)
  }
  walkNode(p.children as ReactNode, acc)
}

function walk(node: ReactNode): Walk {
  const acc: Walk = { text: '', styles: [], labels: [] }
  walkNode(node, acc)
  return acc
}

const ctx: RowCtx = {
  theme,
  blockCtx: chatBlockCtx(theme),
  inFlight: {},
  onAnswer: () => {},
  onToggleLog: () => {},
}
const props = (row: Row): TranscriptRowProps => ({ row, ...ctx })

const TEXT = 'the message that never left'
const delivered = walk(
  TranscriptRow(props({ key: 'l-0', kind: 'local', content: TEXT, queued: false })),
)
const failed = walk(
  TranscriptRow(props({ key: 'l-0', kind: 'local', content: TEXT, queued: false, failed: true })),
)

describe('a rejected send does not paint as a delivered one', () => {
  it('keeps the user’s words — a failed send never loses what was typed', () => {
    expect(failed.text).toContain(TEXT)
  })

  it('drops the delivered fill', () => {
    expect(delivered.styles.some((s) => s.backgroundColor === theme.bubble)).toBe(true)
    expect(failed.styles.some((s) => s.backgroundColor === theme.bubble)).toBe(false)
  })

  it('carries a border the delivered bubble does not — the difference survives a reader who cannot separate two fills', () => {
    const bordered = (w: Walk) => w.styles.some((s) => (s.borderWidth as number) > 0)
    expect(bordered(delivered)).toBe(false)
    expect(bordered(failed)).toBe(true)
  })

  it('says it in WORDS, not in colour alone, and says it to a screen reader', () => {
    expect(failed.text).toContain('not sent')
    expect(delivered.text).not.toContain('not sent')
    expect(failed.labels.join(' ')).toContain('Not sent')
    expect(delivered.labels.join(' ')).not.toContain('Not sent')
  })

  it('never wears the queued badge as well — a failed send is not waiting its turn', () => {
    const queuedAndFailed = walk(
      TranscriptRow(props({ key: 'l-0', kind: 'local', content: TEXT, queued: true, failed: true })),
    )
    expect(queuedAndFailed.text).not.toContain('queued')
    const stillQueued = walk(
      TranscriptRow(props({ key: 'l-0', kind: 'local', content: TEXT, queued: true })),
    )
    expect(stillQueued.text).toContain('queued')
  })

  it('the reducer’s flag reaches the row — localRows carries `failed` through', () => {
    // The seam that would silently swallow the whole fix: a reducer that marks
    // the echo and a row builder that drops the mark.
    const rows = localRows([
      { content: 'a', queued: false, failed: true },
      { content: 'b', queued: false, failed: false },
    ])
    expect(rows.map((r) => (r.kind === 'local' ? r.failed : undefined))).toEqual([true, false])
  })
})
