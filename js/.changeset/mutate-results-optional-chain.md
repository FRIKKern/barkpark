---
'@barkpark/core': patch
---

Harden mutation response decoding against a malformed 2xx that omits `results`. `patch().commit()`, `publishDoc`, `unpublishDoc`, and `discardDraftDoc` dereferenced `data.results[0]` **before** the guard that is meant to raise a typed error on a missing/empty result set — so a 2xx body without a `results` field (e.g. from a misbehaving proxy) threw a raw `TypeError: Cannot read properties of undefined (reading '0')` instead of the intended `BarkparkAPIError`/`BarkparkValidationError`. Changed to `data.results?.[0]` so the existing typed-error guard fires as designed.
