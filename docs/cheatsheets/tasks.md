<!-- doc-tier: agent | canonical-for: tasks-cheatsheet | budget: 600tok -->
# tasks — cheatsheet

Tasks are `type:task` docs. Root task = goal; nest via `content.parent_id`. Create via mutate (write/admin token); endpoints resolve bare ids (`drafts.` prefix = exact). All `/v1/tasks/*` routes bearer-token (read tier). Plugin must be on (`BARKPARK_PLUGINS` unset or contains `tasks`).

| bp | HTTP | Effect · example |
|---|---|---|
| `bp task ls` | `GET /v1/tasks` | list; filters `kind/lifecycle_status/phase_id/parent/label` · `parent=` = child rail |
| `bp task ready` | `GET /v1/tasks/ready` | claimable, priority ASC |
| `bp task prime` | `GET /v1/tasks/prime` | one-call rehydration: in-progress (`--worker W`) + ready head + events + counts |
| `bp task get <id>` | `GET /v1/tasks/:id` | doc + one level of `children` inline |
| `bp task next <worker>` | `POST /v1/tasks/claim` | queue claim · no_ready if none |
| `bp task claim <id> <worker>` | `POST /v1/tasks/:id/claim` | targeted · `--resources a.go,b.go` fences files: 409 `resource_conflict` names holders; freed on close/sweep |
| `bp task close <id> <worker> <epoch> [status] [reason]` | `POST /v1/tasks/:id/close` | close, CAS on epoch; reason → `close_reason` |
| — | `GET /v1/tasks/:id/edges` | dependencies + dependents (`?kind=all`) |
| — | `POST /v1/tasks/edges` | `{"from_id":"t2","to_id":"t1"}` — t2 waits on t1 |
| — | `POST /v1/tasks/:id/labels` | `{"add":["sprint-3"],"remove":[]}` |
| — | `POST /v1/tasks/:id/papers` | link paper slugs: `{"add":["notes"]}` |

**Lifecycle:** `open · in_progress · blocked · done · cancelled`. Ready = open/blocked, `blocks` targets `done`, drafts unless twinned. Closing `done` unblocks dependents.

**Claim/close contract:** claim → `lifecycle_status=in_progress`, stamps `content.claim {worker, ts_iso, epoch}`; epoch bumps every claim. Close needs `worker_id` + `observed_epoch` (CAS; mismatch → 409 `fenced_off`; race → `stale_claim`); optional `lifecycle_status` done|cancelled|blocked (default done), `observed_rev`. Leases sweep after 2700s (`task_lease_ttl_seconds`) → `task.lease_expired`.

**Events** (SSE `/v1/data/listen/:dataset`): `task.claimed/closed/mutated/relabeled/referenced/lease_expired/task.compacted/task.compaction_restored` (compaction job, not lifecycle transitions).

Guide: [`../setup/TASK-SYSTEM.md`](../setup/TASK-SYSTEM.md)
