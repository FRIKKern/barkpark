---
'@barkpark/react': minor
---

Reader-Owned Spacing Doctrine (the 2026-07-31 flip of `/papers/mechanical-spacing-doctrine`), plus two hydration/extraction fixes:

- **`renderPortableDocument` / `PortableDoc` no longer emit `<p></p>` for empty paragraph scaffolds.** A paragraph block whose inline run is nothing (`content: []`, no `text`) or only whitespace text renders NOTHING — readers own vertical rhythm between semantic blocks; an empty paragraph is never published layout. Suppression is exact and narrow: authored text, marks, links, and every non-text inline keep their `<p>` byte-faithful. `paper-surface.css` grows a belt-and-braces `.bp-paper-surface p:empty { display: none }` for legacy cached HTML.
- **`toPlainText` stops silently dropping content.** Headings/eyebrows persisted as `content[]`, list items authored as untyped maps (`{content:[…]}` / `{text}`) or JSON-encoded inline arrays, table cells authored as untyped maps, and `expandable` blocks (summary + nested blocks) now all contribute their words to excerpts/search. `expandable` moves from the textless skip-list to the prose partition.
- **`hydratePortableDoc` renders mermaid themed.** `mermaid.initialize` now derives its theme from the active mode — an explicit `data-theme` stamp on `<html>` wins (`dark` → dark), else `prefers-color-scheme` — so diagrams are legible on dark surfaces. The resolution seam is exported as `activeMermaidTheme`.
