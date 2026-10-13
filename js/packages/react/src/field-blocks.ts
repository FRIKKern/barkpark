// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `@barkpark/react/field-blocks` — the OPT-IN emitters for the schema field
// blocks (field-string … field-image, composite, arrayOf, codelist,
// localizedText; task-7375ba22758155fa). The core PortableDoc bundle does not
// carry them; pass them where a document holds schema fields:
//
//   import { fieldBlocks } from '@barkpark/react/field-blocks'
//   <PortableDoc value={blocks} blocks={fieldBlocks} />
//   renderPortableDocument(blocks, { blocks: fieldBlocks })
//
// Without them those blocks render the core "Unsupported block" placeholder.

import { fieldEmitters } from './blocks/fields'
import type { RenderCtx } from './blocks/chrome'

/** The schema field block emitters, keyed by block type. */
export const fieldBlocks = fieldEmitters as NonNullable<RenderCtx['blocks']>
