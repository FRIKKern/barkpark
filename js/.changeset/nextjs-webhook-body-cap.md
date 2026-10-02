---
'@barkpark/nextjs': patch
---

`createWebhookHandler` now caps the request body it reads. The default is 4 MiB, and a body over the cap is answered `413 { error: 'payload_too_large' }`.

The signature covers the whole body, so the handler has to read the body before it can authenticate the sender; only the unsigned timestamp is checked first. Before this change it read the whole body with `req.text()`, so any sender could make a self-hosted `next start` hold as much memory as it chose to send.

The new read works in two steps:

- A declared `Content-Length` over the cap is refused without reading.
- A streamed body is counted as it arrives and cancelled at the cap.

To raise the cap, set the new `maxBodyBytes` option. You only need to if your webhook payloads carry documents larger than 4 MiB, which is about the request limit serverless hosts already enforce.
