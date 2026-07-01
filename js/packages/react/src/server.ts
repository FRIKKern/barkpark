// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// RSC-safe entry for @barkpark/react.
//
// Next 15 App Router resolves `react` via the `react-server` export condition,
// which does not expose `createContext`. Anything that calls `createContext`
// at module scope (e.g. `BarkparkReference`) will crash the RSC import graph.
//
// This entry re-exports ONLY the pure, context-free renderers so that a
// Server Component can `import { PortableText } from '@barkpark/react'`
// without pulling `BarkparkReference` into the server graph.
// For `BarkparkReference`, import it from a client component ("use client").
//
// The TYPE exports and `imageUrl` MUST mirror `index.ts` (see exports.test.ts +
// exports-server.test.ts): types are compile-erased so they never touch the RSC
// runtime, and `imageUrl` is a pure builder from the React-free @barkpark/core.
// A Server Component types its Portable Text / image fields and builds rendition
// URLs from the same import a client component uses.

export { PortableText } from './PortableText'
export type {
  PortableTextProps,
  PortableTextComponents,
  // Data-shape types — so RSC consumers can type their own Portable Text fields.
  PortableTextNode,
  PortableTextBlock,
  PortableTextSpan,
  PortableTextMarkDef,
  CustomBlock,
} from './PortableText'
export { BarkparkImage } from './Image'
export type {
  BarkparkImageProps,
  // Asset types — so RSC consumers can type their own image fields.
  ImageAsset,
  ImageAssetRef,
  ImageAssetExpanded,
  ImageAssetMetadata,
} from './Image'

// Image-URL builder (preset-based, the urlFor equivalent) — pure function from
// core, RSC-safe. Re-exported so server consumers need no separate core import.
export { imageUrl } from '@barkpark/core'
export type { RenditionPreset, ImageRef, ImageUrlOptions } from '@barkpark/core'

export type {
  BarkparkReferenceProps,
  RefInput,
  ResolvedDoc,
  BarkparkReferenceClient,
} from './Reference'
