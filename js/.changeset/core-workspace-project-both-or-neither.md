---
'@barkpark/core': patch
---

createClient now throws BarkparkValidationError when exactly one of `workspace` / `project` is set. Previously the lone slug was silently ignored and requests fell through to the flat `/v1` routes (reading/writing the wrong content model) — always a misconfiguration, since `scopePrefix()` only emits the scoped `/w/:workspace/p/:project` prefix when both are present. Pass both slugs for scoped routes, or neither for the flat routes. This matches the existing guard in `@barkpark/codegen`.
