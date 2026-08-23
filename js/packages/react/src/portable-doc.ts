// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// `@barkpark/react/portable-doc` — the canonical type-keyed PortableDocument
// renderer as its own subpath, so a consumer that renders only PortableDoc
// tree-shakes free of the legacy PortableText shim. Hook-free and context-free
// (the same code `server.ts` re-exports), so it is safe in Server Components
// and client bundles alike. The root barrel (`@barkpark/react`) keeps exporting
// BOTH surfaces unchanged — this subpath is additive opt-in (compatibility
// policy: README "Subpath exports").

export { PortableDoc, renderPortableDocument } from './PortableDoc'
export type { PortableDocProps, Block, Inline } from './PortableDoc'
