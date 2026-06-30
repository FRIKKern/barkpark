---
'@barkpark/codegen': patch
---

Test coverage: the codegen's core `generateTypes`/`mapField` logic had no tests — the field-type → TS-type mappings (17 types + required/optional, select unions, composite recursion, localizedText) were unverified. Added `generate.test.ts` pinning each mapping, so a regression (e.g. `datetime → number`, or a broken optional `?`) now fails CI. No behavior change.
