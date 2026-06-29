---
'@barkpark/react': patch
---

`PortableText` now nests list items by their `level` — a level-2 item renders as a nested `<ul>`/`<ol>` inside the parent `<li>` instead of flat. Non-nested lists (no `level`) are unchanged; custom `components.list`/`listItem` apply at every depth. Matches Sanity's `@portabletext/react` list behavior.
