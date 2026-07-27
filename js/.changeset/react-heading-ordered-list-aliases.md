---
'@barkpark/react': patch
---

PortableDoc: normalized the `h1` / `h2` / `h3` / `ordered-list` authoring-drift spellings that leaked "Unsupported block" placeholders (20 live prod blocks, unknown-boxing on every surface at once). `coreEmitters` now aliases `h1` / `h2` / `h3` → `heading` at the level the TYPE names and `ordered-list` → the same ordered-list emitter as `numbered_list`. The level is taken from the type, NOT from a stored `level` field: 6 of the 18 drifted headings carry no `level` key at all, so a plain `h3: heading` alias would have emitted `<h2>` for them. A contradicting stored level loses to the type. `REGISTERED_TYPES` goes 66 → 70. No stored-data migration — render-side only, so the same spellings keep working if an author reaches for them again.
