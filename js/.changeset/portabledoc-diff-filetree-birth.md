---
'@barkpark/react': patch
---

Register two new PortableDoc block types — `diff` and `filetree` — in the canonical `@barkpark/react` renderer (Scaffy W7 dogfood wave, born via `bp scaffy run add-block-type`). Both ship in starter-parity form: the block's `text` attr rendered into a `bp-diff` / `bp-filetree` wrapper (honest empty state — empty text renders nothing), shape-equal to the Elixir emitter via the pd-golden parity fixtures. `toPlainText` extracts each block's `text`. The rich renderers (unified-diff +/- semantics, annotated tree glyphs) grow in a follow-up slice; this change makes the types render instead of degrading to unknown.
