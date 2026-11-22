---
"@barkpark/react": patch
---

A list item now shows "Nested too deep to show" in place of a block one past the depth limit (block depth 100). Before, the block went away with no notice, because a list item draws only its list children. `capDepth` marks the notice block with the `CAPPED` Symbol in `src/list-children.ts` (not a package export), and `listChildren` keeps a child carrying it. JSON can't carry a Symbol, so a stored list child with `"capped": true` is still dropped.
