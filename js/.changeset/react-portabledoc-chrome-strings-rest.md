---
'@barkpark/react': patch
---

The `strings` map of `PortableDoc` / `renderPortableDocument` now also covers the rest of the renderer's own words: callout tone names, data-viz fallbacks and legends ("less"/"more", "series N", "Total", "(none)", "route track"), equation and sheet notes, the terminal "live" chip, and the paper-link card labels. Keys are the English text; without `strings`, output is unchanged.
