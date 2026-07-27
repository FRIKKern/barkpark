// The register chrome — ONE owner (charter D49), never duplicated per family:
// the BlockCtx/Render contract every renderer is typed against, the two
// typographic registers (paper/chat), and the spec()/bodyText() helpers the
// family modules in ./blocks/ read them through.
import type { ReactNode } from 'react'

import type { Theme } from '../../ui/theme'
import { roles, type TypeStep } from '../../ui/typography'
import type { BlockRegister, InlineCtx } from './inlines'
import type { Block } from './model'

/** Which typographic voice the same block tree speaks in. `paper` is the
 * reader's serif document register; `chat` is the transcript's sans register
 * (charter D22). An OPTIONAL FIELD, never a positional argument: every
 * container recursion already forwards `ctx` wholesale, so the register
 * reaches nested blocks for free, and `undefined` IS `'paper'` — the paper
 * reader's call sites stay byte-unchanged.
 *
 * DECLARED in inlines.tsx (so inline code styling can read it without a module
 * cycle) and re-exported here, where every caller already imports it. */
export type { BlockRegister }

export interface BlockCtx extends InlineCtx {
  theme: Theme
  /** The connected instance's base URL (connection.projectUrl). Root-relative
   * media srcs — 39 of 40 live image blocks use `/media/files/…` (review
   * census F2) — resolve against it, mirroring how the web surfaces serve
   * the same paths same-origin. */
  serverBase?: string
  /** Defaults to 'paper'. */
  register?: BlockRegister
}

/** One block renderer. Exported so the chat.tsx sibling types its own six
 * against the SAME signature the dispatcher calls — a spread that drifted from
 * this shape would not compile. */
export type Render = (b: Block, ctx: BlockCtx, key: number) => ReactNode

/* ── registers ──────────────────────────────────────────────────────────────── */

// The serif face is no longer named here: it rides the token that needs it
// (roles.readingBody / paperIngress / paperPullquote all carry fontFamily).
export const MONO = 'monospace'

interface RegisterSpec {
  /** The body measure. The paper token carries the serif face on itself; the
   * chat token omits fontFamily, which IS the platform's system sans. */
  body: TypeStep & { readonly fontFamily?: string }
  /** Each heading step carries its own lead. The ×1.3 law that used to be
   * computed here now lives in the token module (roles.paperH1/H2/H3 and
   * roles.chatH1/H2/H3 are that formula, rounded) — one owner for the value. */
  heading: Record<1 | 2 | 3, { step: TypeStep; marginTop: number }>
}

export const REGISTERS: Record<BlockRegister, RegisterSpec> = {
  // The reader: serif measure, display headings, generous lead.
  paper: {
    body: roles.readingBody,
    heading: {
      1: { step: roles.paperH1, marginTop: 24 },
      2: { step: roles.paperH2, marginTop: 20 },
      3: { step: roles.paperH3, marginTop: 16 },
    },
  },
  // The transcript: the same 16/26 measure the #6126 assistant turn already
  // ships, in the system sans — a chat answer is speech, not a printed page.
  // Headings compress hard: an assistant turn is a few hundred words, so a
  // 26 pt display head would out-shout the whole screen.
  chat: {
    body: roles.chatBody,
    heading: {
      1: { step: roles.chatH1, marginTop: 16 },
      2: { step: roles.chatH2, marginTop: 14 },
      3: { step: roles.chatH3, marginTop: 12 },
    },
  },
}

export function spec(ctx: BlockCtx): RegisterSpec {
  return REGISTERS[ctx.register ?? 'paper']
}

export function bodyText(ctx: BlockCtx) {
  return { ...spec(ctx).body, color: ctx.theme.text }
}
