---
'@barkpark/core': minor
---

Add `bp.uploadAsset(file, opts?)` — upload a media asset via multipart `POST /v1/media/:dataset/upload`. `file` is a web `Blob`/`File` (works in Node 18+, browsers, edge, workers — no new deps). The transport now passes `FormData` bodies through and lets fetch set the multipart boundary (JSON requests unchanged). Exports `UploadOptions` / `MediaAsset` types.
