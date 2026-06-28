---
'@barkpark/nextjs': patch
---

The root-export `revalidateBarkpark` guard now throws an actionable message — it tells you to import from `@barkpark/nextjs/revalidate` (server-only) and why — instead of the cryptic "not implemented in scaffold (Phase 3)". Return type tightened to `never`.
