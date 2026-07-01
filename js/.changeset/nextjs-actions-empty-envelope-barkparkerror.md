---
'@barkpark/nextjs': patch
---

`defineActions`' `createDoc` and `deleteDoc` now throw a `BarkparkAPIError` (not a bare `Error`) when the mutate envelope comes back with no results. This honors the "every failure is a `BarkparkError`" contract, so consumers using the cross-bundle-safe `if (isBarkparkError(e))` pattern in their Server Action error boundaries catch this edge and keep `.code`/`.status`/`.hint` — matching what the core patch builder already does on the identical condition.
