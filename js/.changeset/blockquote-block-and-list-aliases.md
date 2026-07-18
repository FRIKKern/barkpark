---
'@barkpark/react': patch
---

PortableDoc: born a real `blockquote` block and normalized the authoring-drift list/quote spellings that leaked "Unsupported block" placeholders (77 live prod blocks). The `blockquote` emitter renders a semantic `<blockquote class="bp-blockquote">` with a `<p>` body (from a `content` inline array or a bare `text`) plus an optional `<cite class="bp-blockquote__cite">` attribution — shape-equal to the Elixir `:article` golden. `coreEmitters` now aliases `bulletList` / `bullet_list` / `bulleted-list` / `bulleted_list` → `list`, `numbered_list` → an ordered `list`, and `quote` → `blockquote`. List items persisted as JSON-encoded inline-array strings (the `bullet_list` drift shape) are decoded to real inline nodes instead of rendering as literal JSON. No stored-data migration — render-side only.
