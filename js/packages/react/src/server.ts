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

export { PortableText } from './PortableText'
export type { PortableTextProps, PortableTextComponents } from './PortableText'
export { BarkparkImage } from './Image'
export type { BarkparkImageProps } from './Image'
export type {
  BarkparkReferenceProps,
  RefInput,
  ResolvedDoc,
  BarkparkReferenceClient,
} from './Reference'
