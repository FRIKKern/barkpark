<!-- doc-tier: agent | canonical-for: http-api-presence | budget: 400tok -->
# Editor presence over HTTP

For non-LiveView clients. Scoped URLs only; the room (workspace + project + dataset) is shared with Studio users.

- `GET /w/:ws/p/:proj/v1/data/presence/:dataset?sessionId=&name=&documentId=&staleAfter=` [token, read] — SSE. Tracks the caller while open. Frames: `event: session` `{sessionId}` once, then `event: presence` `{presences:[{sessionId,name,color,documentId,field,client,selection?}]}` on connect and on every change (`?documentId=` narrows), `: keepalive` every 5 s. `name` defaults to the token label; no `sessionId`: one is generated. `staleAfter=<s>` (≥1): ends after `s` s with no focus POST; re-send the focus to beat (no broadcast).
- `POST …/presence/:dataset/focus` `{sessionId, documentId, field, selection?}` [token, write] — moves the session's focus; `404` unless live + same token. `selection` (`bp-canvas-selection` detail): `{anchor, head}`, each `{blockId, path?, offset}`; `null` clears. Over 512 B JSON `413`, bad shape `422`. `presence_focus` rate class.
- `DELETE …/presence/:dataset/leave?sessionId=` [token, write] — untracks the caller's own session now. `200 {left:true,sessionId}`; `404` unless live + same token. Idempotent. On `pagehide`: `fetch(url, {method:"DELETE", keepalive:true, headers:{Authorization:…}})` (`sendBeacon` can't DELETE or carry the header).

Without `leave` a stream clears on a failed keepalive write (a sleeping laptop: ~15 min, unless `staleAfter`). Prefer `leave`. A grant-admitted caller gets `403`.
