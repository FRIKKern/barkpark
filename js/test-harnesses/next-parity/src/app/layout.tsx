// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Root layout for the Wave-3 Next static-export parity surface. It links the
// canonical `@barkpark/react` paper stylesheet so the exported HTML skins
// `PortableDoc` output identically to Phoenix — the Kinsta/Vercel visual-fidelity
// deliverable (charter D22, carried over). The CSS is a `<link>` only; it is
// orthogonal to the DOM-shape parity the harness asserts (never byte-compared).
import type { ReactNode } from 'react'
import '@barkpark/react/paper-surface.css'

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
