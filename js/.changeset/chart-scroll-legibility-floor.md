---
'@barkpark/react': patch
---

PortableDoc: the `chart` block's svg now rides a `div.bp-chart__scroll` container, mirroring the Phoenix emitter. The chart's text is sized in viewBox units (640 wide), so a bare `width:100%` svg scaled every label with its container — 11px ticks painted 4.26px at a 360px viewport. The paper-surface stylesheet pins the svg at `min-width:640px` inside the scroll wrapper, so tick and annotation text never paints below its authored px and the figure scrolls horizontally at narrow widths instead of shrinking its labels away. Caption and legend stay outside the scroll container; the wide end (charts at or above the 640px viewBox width) renders exactly as before.
