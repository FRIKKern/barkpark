---
"@barkpark/react": patch
---

Paper evidence breakout: the four article `<figure>` emitters now carry the
evidence band inline alongside their air beat — `width: var(--bp-evidence-width,
100%)`, `margin-inline: var(--bp-evidence-pull, 0px)` and `box-sizing:
border-box` — and article figcaptions return to a `var(--bp-evidence-caption,
72ch)` reading measure inside them.

Every fallback resolves to "stay in the column", so an embedder without
`paper-surface.css` renders byte-equivalent output to before. With the sheet
loaded, a figure, diagram, terminal recording or video steps out of the 660px
prose column into a centered band that grows with the viewport (1040px base,
1240px cap) while the prose around it keeps its measure.

Mirrors the Elixir producer; the four figure-family `pd-golden` fixtures moved
with it.
