---
"@barkpark/core": patch
---

uploadAsset now throws BarkparkEdgeRuntimeError instead of a bare Error when the runtime lacks a global FormData, honoring the "every failure is a BarkparkError" contract.
