---
"@barkpark/react": patch
---

Article links render as a bare `<a href>`: the inline `color:var(--paper-accent, …)` is gone, matching the server renderer. On a page that loads the paper-surface stylesheet nothing changes, because the `.bp-paper-surface a` rule paints the same colour. Rendered without that stylesheet, links take the host site's own link colour.
