---
'@barkpark/react': patch
---

PortableDoc: the `divider` emitter stamps `bp-section-divider` on its outer
`<div>` and `bp-section-divider__mark` on the `§` span. The classes carry no
styling — every value stays inline, byte-identical to what the Elixir
`:article` emitter (`Figures.section_divider_html/0`) produces, and
`divider.golden.json` is regenerated on both mirrors from that one source. They
are a positional HANDLE: a divider was the last article block rendering as a
class-less box, so a reader stylesheet had no way to say anything about where one
sits. The Barkpark paper shell now uses it to collapse a divider that sits
directly in front of a section head, which already draws that boundary — a render
decision, so the block stays in the document and keeps round-tripping through
every engine. An SDK-rendered document carries the same handle as a
Barkpark-rendered one, so a consumer shipping `paper-surface.css` gets the same
page.
