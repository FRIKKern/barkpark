---
'@barkpark/nextjs': patch
---

`useOptimisticDocument` now uses core's `isBarkparkError(e, 'BarkparkConflictError')` type guard to detect conflicts instead of hand-rolling the `instanceof`-or-`err.code` dance. Behaviour is unchanged (still bundle-safe across pnpm-hoisted class copies), but the two `@typescript-eslint/no-explicit-any` casts are gone — cleaner reference code for consumers copying the pattern.
