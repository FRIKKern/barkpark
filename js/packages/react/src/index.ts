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

export { BarkparkImage } from './Image'
export type {
  BarkparkImageProps,
  // Asset types — so consumers can type their own image fields.
  ImageAsset,
  ImageAssetRef,
  ImageAssetExpanded,
  ImageAssetMetadata,
} from './Image'

export { BarkparkReference } from './Reference'
export type {
  BarkparkReferenceProps,
  // The ref / resolved-doc / client shapes the props accept.
  RefInput,
  ResolvedDoc,
  BarkparkReferenceClient,
} from './Reference'
