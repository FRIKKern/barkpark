---
'@barkpark/core': minor
---

Add `isBarkparkError(e, code?)` type guard. It narrows `unknown` to `BarkparkError` by matching the string `code` field (equal to the class name) rather than `instanceof`, so it stays correct across pnpm-hoisted duplicate class copies. Pass a `code` to narrow to a specific error (e.g. `isBarkparkError(e, 'BarkparkConflictError')`), removing the hand-rolled instanceof-or-`err.code` dance and the `as any` casts consumers previously needed.
