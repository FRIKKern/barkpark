---
'@barkpark/core': minor
---

Add semantic query-builder sugar to `client.docs(type)`: `.eq()`, `.in()`, `.contains()`, `.gt()`, `.gte()`, `.lt()`, `.lte()` as thin, validated wrappers over `.where()`. Additive — `.where()` is unchanged.
