---
'@barkpark/core': patch
---

Document the `client.auth` surface in the core README. The full user-auth lifecycle (register / login / me / logout, TOTP MFA enrol-verify-disable, and email-verification + password recovery) shipped across several releases but had no README section — it was complete yet undiscoverable. Adds an "Auth" section with accurate, verified examples.
