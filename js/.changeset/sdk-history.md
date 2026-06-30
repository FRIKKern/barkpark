---
'@barkpark/core': minor
---

Added document history / revisions to the SDK: `client.getHistory(type, id)` lists a document's past versions, `client.getRevision(revId)` fetches one with its content (null on 404), and `client.restoreRevision(revId, type)` writes a past version back as a draft. The server has had the history/revision API (`/v1/data/history/...`, `/v1/data/revision/...`) all along — Sanity-style version history — but the SDK exposed none of it. New types: `DocumentRevision`, `RestoreResult`, `HistoryOptions`, `RevisionOptions`.
