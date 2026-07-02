---
"@barkpark/core": patch
---

getDoc / client.doc() now throw BarkparkValidationError on an empty or non-string type or id (parity with getHistory/getBacklinks/restoreRevision) instead of issuing a collapsed `/v1/data/doc/<ds>/<type>/` request that returned an opaque server 404/405.
