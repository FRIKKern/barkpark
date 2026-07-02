---
'@barkpark/core': patch
---

getWebhook now throws BarkparkValidationError on an empty id before any request is made (previously the request path collapsed to the webhook list route and the call returned null), matching getAsset/updateWebhook/deleteWebhook.
