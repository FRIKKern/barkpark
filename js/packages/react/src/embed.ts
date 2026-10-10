// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `@barkpark/react/embed` — the OPT-IN emitter for `embed` blocks (note
// transclusion). The core bundle does not carry it. Pass it through the same
// `blocks` option as the field blocks:
//
//   import { embedBlocks } from '@barkpark/react/embed'
//   <PortableDoc value={blocks} blocks={embedBlocks({ 'Field notes': html })} />
//
// `embeds` maps a block's `target` to PRE-RENDERED HTML (for example the
// server's render of that paper), injected verbatim: only pass HTML you
// produced or trust. A target with no entry, or no map at all, renders the
// inert "↪ target" placeholder the Phoenix reader shows for an unresolved embed.

import { type EmbedHtml, embedEmitter } from './blocks/embed'
import type { RenderCtx } from './blocks/chrome'

export type { EmbedHtml } from './blocks/embed'

/**
 * The `embed` emitter for the `blocks` option, resolving targets from `embeds`.
 *
 * TRUST CONTRACT: the HTML in `embeds` is CALLER-TRUSTED and injected verbatim,
 * the same contract as the Elixir renderer's `:embeds` palette. It comes ONLY
 * from this map: nothing in the document (the block's own fields included) is
 * ever read as HTML, so an embed block carrying markup still renders the inert
 * `↪ target` placeholder. Fill the map only with HTML you rendered or trust.
 */
export function embedBlocks(embeds?: EmbedHtml): NonNullable<RenderCtx['blocks']> {
  return { embed: embedEmitter(embeds) } as NonNullable<RenderCtx['blocks']>
}
