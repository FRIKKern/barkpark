---
'@barkpark/react': minor
---

Ship the PortableDoc surface. `@barkpark/react` now exports `PortableDoc` and `renderPortableDocument` — the type-keyed renderer for Barkpark's own PortableDocument block grammar, emitting the same `bp-*` classes Phoenix's Walk emits so React output is byte-faithful to Studio. It is context-free (no `createContext`), so it is mirrored verbatim in the `react-server` entry and drops straight into a Server Component: `<PortableDoc value={blocks} />`, or `renderPortableDocument(blocks)` for a raw HTML string. Ships alongside the block registry (`table`, `sheet`, `dataviz`, `forms`, `chat`, `taskboard`), the pure `toPlainText` extractor for excerpts/meta/reading-time, and the `@barkpark/react/paper-surface.css` stylesheet that themes the rendered document.

The live `@barkpark/react@1.0.0-preview.1` on npm predates all of this (its tarball contains no PortableDoc); this changeset cuts `preview.2`, which the search-starter template pins for its detail route.
