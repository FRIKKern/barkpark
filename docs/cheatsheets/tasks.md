<!-- doc-tier: agent | canonical-for: tasks-cheatsheet | budget: 600tok -->
# tasks — cheatsheet

Tasks are `type:task` docs. Root task = goal; nest via `content.parent_id`. Create via mutate (admin); endpoints resolve bare ids (`drafts.` prefix = exact). All `/v1/tasks/*` routes bearer-token (read tier). Plugin must be on (`BARKPARK_PLUGINS` unset or contains `tasks`).

| bp | HTTP | Effect · example |
|---|---|---|
| `bp task ls` | `GET /v1/tasks` | list; filters `kind/lifecycle_status/phase_id/parent/label/limit` · `parent=` = child rail, oldest first |
| `bp task ready` | `GET /v1/tasks/ready` | unblocked queue, priority ASC then oldest · `bp task ready --limit 5` |
| `bp task prime` | `GET /v1/tasks/prime` | one-call rehydration: in-progress (`--worker W`), ready head, recent events, counts |
| `bp task get <id>` | `GET /v1/tasks/:id` | doc + one level of `children` inline |
| `bp task next <worker>` | `POST /v1/tasks/claim` | queue claim · no_ready if none |
| `bp task claim <id> <worker>` | `POST /v1/tasks/:id/claim` | targeted claim · ids via `bp task ready` |
| `bp task close <id> <worker> <epoch> [status]` | `POST /v1/tasks/:id/close` | close, CAS on the claim epoch |
| — | `POST /v1/tasks/claim` | queue claim body: `{"worker_id":"agent-1"}` |
| — | `GET /v1/tasks/:id/edges` | dependencies + dependents (`?kind=all`) |
| — | `POST /v1/tasks/edges` | `{"from_id":"t2","to_id":"t1"}` — t2 waits on t1 (kind default `blocks`) |
| — | `POST /v1/tasks/:id/labels` | `{"add":["sprint-3"],"remove":[]}` |
| — | `POST /v1/tasks/:id/papers` | link paper slugs: `{"add":["notes"]}` |

**Lifecycle:** `open · in_progress · blocked · done · cancelled`. Ready = open/blocked AND every `blocks` target `done`. Closing `done` auto-flips dependents blocked → open.

**Claim/close contract:** claim → `lifecycle_status=in_progress`, stamps `content.claim {worker, ts_iso, epoch}`; epoch bumps every claim. Close needs `worker_id` + `observed_epoch` (CAS — mismatch → 409 `fenced_off`; race → `stale_claim`); optional `lifecycle_status` done|cancelled|blocked (default done), `observed_rev`. Leases sweep after 300s (`task_lease_ttl_seconds`) → `task.lease_expired`.

**Events** (SSE `/v1/data/listen/:dataset`): `task.claimed/closed/mutated/relabeled/referenced/lease_expired`.

Guide: [`../setup/TASK-SYSTEM.md`](../setup/TASK-SYSTEM.md)
