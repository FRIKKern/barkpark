---
'@barkpark/react': patch
---

PortableDoc: render the `pre-gate-badge` block. The badge is reader-synthesised — Elixir's `Content.Papers.PreGateRegister.annotate/3` mints it into the block stream of a grandfathered Paper and it is never stored — so the JS renderer meets it in `value` like any other block, and without an emitter it fell through to `bp-unknown-block`. The new emitter mirrors `compose.ex`'s clause and `walk.ex`'s `pre_gate_class/1` exactly: one `<p>` with the `bp-pregate` family root, a tone modifier from a two-value whitelist (anything but `warning` is `neutral`, so a stray value can never mint a class), the `--tucked` modifier only under a byline anchor, and the register's `reader_behaviour` as `title=`, omitted when empty. `toPlainText` deliberately skips it: the label is surface chrome, not reading-flow prose.
