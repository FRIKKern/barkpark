---
'@barkpark/core': patch
---

Every thrown `BarkparkError` now carries `details` (the server envelope's structured details map, e.g. `duplicate_task`'s `similar`/`advise`, `schema_has_documents`'s `count`) and `reason` (the envelope's top-level sub-code, e.g. `forbidden_membership`'s `not_a_member`) — previously `transport.ts` parsed `details` from the envelope but only attached it to the 429/412/422 branches' thrown error, so a 401/403/409/404 (auth, conflict, not-found) silently dropped it, and the top-level `reason` discriminator was never read at all on the canonical envelope path. Both fields are purely additive on `BarkparkErrorOptions` and the `BarkparkError` base class, assigned with the same `undefined`-guard as the existing `serverCode`/`hint` fields — no existing field changed type or disappeared, and no thrown error class changed.
