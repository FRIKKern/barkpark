---
'@barkpark/core': minor
---

Type the publish wall's advisory channel: `MutateEnvelope` gains an optional
`warnings?: MutateWarning[]` (`{code, severity: 'advisory', message}`) — emitted
by the API on successful mutates whose publishes trip a non-blocking authoring
advisory (e.g. the 2–4 tag-count norm). Purely additive; advisories never block
a write.
