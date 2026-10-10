// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `embed` (note transclusion, `![[note]]`) — the JS twin of walk.ex embed/2 at
// `:article` (rpu-backlog-field-embed-coverage, criterion 3). The block carries
// only a `target`; the Elixir walker injects the caller's PRE-RENDERED target
// HTML (palette `:embeds`, resolved by Papers.resolve_embeds_in_blocks), else
// draws the unresolved placeholder. Same contract here: `embeds` maps a target
// to its pre-rendered HTML, which is injected VERBATIM (it is renderer output
// the caller owns), and a missing target draws the identical placeholder.

import { type Block, escapeHtml } from '../inline'

/** Pre-rendered transclusion HTML, keyed by the embed block's raw `target`. */
export type EmbedHtml = Record<string, string>

export function embedEmitter(embeds?: EmbedHtml): (b: Block) => string {
  return (b) => {
    const raw =
      typeof b.target === 'string' ? b.target : typeof b.target === 'number' ? String(b.target) : ''
    const target = escapeHtml(raw)
    const html =
      embeds && Object.prototype.hasOwnProperty.call(embeds, raw) ? embeds[raw] : undefined
    return typeof html === 'string'
      ? `<section class="paper-embed bp-embed" data-embed="${target}">${html}</section>`
      : `<section class="paper-embed paper-embed--unresolved bp-embed bp-embed--unresolved" data-embed="${target}">↪ ${target}</section>`
  }
}
