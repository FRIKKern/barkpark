---
"@barkpark/react": minor
---

Add `PortableDoc`, the canonical type-keyed PortableDocument renderer.

`PortableDoc({ value })` renders Barkpark's own `type`-keyed block AST
(heading/paragraph/list/table/callout/code/divider/image/figure/section/columns
plus the data-viz, forms, task-tracking, and chat families — 42 block types) and
emits the exact `bp-*` class vocabulary Phoenix's `Render.Walk` emits at
`style=:article`, so one stylesheet (`paper-surface.css`) skins Next, Astro, and
Phoenix identically. It is context-free (no `createContext`, no hooks) and ships
from both the client entry and the RSC-safe `react-server` entry. Also exports
`renderPortableDocument(value)` — the framework-free HTML-string form — plus the
`Block` / `Inline` / `PortableDocProps` types.

The existing Sanity-shaped `PortableText` renderer is unchanged and stays the
legacy shim for `_type:'block'` content.
