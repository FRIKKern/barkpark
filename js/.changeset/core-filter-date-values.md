---
'@barkpark/core': patch
---

Comparison filter sugar (`gt`/`gte`/`lt`/`lte`) and `FilterValue` now accept `Date` values, and `buildQueryString` ISO-normalizes them (`toISOString()`) instead of falling back to `String()`. Previously `.gt('_createdAt', someDate)` was a type error, and casting around it silently serialized a locale string (`'Thu Jul 01 2026 …'`) the Phoenix query parser can't read. Widening the input is additive; a `Date` now encodes as `2026-07-01T00:00:00.000Z`.
