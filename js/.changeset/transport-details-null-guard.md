---
'@barkpark/core': patch
---

Fix a `TypeError` crash when the API returns a `422` (or any error envelope) whose `details` field is JSON `null`. Because `typeof null === 'object'`, the transport treated `details: null` as a validation map and called `Object.entries(null)`, throwing a raw `TypeError: Cannot convert undefined or null to object` that escaped the SDK's error taxonomy — the caller lost the status code, `serverCode`, `message`, and `request_id`, and `isBarkparkError(e, 'BarkparkValidationError')` returned `false`. This affected the entire mutation surface (`patch().commit()`, `transaction().commit()`, `create`/`publish`/`upsertSchema`/`createWebhook`, …) on any `details: null` error — a normal Phoenix changeset-less 422. The `details` guard now excludes `null`, so these surface as a proper `BarkparkValidationError` with the server's status/code/message/request-id intact.
