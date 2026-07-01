---
'@barkpark/core': patch
---

**Fixed:** the SDK now decodes a **bare-string error body** (`{"error":"not_found"}`) into `err.serverCode` + `err.message`, at parity with the `bp` CLI's `classifyError`. Some admin/legacy endpoints answer with a bare string rather than the canonical `{"error":{"code":…}}` envelope; previously `transport` cast the string `error` to an object and read it as `{}`, so `serverCode` came back `undefined` and the message degraded to a bare `HTTP <status>`. A sibling `reason` (the pre-canonical `{"error":"halted","reason":…}` veto shape) is now used as the message. The canonical-envelope, message-only, and non-error-body paths are unchanged.
