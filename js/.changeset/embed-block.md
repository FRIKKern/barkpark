---
'@barkpark/react': minor
---

New opt-in subpath `@barkpark/react/embed` for `embed` blocks (note transclusion, `![[note]]`). Pass `embedBlocks(embeds)` through the `blocks` option: `<PortableDoc blocks={embedBlocks({ 'Field notes': html })}>`.

`embeds` maps an embed's `target` to pre-rendered HTML, which is injected inside the same `section.bp-embed` frame the Phoenix reader draws. Only pass HTML you produced or trust. A target with no entry renders the reader's inert `↪ target` placeholder. Without the option, `embed` keeps rendering the "Unsupported block" placeholder, and the core bundles are unchanged.
