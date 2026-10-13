---
"@barkpark/react": patch
---

The paper-links block and the route block no longer put theme colours in their markup, matching the server renderer. Paper-links elements carry `bp-plinks*` / `bp-plink*` classes, and their rules, borders and inks come from the paper-surface stylesheet; layout and type stay inline. The route track strokes `currentColor`, and the stylesheet paints it along with the meta, caption and separator. On a page that loads the paper-surface stylesheet nothing changes. Rendered without it, these blocks take the host site's colours.
