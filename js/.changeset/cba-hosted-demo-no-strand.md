---
"create-barkpark-app": patch
---

A failure while applying `--hosted-demo` settings no longer aborts the run and strands a complete scaffold behind the not-empty guard. The remedy is relieve, not delete: the failure is caught and said out loud with the two manual steps (remove the compose files, write `.env.local`), nothing is removed — the tree is finished, usable work — and the run continues through install, git and next steps, so there is nothing left to retry.
