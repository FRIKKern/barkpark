---
'@barkpark/core': minor
---

Added media-collection share links: `client.shareCollection(id, { ttl? })` enables/rotates a public share link (returns `{ token, shareUrl, expiresAt }`; default 7-day TTL) and `client.revokeCollectionShare(id)` revokes it. Completes the collection write surface (membership writes shipped in the previous release). New type: `CollectionShare`.
