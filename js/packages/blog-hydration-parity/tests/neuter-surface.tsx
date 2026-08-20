// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// REVERT-RED NEUTER of create-barkpark-app's `PortableDocSurface` island.
//
// This is a byte-for-byte clone of the real island's STATIC render path with
// exactly one thing removed: the `useEffect(() => hydratePortableDoc(...))`
// call (and its `@barkpark/react/client` import). Everything else — the
// `bp-paper-surface` root, the `renderPortableDocument` string emit, the ref —
// is identical.
//
// It exists so the positive proof is genuinely PROTECTIVE, not vacuous green:
// if hydration silently regressed to a no-op, a passing suite would look EXACTLY
// like mounting this component — the mermaid `<pre>` and asciicast `<div>` mount
// points present in the DOM but forever inert. The neuter test asserts precisely
// that inertness, so a revert of the island's hydration call (or a broken
// hydratePortableDoc) turns the suite red.

'use client'

import { useRef } from 'react'
import { renderPortableDocument, type Block } from '@barkpark/react'

interface Props {
  blocks: Block[]
  className?: string
}

export function NeuterDocSurface({ blocks, className }: Props) {
  const ref = useRef<HTMLDivElement>(null)

  // DELIBERATELY NO `useEffect(hydratePortableDoc)` — this is the neuter. The
  // static HTML renders; the media mount points never become live.

  const cls = className ? `bp-paper-surface ${className}` : 'bp-paper-surface'
  return (
    <div
      ref={ref}
      className={cls}
      dangerouslySetInnerHTML={{ __html: renderPortableDocument(blocks) }}
    />
  )
}
