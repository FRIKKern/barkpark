---
'@barkpark/core': minor
---

`client.imageUrl` now respects the client's workspace/project scope. Previously it built rendition URLs with only `{ baseUrl: projectUrl }`, so a scoped client (`workspace`/`project` set) emitted the flat `/media/renditions/<id>/<preset>` route — which the server pins to the Default workspace, 404ing every non-Default rendition `<img src>`. `imageUrl` now prepends `scopePrefix(config)` (e.g. `/w/<ws>/p/<proj>`), matching the scope invariant every other path builder already follows. `ImageUrlOptions` gains a public `pathPrefix?` field (the scope prefix for the built `/media/...` and `/images/...` paths; ignored for inline urls). Flat (unscoped) clients are byte-identical to before — `scopePrefix` returns `''`.
