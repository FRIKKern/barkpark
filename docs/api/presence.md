<!-- doc-tier: agent | canonical-for: http-api-presence | budget: 400tok -->
# Editor presence over HTTP

For editing clients that aren't the LiveView Studio. Scoped URLs only; the room is workspace + project + dataset, shared with Studio users.

- `GET /w/:ws/p/:proj/v1/data/presence/:dataset?sessionId=&name=&documentId=` [token, read] — SSE. Tracks the caller while open. Frames: `event: session` `{sessionId}` once, then `event: presence` `{presences:[{sessionId,name,color,documentId,field,client,selection?}]}` on connect and on every change (`?documentId=` narrows), `: keepalive` every 5 s. `name` defaults to the token label; omit `sessionId` and one is generated.
- `POST …/presence/:dataset/focus` `{sessionId, documentId, field, selection?}` [token, write] — moves that session's focus. `404` unless open and opened by the same token. `selection`: canvas `bp-canvas-selection` detail, `{anchor, head}` each `{blockId, path?, offset}`, `null` clears. Over 512 B JSON `413`, bad shape `422`. `presence_focus` rate class.
- `DELETE …/presence/:dataset/leave?sessionId=` [token, write] — untracks the caller's own session now. `200 {left:true,sessionId}`; `404` unless live + same token (self only, no leak). Idempotent. Call on `pagehide`/doc switch: `fetch(url, {method:"DELETE", keepalive:true, headers:{Authorization:…}})` — `sendBeacon` can't carry the header or DELETE.

A stream closing without `leave` also clears, but only on its next failed keepalive write — not instant. `leave` is deterministic; prefer it. A grant-admitted caller gets `403`.
