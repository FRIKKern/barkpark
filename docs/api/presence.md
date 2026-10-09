<!-- doc-tier: agent | canonical-for: http-api-presence | budget: 400tok -->
# Editor presence over HTTP

For editing clients that are not the LiveView Studio. Scoped URLs only; the room is workspace + project + dataset, shared with Studio users.

- `GET /w/:ws/p/:proj/v1/data/presence/:dataset?sessionId=&name=&documentId=` [token, read] — SSE. Tracks the caller while open. Frames: `event: session` `{sessionId}` once, then `event: presence` `{presences:[{sessionId,name,color,documentId,field,client,selection?}]}` on connect and on every change (`?documentId=` narrows), `: keepalive` every 15 s. `name` defaults to the token label; omit `sessionId` and one is generated.
- `POST …/presence/:dataset/focus` `{sessionId, documentId, field, selection?}` [token, write] — moves that session's focus. `404` unless the stream is open and was opened by the same token. `selection` is the canvas `bp-canvas-selection` detail (`api/assets/paper-editor/EMBED-CONTRACT.md`): `{anchor, head}`, each `{blockId, path?, offset}`, or `null`. Omitted or `null` clears it; entries carry it only while set. Over 512 B of JSON is `413`, any other shape `422`. Same `presence_focus` rate class.

An entry leaves the room when its stream closes. A grant-admitted caller gets `403`.
