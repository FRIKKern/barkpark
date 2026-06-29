---
'@barkpark/codegen': patch
---

Generated types now quote field names that aren't valid JS identifiers (e.g. `my-field`, `2col`, `has space`) — `"my-field"?: string` instead of the invalid `my-field?: string`. Previously such a field produced a `.ts` that wouldn't compile (and `generate` itself threw in the prettier pass). Valid-identifier fields are unchanged.
