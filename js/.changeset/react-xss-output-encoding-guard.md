---
'@barkpark/react': patch
---

Internal: add a permanent XSS output-encoding regression guard for the PortableDoc block emitters (`tests/xss-output-encoding-guard.test.ts`). `renderPortableDocument` returns the exact HTML string consumers inject via `dangerouslySetInnerHTML` with no CSP and no library-controlled sanitizer, so that string boundary is the security boundary. The guard drives a tag/URL breakout payload through every emitter family (core, dataviz, chat, forms, math, table, sheet, taskboard) and asserts no real tag opening (`<img`/`<svg`/`<script`/`<iframe`) and no live `javascript:`/`data:`/`vbscript:` URL scheme survive — locking in the escaping so it goes red if any escaper is removed or a future emitter interpolates a raw user field. Mutation-validated: neutering `escapeHtml`/`safeUrl` flips 64 of 68 assertions red. No runtime change.
