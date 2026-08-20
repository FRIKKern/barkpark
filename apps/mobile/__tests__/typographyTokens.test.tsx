// The type system's contract, pinned (t3w2-s8-token-migration).
//
// S8 moved every fontSize/lineHeight literal in apps/mobile/src onto
// src/ui/typography.ts, which makes that file the single owner of the app's
// rendered type geometry — and therefore the single point where a one-line
// edit can silently reflow every screen at once. The ESLint literal ban keeps
// values OUT of the call sites; this suite keeps the values in the token
// module HONEST:
//
//   1. THE SETTLED REGISTER — the #6126 bubble law (16/23 user, 16/26
//      assistant) and the reader's 16/26 serif measure, asserted both on the
//      tokens and THROUGH the screen that renders them.
//   2. NO HALF-TOKENS — every step and role carries both a size and a lead.
//      A role with a size and no lead silently re-introduces the platform
//      default the scale exists to replace.
//   3. THE HEADING LAW — paper and chat heading roles ARE fontSize × 1.3
//      rounded, the formula blocks.tsx used to compute inline.
import { TranscriptRow, chatBlockCtx, type Row } from '../src/screens/ChatSessionScreen'
import type { ChatMessage } from '../src/chat/wire'
import { light, type Theme } from '../src/ui/theme'
import { roles, scale } from '../src/ui/typography'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme: Theme = light

/* ── the walker (same shape the sibling renderer suites use) ─────────────── */

interface Style {
  fontSize?: number
  lineHeight?: number
  fontFamily?: string
}

function walkStyles(node: unknown, acc: Style[] = []): Style[] {
  if (!node || typeof node !== 'object') return acc
  if (Array.isArray(node)) {
    for (const c of node) walkStyles(c, acc)
    return acc
  }
  const el = node as { props?: Record<string, unknown>; $$typeof?: symbol }
  if (!('$$typeof' in el) || !el.props) return acc
  const raw = el.props.style
  if (raw !== undefined) {
    const parts = Array.isArray(raw) ? raw : [raw]
    acc.push(Object.assign({}, ...parts.filter(Boolean)) as Style)
  }
  walkStyles(el.props.children, acc)
  return acc
}

function row(role: 'user' | 'assistant', m: Partial<ChatMessage> = {}): Row {
  return {
    key: 'm-1',
    kind: 'message',
    message: { seq: 1, role, source_markdown: 'a turn', ...m },
  }
}

function renderRow(r: Row): Style[] {
  return walkStyles(
    TranscriptRow({ row: r, theme, blockCtx: chatBlockCtx(theme), inFlight: {}, onAnswer: () => {} }),
  )
}

/* ── 1. the settled register ─────────────────────────────────────────────── */

describe('the #6126 register survives tokenisation', () => {
  it('the bubble law is 16/23 user, 16/26 assistant — on the tokens', () => {
    expect(roles.userBubble).toEqual({ fontSize: 16, lineHeight: 23 })
    expect(roles.chatBody).toEqual({ fontSize: 16, lineHeight: 26 })
    // The user turn is DELIBERATELY tighter than the answer. Collapsing the
    // two onto one token would read as a regression, not a cleanup.
    expect(roles.userBubble.lineHeight).toBeLessThan(roles.chatBody.lineHeight)
    expect(roles.userBubble.fontSize).toBe(roles.chatBody.fontSize)
  })

  it('the reader measure is 16/26 SERIF and the transcript measure is its sans twin', () => {
    expect(roles.readingBody).toEqual({ fontSize: 16, lineHeight: 26, fontFamily: 'serif' })
    expect(roles.chatBody.fontSize).toBe(roles.readingBody.fontSize)
    expect(roles.chatBody.lineHeight).toBe(roles.readingBody.lineHeight)
    expect('fontFamily' in roles.chatBody).toBe(false)
  })

  it('reaches those pairs THROUGH the screen, not just the token module', () => {
    const user = renderRow(row('user'))
    expect(user.some((s) => s.fontSize === 16 && s.lineHeight === 23)).toBe(true)

    const assistant = renderRow(row('assistant'))
    expect(assistant.some((s) => s.fontSize === 16 && s.lineHeight === 26)).toBe(true)
  })
})

/* ── 2. no half-tokens ───────────────────────────────────────────────────── */

describe('the token module is total', () => {
  it('every chrome step carries an explicit lead', () => {
    for (const [name, step] of Object.entries(scale)) {
      expect(typeof step.fontSize).toBe('number')
      expect(typeof step.lineHeight).toBe('number')
      // A lead below the size is a typo, not a design; above 1.6 is a bug.
      const ratio = step.lineHeight / step.fontSize
      expect({ name, ok: ratio > 1 && ratio < 1.6 }).toEqual({ name, ok: true })
    }
  })

  it('every named role carries an explicit lead', () => {
    for (const [name, role] of Object.entries(roles)) {
      expect({ name, hasSize: typeof role.fontSize === 'number' }).toEqual({ name, hasSize: true })
      expect({ name, hasLead: typeof role.lineHeight === 'number' }).toEqual({ name, hasLead: true })
    }
  })

  it('the 8 census steps keep the sizes the census measured', () => {
    expect(Object.values(scale).map((s) => s.fontSize)).toEqual([11, 12, 13, 14, 15, 16, 20, 26])
  })
})

/* ── 3. the heading law ──────────────────────────────────────────────────── */

describe('heading roles ARE the ×1.3 law', () => {
  // The ×1.3 assertion below is a RELATION, not a value: it holds for 26/34
  // and equally for 28/36. Since S8 made typography.ts the sole owner of the
  // app's rendered geometry, a heading register pinned only by its own ratio
  // is not pinned at all — the whole reader could be scaled up a step and
  // every test would stay green. These are the absolute values the paper and
  // chat registers shipped (blocks.tsx REGISTERS before the migration); they
  // are the thing a screenshot would have caught.
  it('the heading roles keep the sizes the registers shipped', () => {
    expect([roles.paperH1, roles.paperH2, roles.paperH3].map((s) => [s.fontSize, s.lineHeight])).toEqual([
      [26, 34],
      [22, 29],
      [18, 23],
    ])
    expect([roles.chatH1, roles.chatH2, roles.chatH3].map((s) => [s.fontSize, s.lineHeight])).toEqual([
      [20, 26],
      [18, 23],
      [16, 21],
    ])
  })

  it('paper and chat heading leads are the size × 1.3, rounded', () => {
    for (const step of [
      roles.paperH1,
      roles.paperH2,
      roles.paperH3,
      roles.chatH1,
      roles.chatH2,
      roles.chatH3,
    ]) {
      expect(step.lineHeight).toBe(Math.round(step.fontSize * 1.3))
    }
  })

  it('the chat register is strictly smaller than the paper one at every level', () => {
    expect(roles.chatH1.fontSize).toBeLessThan(roles.paperH1.fontSize)
    expect(roles.chatH2.fontSize).toBeLessThan(roles.paperH2.fontSize)
    expect(roles.chatH3.fontSize).toBeLessThan(roles.paperH3.fontSize)
  })
})
