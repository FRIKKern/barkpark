---
"@barkpark/react": patch
---

`<PortableDoc>` answers the server renderer's limits the same way: a block or inline nested past the depth limit shows "Nested too deep to show", a record table past the cell cap shows "Table too large to show", a toc reads at most six levels, sheet merges and table spans stop at the first one past the cells left, out-of-range chart and heatmap numbers are left out, and whole numbers print every digit. Table `spans` now render as `colspan`/`rowspan`, and deeply nested inline arrays no longer run out of stack.
