---
'@barkpark/react': minor
---

`hydratePortableDoc` now keeps the palette promise its own code comment made:
a colour-mode change repaints already-rendered mermaid diagrams from the
stashed `data-bp-src`, so flipping a page to dark no longer leaves every
diagram on the light palette. Two sources are watched — `<html data-theme>`
(MutationObserver) and `prefers-color-scheme` — and the repaint is guarded on
the RESOLVED theme, so a stamp change that does not change the colour mode
costs nothing. New exports `watchMermaidTheme` / `stopMermaidThemeWatch` on
`@barkpark/react/client` for consumers that want to drive or tear down the
watch themselves. The package still never stamps `data-theme` itself, mermaid
stays a lazy dynamic import, and a diagram-free page installs no listeners.
