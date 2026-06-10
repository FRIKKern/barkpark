<!-- doc-tier: human | canonical-for: task-system-guide | budget: 4000tok -->
# The Task System

Barkpark as your AI's task board: the agent claims work over HTTP, you steer the same queue in the browser Studio, and every change broadcasts to both sides in real time. Tasks are plain `type:task` documents — no second store, no sync. A root task is a **goal**; children nest under it; dependencies form a graph; claims are atomic and fenced so many workers can't trample each other.

## What you get

| Surface | What |
|---|---|
| **Studio Tasks pane** | A **Tasks ✅** desk group at `/studio` (plugin desk item), with lifecycle tabs (open · in_progress · blocked · closed · all). The editor is a full dossier in four groups — **brief** (description, design notes, an expandable `design_doc` paper reference, checkable acceptance criteria with met/evidence), **work** (priority, assignee, estimate, due date, labels), **close** (outcome, reason), **system** — plus soft validations (e.g. closing `done` without an outcome warns). `dependencies` and `claim` render read-only ("managed via API"). |
| **`bp` verbs** | `bp task ls / ready / get / next / claim / close` — manifest-driven from `GET /v1/capabilities`, provenance `plugin:tasks`. |
| **Terminal TUI** | Task lists carry quick actions: `c` claims the highlighted task, `x` closes it (same fenced endpoints; worker id from `BARKPARK_WORKER_ID`, default `tui-<hostname>`). Plus the standard desk keys — `/` search, `n` new, `y` duplicate, `D`×2 delete. |
| **HTTP API** | Ten bearer-token endpoints under `/v1/tasks/*` (read tier, not admin): list, ready-queue, queue claim, targeted claim, close, fetch-with-children, edges, labels, paper links. |
| **Events** | Every task op emits a `mutation_events` row — `task.claimed / task.closed / task.mutated / task.relabeled / task.referenced / task.lease_expired` — streamed over SSE at `/v1/data/listen/:dataset`. |

Lifecycle states: `open · in_progress · blocked · done · cancelled`.

## Set up from zero

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp            # no config + TTY → the setup wizard, then the TUI
```

The wizard's **clean profile pre-checks the `bulldocs` and `tasks` plugins** (the server unions `media` in on its own). Accept, and the task schema, routes, and cron workers are live on first boot. Already running a dev server on `:4000`? It blocks the local target's DB reset — stop it first, or pick **connect** instead.

**Existing installs** — enable via env and restart:

```bash
BARKPARK_PLUGINS=bulldocs,tasks    # CSV whitelist · unset = all plugins · empty = kill switch
```

- **Server (`deploy.sh` / `bp setup --target deploy`):** pass `BARKPARK_PLUGINS=bulldocs,tasks` in the deploy env — it persists into `/opt/barkpark/.env`, sourced by `api/start.sh` (the systemd unit's ExecStart).
- **Docker:** `docker-compose.yml` passes the variable through as a bare `- BARKPARK_PLUGINS` entry — export it in the invoking shell before `docker compose up`.
- **Local mix:** `BARKPARK_PLUGINS=bulldocs,tasks mix phx.server`.

The `task` schema auto-registers on every boot (idempotent on `(name, dataset)`); two Oban cron jobs come with it — a lease sweeper every minute and compaction every six hours.

## Point an AI agent at it

**1. Token.** Any bearer token works for the task endpoints (read tier — claim/close are workflow ops, not document mutations). Creating tasks goes through the mutate endpoint, which needs an admin token. Dev default: `barkpark-dev-token`.

**2. Discover.** One call teaches the whole surface:

```bash
bp capabilities -o json          # or: curl -H "Authorization: Bearer $TOKEN" $API/v1/capabilities
```

**3. Create tasks.** Tasks are documents — create them through the standard mutation envelope. Required content: `kind: "task"` and a valid `lifecycle_status`. Optional: `priority` (0–4, 0 = highest), `assignee`, `parent_id`, `labels`, `papers`, plus the dossier fields (`description`, `design`, `design_doc` paper slug, `acceptance_criteria` list, `estimate`, `due_at`, `outcome`, …) — the schema (`GET /v1/schemas/:dataset`, name `task`) is the authoritative field list.

```bash
curl -X POST $API/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"task","_id":"t1","title":"Ship the docs",
       "content":{"kind":"task","lifecycle_status":"open","priority":1}}}]}'
```

> **Draft prefix note:** `create` always lands as a draft (stored id `drafts.t1`). The task endpoints resolve the bare id `t1` automatically — you can use either `t1` or `drafts.t1`. If both a published `t1` and a draft `drafts.t1` exist, `t1` matches the published row (exact match wins). Task lifecycle is independent of draft/publish; publishing a task is optional.

**4. The claim → work → close loop.** Pick a stable `worker_id` per agent.

```bash
# Queue claim: atomically take the NEXT ready task (priority ASC, then oldest)
bp task next agent-1                # prints the claimed doc_id + epoch; no_ready on empty queue
curl -X POST $API/v1/tasks/claim \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"worker_id":"agent-1"}'
# → {"ok":true,"doc":{...,"claim":{"worker":"agent-1","ts_iso":"…","epoch":1}}}
# → {"ok":false,"reason":"no_ready"} when the queue is empty

# Targeted claim: name the row
bp task claim t1 agent-1            # args: <doc_id> <worker_id>

# ... do the work ...

# Close: CAS on the fencing epoch you were handed at claim time
bp task close t1 agent-1 1          # args: <doc_id> <worker_id> <observed_epoch> [lifecycle_status]
```

The contract, precisely:

- **Claim** flips `lifecycle_status` to `in_progress` and stamps `content.claim = {worker, ts_iso, epoch}`. The epoch bumps on **every** claim (losing a race → 409 `stale_claim`).
- **Close** requires `worker_id` + `observed_epoch` (string ints accepted). Epoch mismatch → 409 `fenced_off` — the only protection against a stale-but-alive worker writing after its lease was swept. Optional body: `lifecycle_status` (`done` | `cancelled` | `blocked`, default `done`) and `observed_rev`.
- **Leases expire.** A sweeper runs every minute; claims idle past `task_lease_ttl_seconds` (default **300**) are released and emit `task.lease_expired`. Finish or re-claim.
- **Ready** means: `lifecycle_status` ∈ {`open`, `blocked`} **and** every outbound `blocks` edge points at a `done` task. Closing a task `done` auto-flips dependents from `blocked` → `open` when their full blocker set is done.

**5. Dependencies, labels, papers.**

```bash
# t2 waits on t1 (from = dependent, to = blocker; kind defaults to "blocks")
curl -X POST $API/v1/tasks/edges -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"from_id":"drafts.t2","to_id":"drafts.t1"}'

curl $API/v1/tasks/drafts.t2/edges -H "Authorization: Bearer $TOKEN"   # ?kind=all for every edge kind

curl -X POST $API/v1/tasks/drafts.t1/labels -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"add":["sprint-3"],"remove":[]}'

# Link a paper (a Bulldocs doc) to a task — design notes travel with the work
curl -X POST $API/v1/tasks/drafts.t1/papers -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"add":["design-notes"]}'
```

**6. Filtered reads.**

```bash
bp task ready --limit 5                          # the unblocked queue
bp task ls --limit 20                            # everything, goals included
curl "$API/v1/tasks?lifecycle_status=open&label=sprint-3" -H "Authorization: Bearer $TOKEN"
curl "$API/v1/tasks?parent=drafts.g1" -H "Authorization: Bearer $TOKEN"   # a goal's rail, oldest first
```

Filters: `kind`, `lifecycle_status`, `phase_id`, `parent`, `label`, `type`, `limit` (index default 1000; `ready` and the bp verbs default 50).

**7. Watch the stream.** Subscribe to `/v1/data/listen/:dataset` (SSE) and react to `task.claimed`, `task.closed`, `task.lease_expired`, etc. — no polling.

## Working with your AI in Studio

Open `/studio` → the **Tasks ✅** group. The division of labour:

| You (Studio form) | The agent (API) |
|---|---|
| Flip `lifecycle_status` (5-state dropdown), set `priority`, `assignee`, edit titles/descriptions | `claim` / `close` with fencing, add edges, relabel, link papers |
| Triage: open new tasks, cancel dead ones | Drain the ready queue in priority order |

The terminal TUI edits the flat fields (title, description, lifecycle, priority, …) and carries the claim/close quick actions (`c` / `x` on a task list or in a task's editor — same fenced endpoints the agent uses); composite dossier fields like `acceptance_criteria` are Studio- and API-editable only (the documented v1 TUI constraint). `dependencies` and `claim` show as read-only pretty-printed JSON in the editor — round-tripping structured values through a text input would corrupt them, so the form simply never submits those fields and the API stays the single writer. Everything updates live via PubSub: when the agent claims a task, your pane reflects it without a refresh.

## Goals and phases

Everything is a task. The pattern:

- **Goal** = a root task (no `parent_id`).
- **Phase / subtask** = a task whose `content.parent_id` is the parent's doc id.
- **Rail** = a task's chronological children: `GET /v1/tasks?parent=<id>` (oldest first), and `GET /v1/tasks/:id` returns one level of `children` summaries inline (`doc_id`, `title`, `lifecycle_status`) plus `child_count`.
- Scope a worker to one phase: `POST /v1/tasks/claim` with `{"worker_id":"agent-1","phase_id":"<phase-doc-id>"}`, or `GET /v1/tasks/ready?phase_id=…`.

Goal → phases → leaf tasks, with `blocks` edges sequencing the phases, gives you a multi-phase project board in a standard Barkpark install.

## Workspaces, projects, datasets — experiment without mess

Spin up an isolated sandbox in one command; throw the whole thing away later. Any write-tier token may create a workspace — it arrives ready to use:

```bash
bp workspace create Spike
# → workspace + you as owner-member + a Default project + a production dataset
#   (slug derived from the name; explicit: --slug spike)

bp -w spike workspace project-create agents-v2    # member-gated; -w names the workspace
bp workspace ls                                   # what your token can reach
# Raw HTTP equivalents: POST /api/workspaces {"name":…} and
# POST /api/workspaces/:slug/projects {"name":…} — see docs/cheatsheets/http-api.md
```

Scoped Studio lives at `/w/:workspace_slug/p/:project_slug/studio`; scoped data routes mirror under the same prefix. The flat `/v1/tasks/*` surface operates on the server's default (unscoped) scope — under scoped pipelines, task reads and claims are strictly filtered by workspace + project. Membership is the boundary: non-members get 404, never an existence leak.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| No **Tasks** pane in Studio | Plugin not whitelisted (`BARKPARK_PLUGINS` set without `tasks`) **or** the `task` schema isn't registered in this dataset. Fix env, restart; the schema auto-registers on boot. |
| `404` on `/v1/tasks/*` | Plugin disabled — routes only mount when the tasks plugin is registered. |
| `404 task not found` on an id you just created | Rare — the endpoints resolve bare `t1` to `drafts.t1` automatically. Check that the task plugin is enabled and the token has access. |
| `400 worker_id is required` | Claim/close need `worker_id` — positional via bp (`bp task claim <id> <worker>`), JSON body via curl. |
| `409 fenced_off` | Your `observed_epoch` is stale — the lease was swept and re-claimed. Re-claim, then close with the new epoch. |
| `409 stale_claim` | Lost a concurrent claim race. Call `/v1/tasks/claim` again. |
| `409 not_ready` | Targeted claim on a task that is `in_progress`/`done`/`cancelled`. |
| `409 blocked_by_unsatisfied_deps` | Targeted claim while a `blocks` edge points at a non-`done` task. |
| `{"ok":false,"reason":"no_ready"}` | Not an error — the queue is empty (HTTP 200). |
| Task invisible in Studio but in API | Tenancy: the doc carries a different workspace/project scope than the Studio you're looking at. |

Cheatsheet: [`../cheatsheets/tasks.md`](../cheatsheets/tasks.md) · CLI canon: [`../cli/HANDBOOK.md`](../cli/HANDBOOK.md) · HTTP contract: [`../api-v1.md`](../api-v1.md)
