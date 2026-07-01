---
'@barkpark/react': minor
---

`BarkparkImage` now defaults the native `<img>` fallback to `loading="lazy"` and `decoding="async"` — the modern performance posture (as in `next/image`), so below-the-fold images lazy-load without callers wiring it up each time. Both are overridable via props (pass `loading="eager"` for an above-the-fold / LCP hero), and custom `as` components (e.g. `next/image`) are left untouched since they manage their own loading strategy.
