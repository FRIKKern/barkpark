---
'@barkpark/react': patch
---

`PortableText`: guard against a `RangeError` crash on a list block whose `level` is fractional or non-numeric. The level is used as an array length (`stack.length = lvl`), so a value like `1.5` or `"abc"` (→ `NaN`) — from loosely-typed query data or an import — slipped past the `Math.max(1, …)` clamp and threw `RangeError: Invalid array length`, taking down the entire render. `level` is now coerced and floored to an integer ≥ 1, matching the package's fail-soft handling of missing `children`/`marks`/unknown types.
