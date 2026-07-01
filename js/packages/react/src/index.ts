'use client'

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export { PortableText } from './PortableText'
export type {
  PortableTextProps,
  PortableTextComponents,
  // Data-shape types — so consumers can type their own Portable Text fields.
  PortableTextNode,
  PortableTextBlock,
  PortableTextSpan,
  PortableTextMarkDef,
  CustomBlock,
} from './PortableText'

// Plain-text extraction (excerpts / meta descriptions / reading time) — pure,
// so it works in a Server Component too. Mirrored in server.ts.
export { toPlainText } from './toPlainText'

export { BarkparkImage } from './Image'
export type {
  BarkparkImageProps,
  // Asset types — so consumers can type their own image fields.
  ImageAsset,
  ImageAssetRef,
  ImageAssetExpanded,
  ImageAssetMetadata,
} from './Image'

// Image-URL builder (preset-based, the urlFor equivalent) — re-exported from core
// so react consumers can build rendition URLs without a separate @barkpark/core import.
export { imageUrl } from '@barkpark/core'
export type { RenditionPreset, ImageRef, ImageUrlOptions } from '@barkpark/core'

export { BarkparkReference } from './Reference'
export type {
  BarkparkReferenceProps,
  // The ref / resolved-doc / client shapes the props accept.
  RefInput,
  ResolvedDoc,
  BarkparkReferenceClient,
} from './Reference'
