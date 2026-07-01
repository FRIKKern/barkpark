---
'@barkpark/core': patch
---

`isBarkparkError(e, code)` now narrows `e` to the specific error subclass, not just the abstract `BarkparkError`. Typed overloads (one per concrete class) make the README's documented promise true: after `isBarkparkError(e, 'BarkparkRateLimitError')` you can read `e.retryAfterMs` (and `serverEtag`/`serverDoc`, `timeoutMs`, `issues`/`field`, `body`) with no cast. The known class names are the new exported `BarkparkErrorCode` union, giving autocomplete on the `code` argument (an arbitrary string is still accepted for cross-bundle codes, but only a union member narrows the subclass). Types-only — no runtime behaviour changes.
