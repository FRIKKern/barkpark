// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `@barkpark/react/portable-text` — the LEGACY Sanity-shaped PortableText shim
// as its own subpath, so a consumer that renders only PortableText tree-shakes
// free of the PortableDoc renderer chunk (~16KB gzip it never uses). The root
// barrel (`@barkpark/react`) keeps exporting BOTH surfaces unchanged — this
// subpath is additive opt-in, never a migration requirement (compatibility
// policy: README "Subpath exports").

export { PortableText } from './PortableText'
export type {
  PortableTextProps,
  PortableTextComponents,
  PortableTextNode,
  PortableTextBlock,
  PortableTextSpan,
  PortableTextMarkDef,
  CustomBlock,
} from './PortableText'
