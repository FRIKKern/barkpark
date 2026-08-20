---
'@barkpark/react': patch
---

Render the `{content:[…]}` list-item shape (and three swept siblings) instead of dropping it.

A live-corpus census (537 published papers on guerrilla, 2026-07-25) found 2,046
of 10,455 published list items rendering as an empty `<li><span></span></li>`:
`renderInlines` returns `''` for a map, and the list emitter passed items
straight through. The list emitter now normalizes an item through `itemInlines`
— array / JSON-string / plain string / **map with its own `content` or `text`** —
the semantics the shipped RN reader (`apps/mobile/src/papers/portabledoc`)
already proved against the same corpus, and the same content||text law the
heading emitter took in `@barkpark/react@…` (PR #6009).

Swept the sibling emitters for the same class:

- `eyebrow` and `note` read `text` alone and blanked their `content[]` form.
- An inline `code` node authored with `children[]` (rather than a flat `value`)
  rendered `<code></code>`; children now fold to escaped plain text.
- A nested inline array (`content: [[{…}]]`, flattened one level too shallow)
  returned `''` — a js-only divergence from `inline.ex compose_inline(is_list)`,
  which wraps it in a PdText that `walk.ex` emits as a bare `<span>`.

Post-fix census: 13 of 10,455 items still blank, all in one paper, all from an
unrelated shape (inline text nodes keyed `text` instead of `value`, which the
Elixir twin also drops). Every fallback fires only when the existing
`text`/`value` path is absent or empty, so the Elixir golden-parity fixtures are
byte-unchanged.
