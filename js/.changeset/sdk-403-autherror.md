---
'@barkpark/core': patch
---

A 403 response now throws `BarkparkAuthError`, matching that class's own doc ("401/403 or token invalid"). The transport only wired 401 + the auth codes, so a 403 (token lacks permission, CORS/CSRF rejection) fell through to a generic `BarkparkAPIError` — consumers couldn't `catch (e instanceof BarkparkAuthError)` a permission failure even though the class advertised it. Now `status === 403` and the `forbidden`/`cors_forbidden`/`csrf_required` codes map to `BarkparkAuthError` alongside 401.
