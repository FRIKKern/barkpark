<!-- doc-tier: human | canonical-for: task-system-guide | budget: 4000tok -->
# The Task System

Barkpark as your AI's task board: the agent claims work over HTTP, you steer the same queue in the browser Studio, and every change broadcasts to both sides in real time. Tasks are plain `type:task` documents — no second store, no sync. A root task is a **goal**; children nest under it; dependencies form a graph; claims are atomic and fenced so workers can't trample each other.

## What you get

| Surface | What |
|---|---|
| **Studio Tasks pane** | A **Tasks ✅** desk group at `/studio` with lifecycle tabs (open · in_progress · blocked · closed · all). The editor is a four-group dossier — **brief** (description, design notes, expandable `design_doc` reference, checkable acceptance criteria with met/evidence), **work** (priority, assignee, estimate, due date, labels), **close** (outcome, reason), **system** — plus soft validations (e.g. closing `done` without an outcome warns). `dependencies` and `claim` render read-only. |
| **`bp` verbs** | `bp task ls / ready / prime / get / next / claim / close` — manifest-driven from `GET /v1/capabilities`, provenance `plugin:tasks`. |
| **Terminal TUI** | Task lists carry quick actions: `c` claims the highlighted task, `x` closes it (same fenced endpoints; worker id from `BARKPARK_WORKER_ID`, default `tui-<hostname>`). Plus the standard desk keys — `/` search, `n` new, `y` duplicate, `D`×2 delete. |
| **HTTP API** | Eleven bearer-token endpoints under `/v1/tasks/*` (read tier, not admin): list, ready-queue, **prime** (one-call agent rehydration), queue claim, targeted claim, close, fetch-with-children, edges, labels, paper links. |
| **Events** | Every task op emits a `mutation_events` row — `task.claimed / task.closed / task.mutated / task.relabeled / task.referenced / task.lease_expired / task.compacted / task.compaction_restored` — streamed over SSE at `/v1/data/listen/:dataset`. |

Lifecycle states: `open · in_progress · blocked · done · cancelled`.

## Set up from zero

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp            # no config + TTY → the setup wizard, then the TUI
```

The wizard's **clean profile pre-checks `bulldocs` + `tasks`** (server unions `media`). Accept, and the task schema, routes, and cron workers are live on first boot. A dev server on `:4000` blocks the local DB reset — stop it, or pick **connect**.

**Existing installs** — enable via env and restart:

```bash
BARKPARK_PLUGINS=bulldocs,tasks    # CSV whitelist · unset = all plugins · empty = kill switch
```

Set it in the deploy env (persists to `/opt/barkpark/.env`), export it before `docker compose up`, or prefix `mix phx.server`.

The `task` schema auto-registers each boot (idempotent on `(name, dataset)`); two Oban crons ride along — a lease sweeper (1 min) and compaction (6 h).

## Point an AI agent at it

**1. Token.** Any bearer token works for the task endpoints (read tier — claim/close are workflow ops, not document mutations). Creating tasks goes through the mutate endpoint, which needs a write-tier token ("write" or "admin" permission). Dev default: `barkpark-dev-token`.

**2. Discover.** One call teaches the whole surface:

```bash
bp capabilities -o json          # or: curl -H "Authorization: Bearer $TOKEN" $API/v1/capabilities
```

**3. Create tasks.** Create them through the standard mutation envelope. Required content: `kind: "task"` + a valid `lifecycle_status`. Optional: `priority` (0–4, 0 = highest), `assignee`, `parent_id`, `labels`, `papers`, plus dossier fields (`description`, `design`, `design_doc` slug, `acceptance_criteria`, `estimate`, `due_at`, `outcome`, …); the schema (`GET /v1/schemas/:dataset`, name `task`) is the authoritative field list.

```bash
curl -X POST $API/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"task","_id":"t1","title":"Ship the docs",
       "content":{"kind":"task","lifecycle_status":"open","priority":1}}}]}'
```

> **Draft prefix note:** `create` always lands as a draft (stored id `drafts.t1`), but the task endpoints resolve the bare `t1` automatically — use either. If both a published `t1` and a draft `drafts.t1` exist, `t1` matches the published row (exact wins). Task lifecycle is independent of draft/publish; publishing is optional.

**4. The claim → work → close loop.** Pick a stable `worker_id` per agent.

```bash
# Queue claim: atomically take the NEXT ready task (priority ASC, then oldest)
bp task next agent-1                # prints the claimed doc_id + epoch; no_ready on empty queue
curl -X POST $API/v1/tasks/claim \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"worker_id":"agent-1"}'
# → {"ok":true,"doc":{...,"claim":{"worker":"agent-1","ts_iso":"…","epoch":1}}}
# → {"ok":false,"reason":"no_ready"} when empty

# Targeted claim: name the row
bp task claim t1 agent-1            # <doc_id> <worker_id>

# ... do the work ...

# Close: CAS on the fencing epoch handed at claim
bp task close t1 agent-1 1          # <doc_id> <worker> <epoch> [status] [reason]

# Close with evidence: flip criteria met/evidence ATOMICALLY with the close (same rev-CAS).
bp task close t1 agent-1 1 --set 'criteria:=[{"index":0,"met":true,"evidence":"PR #123"}]'
```

The contract, precisely:

- **Claim** flips `lifecycle_status` to `in_progress` + stamps `content.claim = {worker, ts_iso, epoch}`; the epoch bumps on every claim (race loss → 409 `stale_claim`).
- **Close** requires `worker_id` + `observed_epoch`. Epoch mismatch → 409 `fenced_off` (swept-but-alive worker guard). Optional body: `lifecycle_status` (`done`|`cancelled`|`blocked`, default `done`), `observed_rev`, `reason`, and `criteria` — `{index, met, evidence, criterion}` merged into `acceptance_criteria` in the flip's rev-CAS write (criterion text never rewritten; a text/index mismatch → 409, aborting the close). Unmet criteria only warn (see **Criteria progress**), never gate. Close also fences by default on a claim-time **work digest** of `title`/`description`/`acceptance_criteria`: a brief edited under your claim → 409 `doc_changed_since_claim` (with `current_rev` + `changed_fields`); re-read and retry, or pass `observed_rev` to bypass. `code_refs`/`labels` edits never trip it.
- **Leases expire.** A per-minute sweeper releases claims idle past `task_lease_ttl_seconds` (default **300**), emitting `task.lease_expired`. Finish or re-claim.
- **Ready** = `lifecycle_status` ∈ {`open`,`blocked`} AND every `blocks` edge points at a `done` task. Closing `done` auto-flips dependents `blocked`→`open` once their whole blocker set is done.
- **Criteria progress (advisory).** Envelopes (`get`/`ls`/`ready`/`prime`/children) carry `criteria_progress: {met, total}` over `acceptance_criteria` — only `met:true` counts; omitted when absent (never `0/0`). A `done` close with unmet criteria warns but still commits. Owner: `Barkpark.Tasks.Criteria.progress/1` (`@canonical capability:task-criteria-progress`).

**5. Dependencies, labels, papers.**

```bash
# t2 waits on t1 (from=dependent, to=blocker; kind defaults "blocks")
curl -X POST $API/v1/tasks/edges -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"from_id":"drafts.t2","to_id":"drafts.t1"}'

curl $API/v1/tasks/drafts.t2/edges -H "Authorization: Bearer $TOKEN"   # ?kind=all for every edge kind

curl -X POST $API/v1/tasks/drafts.t1/labels -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"add":["sprint-3"],"remove":[]}'

# Link a paper (Bulldocs doc) to a task — design notes travel with the work
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

## Task ↔ code linkage

Tasks carry machine-readable provenance so "what code is this task?" is a field read, not a git-archaeology dig. Two optional content fields:

- **`code_refs`** = `{"prs":[int], "commits":["sha"], "branch":"name", "worktree":"path-or-null"}` — the PRs, merge commits, git branch, and (while in flight) the worktree path for the task's work.
- **`last_worked_at`** = ISO timestamp of the newest attached code activity (a PR merge / commit date) — distinct from `updated_at`, which any metadata edit bumps.

Stamp at three moments (see [ledger process rule 6](../../.claude/workflows/bp-loop-ledger.md)): at **claim** set `branch` + `worktree`; at **PR-open** append to `prs` + bump `last_worked_at`; at **merge** append the sha to `commits`, bump `last_worked_at`, and **clear `worktree` → null**. Patch flat into content:

```bash
curl -X POST $API/v1/data/mutate/production -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"mutations":[{"patch":{"id":"drafts.t1",
    "type":"task","set":{"code_refs":{"prs":[941],"commits":[],"branch":"feat/x",
    "worktree":null},"last_worked_at":"2026-07-03T00:00:00Z"}}}]}'
```

`set` keys merge flat into `content` (no dotted paths). Honesty rule: leave a field **absent** when unknown — absent means "not yet linked", never fabricate a ref.

## Working with your AI in Studio

Open `/studio` → the **Tasks ✅** group. The division of labour:

| You (Studio form) | The agent (API) |
|---|---|
| Flip `lifecycle_status` (5-state dropdown), set `priority`, `assignee`, edit titles/descriptions | `claim` / `close` with fencing, add edges, relabel, link papers |
| Triage: open new tasks, cancel dead ones | Drain the ready queue in priority order |

The terminal TUI edits the flat fields (title, description, lifecycle, priority, …) and carries the claim/close quick actions (`c` / `x`, same fenced endpoints the agent uses); composite fields like `acceptance_criteria` are Studio/API-editable only. `dependencies` and `claim` render read-only in the editor — the form never submits them, so the API stays the single writer for structured values. Everything updates live via PubSub: an agent's claim shows in your pane without a refresh.

## Goals and phases

Everything is a task. The pattern:

- **Goal** = a root task (no `parent_id`).
- **Phase / subtask** = a task whose `content.parent_id` is the parent's doc id.
- **Rail** = a task's chronological children: `GET /v1/tasks?parent=<id>` (oldest first); `GET /v1/tasks/:id` also inlines one level of `children` summaries + `child_count`.
- Scope a worker to one phase: `POST /v1/tasks/claim` `{"worker_id":…,"phase_id":…}`, or `GET /v1/tasks/ready?phase_id=…`.

Goal → phases → leaf tasks, with `blocks` edges sequencing phases, is a multi-phase project board in a standard Barkpark install.

### How to organize tasks (the rules — follow these when creating ANY task)

Tasks are first-class in Barkpark; a scattered board is a defect. When you add a task, make it fit the structure:

1. **Every task belongs to a goal.** A task either HAS subtasks or IS one — never a floating orphan. If related tasks have no binding parent, create a goal and set their `parent_id` to it; nest that goal under a larger goal (epic) where a bigger mission exists.
2. **Goals are MISSIONS, named as the outcome a human wants** — e.g. *"Sheets reaches Excel parity"*, *"Every outbound email is delivered and observable"*. Never name a goal after provenance/process (`loop`, `cleanup`, `misc`) or after a label. A shared tag is a facet; the goal states the shared outcome.
3. **Combine tasks with the same goal beneath each other** — group by ancestry first; the parent tree is the spine. Labels are secondary facets, never the structure.
4. **Labels** (`content.labels`): `proj:<mission>` (required), `phase:<goal|design|decision|build|verify>`, `kind:<deferred|low|…>`, and flags `needs-human`/`decision`/`security` where they gate the work.
5. **Real work tasks carry `acceptance_criteria`** — 1–3 concrete, checkable conditions that define done. Decisions and goals may omit them.
6. **Blockers are explicit** — `blocks` edges keep a gated task out of "ready"; a task waiting on a human carries `needs-human`/`decision`. The board reads these to show what stopped a goal.

A well-formed board reads as *missions, and what each is made of* — so anyone sees what is being worked, what is blocked, and why.

## Workspaces, projects, datasets — experiment without mess

Spin up an isolated sandbox in one command, fully isolated from your real work (deleting a whole workspace is [deferred](../decisions/deferred.md); today spikes are abandoned in place, never leaked). Any write-tier token may create a workspace — it arrives ready to use:

```bash
bp workspace create Spike
# → workspace + you as owner-member + a Default project + a production dataset
#   (slug derived from the name; explicit: --slug spike)

bp -w spike workspace project-create agents-v2    # member-gated; -w names the workspace
bp workspace ls                                   # what your token can reach
# Raw HTTP equivalents: POST /api/workspaces {"name":…} and
# POST /api/workspaces/:slug/projects {"name":…} — see docs/cheatsheets/http-api.md
```

Scoped Studio lives at `/w/:workspace_slug/p/:project_slug/studio`; scoped data routes mirror under the same prefix. The flat `/v1/tasks/*` surface operates on the server's default (unscoped) scope — under scoped pipelines, task reads and claims are strictly filtered by workspace + project. Membership is the boundary: non-members get 404, never a leak.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| No **Tasks** pane in Studio | Plugin not whitelisted (`BARKPARK_PLUGINS` set without `tasks`) **or** the `task` schema isn't registered in this dataset. Fix env, restart; the schema auto-registers on boot. |
| `404` on `/v1/tasks/*` | Plugin disabled — routes only mount when the tasks plugin is registered. |
| `404 task not found` on an id you just created | Rare — the endpoints resolve bare `t1` to `drafts.t1` automatically. Check that the task plugin is enabled and the token has access. |
| `400 worker_id is required` | Claim/close need `worker_id` — positional via bp (`bp task claim <id> <worker>`), JSON body via curl. |
| `409 fenced_off` | Your `observed_epoch` is stale — the lease was swept and re-claimed. Re-claim, then close with the new epoch. |
| `409 stale_claim` | Lost a concurrent claim race. Call `/v1/tasks/claim` again. |
| `409 doc_changed_since_claim` | The brief was edited under your claim. Re-read (`bp task get <id>`) then close again, or pass `observed_rev` for strict rev fencing. |
| `409 not_ready` | Targeted claim on a task that is `in_progress`/`done`/`cancelled`. |
| `409 blocked_by_unsatisfied_deps` | Targeted claim while a `blocks` edge points at a non-`done` task. |
| `{"ok":false,"reason":"no_ready"}` | Not an error — the queue is empty (HTTP 200). |
| Task invisible in Studio but in API | Tenancy: the doc carries a different workspace/project scope than the Studio you're looking at. |

Cheatsheet: [`../cheatsheets/tasks.md`](../cheatsheets/tasks.md) · CLI canon: [`../cli/HANDBOOK.md`](../cli/HANDBOOK.md) · HTTP contract: [`../api-v1.md`](../api-v1.md)
