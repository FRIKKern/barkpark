---
"@barkpark/react": patch
---

The code, code-tabs and diagram blocks no longer put theme colours in their markup, matching the server renderer. The code slab carries `bp-codeblock`, and the diagram frame carries `bp-diagram`. Their ground, ink and rule colour come from the paper-surface stylesheet, and the frame keeps its border width and style inline. On a page that loads that stylesheet nothing changes. Rendered without it, these blocks take the host site's colours.
