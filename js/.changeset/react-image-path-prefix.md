---
'@barkpark/react': minor
---

`BarkparkImage` gains an optional `pathPrefix` prop, forwarded to core `imageUrl` when building a `preset` rendition URL. Set it to a workspace/project scope prefix (e.g. `/w/<ws>/p/<proj>`) when the asset lives in a non-Default workspace, whose renditions are only reachable via the scoped route. Unset, behavior is unchanged.
