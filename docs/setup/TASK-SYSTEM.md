<!-- doc-tier: human | canonical-for: task-system-guide | budget: 4000tok -->
# The Task System

Barkpark as your AI's task board: agents claim work over HTTP, you steer the same queue in Studio, every change broadcasts live. Tasks are plain `type:task` documents — no second store. A root task is a **goal**; children nest; dependencies form a graph; claims are atomic and fenced.

## What you get

| Surface | What |
|---|---|
| **Studio Tasks pane** | A **Tasks ✅** desk group at `/studio` with lifecycle tabs; editor = four-group dossier (brief · work · close · system), soft validations, `dependencies`/`claim` read-only. Live **Projects board** at `/admin/projects`. |
| **`bp` verbs** | `bp task ls / ready / prime / events / get / next / claim / stamp / pulse / close / move` — manifest-driven from `GET /v1/capabilities`. |
| **Terminal TUI** | `c`/`x` claim/close the highlighted task (worker `BARKPARK_WORKER_ID`, default `tui-<hostname>`); desk keys: `/` search, `n` new, `y` duplicate, `D`×2 delete. |
| **HTTP API** | Fifteen bearer-token endpoints under `/v1/tasks/*` (read tier): the verbs above plus fetch, edges, labels, papers. |
| **Events** | Each op emits a `mutation_events` row — `task.{claimed,criterion,pulse,closed,mutated,relabeled,referenced,reparented,lease_expired,compacted,compaction_restored}`. **Push** SSE `/v1/data/listen/:dataset`; **pull** keyset feed `GET /v1/tasks/events?since=<id>` (§7). |

Lifecycle states: `open · in_progress · blocked · done · cancelled`.

## Set up from zero

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp            # no config + TTY → the setup wizard, then the TUI
```

The wizard's **clean profile pre-checks `bulldocs` + `tasks`** (server unions `media`); accept and the schema, routes, and crons are live on first boot. A dev server on `:4000` blocks the local DB reset — stop it or pick **connect**.

**Existing installs** — enable via env and restart:

```bash
BARKPARK_PLUGINS=bulldocs,tasks    # CSV whitelist · unset = all plugins · empty = kill switch
```

The `task` schema auto-registers each boot (idempotent on `(name, dataset)`); two Oban crons ride along: lease sweeper (1 min), compaction (6 h).

## Point an AI agent at it

**1. Token.** Any bearer token works for the task endpoints (read tier); creating tasks uses the mutate endpoint (write-tier token). Dev default: `barkpark-dev-token`.

**2. Discover.** One call teaches the whole surface:

```bash
bp capabilities -o json          # or: curl -H "Authorization: Bearer $TOKEN" $API/v1/capabilities
```

**3. Create tasks.** Via the standard mutation envelope. Required content: `kind: "task"` + a valid `lifecycle_status`. Optional: `priority` (0–4, 0 = highest), `assignee`, `parent_id`, `labels`, `papers`, plus dossier fields (`brief`, `description`, `acceptance_criteria`, `estimate`, `due_at`, `outcome`, …); the `task` schema is authoritative. `brief` is the canonical presentation-grade PortableDoc envelope (`{version: 1, blocks: [...]}`); `description` is its concise Markdown/text fallback for search, old clients, and text-only agents. Rich task authors should use PortableDoc headings, sections, lists, code, tables, diagrams, and callouts rather than packing an unstructured wall into `description`.

```bash
curl -X POST $API/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"task","_id":"t1","title":"Ship the docs",
       "content":{"kind":"task","lifecycle_status":"open","priority":1}}}]}'
```

> **Draft prefix:** `create` lands as `drafts.t1`; the task endpoints resolve bare `t1` (published `t1` wins). Lifecycle is independent of draft/publish.

**4. The claim → stamp → close loop.** Use a stable `worker_id` per agent.

```bash
# Queue claim: take the NEXT ready task (priority order)
bp task next agent-1                # prints doc_id + epoch; no_ready on empty queue

# Targeted claim: name the row
bp task claim t1 agent-1            # <doc_id> <worker_id>

# Mid-claim: stamp a criterion — met or honestly missed
bp task stamp t1 agent-1 1 --criterion 0 --met --evidence "gate green"
bp task stamp t1 agent-1 1 --criterion 1 --miss --note "flaky under sandbox"

# ... pulse the now-line as you work (renews the lease)
bp task pulse t1 agent-1 --now "warm-up pinned, rerunning" --criterion 2

# Close: CAS on the epoch handed at claim
bp task close t1 agent-1 1          # <doc_id> <worker> <epoch> [status] [reason]

# Close with evidence: flip criteria met/evidence ATOMICALLY with the close (same rev-CAS).
bp task close t1 agent-1 1 --set 'criteria:=[{"index":0,"met":true,"evidence":"PR #123"}]'
```

The contract, precisely:

- **Claim** flips `lifecycle_status` to `in_progress` + stamps `content.claim = {worker, ts_iso, epoch}`; the epoch bumps on every claim (race loss → 409 `stale_claim`).
- **Stamp (mid-claim)** — `POST /v1/tasks/:id/stamp`, holder-only + close's epoch fence. `--met` REQUIRES non-empty `--evidence`; `--miss` appends `{note,ts,worker}` to the criterion's `attempts` (5 kept), never flipping `met`. Emits `task.criterion`; stamps never trip the digest fence.
- **Pulse (heartbeat).** `POST /v1/tasks/:id/pulse` `{worker_id, now, criterion?}` atomically writes `claim.now = {text, ts, criterion?}` AND renews the lease (epoch + `ts_iso`); digest untouched; emits `task.pulse`. Holder-only, **no epoch arg** — survives L4 fences; a lost lease (reaped/released/closed) → 409 `not_holder`, never a re-claim. Boards render decay from `now.ts`.
- **Close** needs `worker_id` + `observed_epoch` (mismatch → 409 `fenced_off`). Body: `lifecycle_status` (`done`|`cancelled`|`blocked`, default `done`), `observed_rev`, `reason`, `criteria` — `{index, met, evidence, criterion}` merged into `acceptance_criteria` (rev-CAS; index/text mismatch → 409). Unmet criteria warn, never gate. Default fence: a claim-time **work digest** (title/PortableDoc brief/description/criterion text) — a brief edited under your claim → 409 `doc_changed_since_claim`; re-read or pass `observed_rev`. Self-edits (`code_refs`, `labels`, criteria progress) never trip.
- **Leases expire.** A per-minute sweeper releases claims idle past `task_lease_ttl_seconds` (default **2700**, env-tunable), emitting `task.lease_expired` (reap keeps `assignee`). Finish, pulse, or re-claim.
- **Ready** = `lifecycle_status` ∈ {`open`,`blocked`} AND every `blocks` edge points at a `done` task. Closing `done` auto-flips dependents `blocked`→`open` once their whole blocker set is done.
- **Criteria progress (advisory).** Envelopes (`get`/`ls`/`ready`/`prime`/children) carry `criteria_progress: {met, total}` — only `met:true` counts; omitted when absent (never `0/0`). A `done` close with unmet criteria warns but commits.
- **Rail awareness (advisory).** Claim/queue-claim/close carry `rail_rev` (ETag of the parent rail: children + `blocks` edges); prime carries `rails: {parent_id → rail_rev}`. `notices`: `blocked_while_claimed`, and `rail_changed` when body `observed_rail_rev` ≠ current. **Allow-and-fence (L4):** a blocker edge or `move` onto an `in_progress` task bumps its epoch (mutator never rejected); the holder's stale close → `fenced_off`, fixed by a same-worker re-claim (= renewal: epoch bump, digest kept).
- **Move (re-parent).** `POST /v1/tasks/:id/move` `{new_parent_id}` (null = root) flips `parent_id`, emits `task.reparented` `{from, to}`, returns `rail_rev` (dest) + `from_rail_rev`. Guards: bad parent → 409 `invalid_parent`; self/descendant → `cycle`; same-parent → no-op.

**5. Dependencies, labels, papers.**

```bash
# t2 waits on t1 (from=dependent, to=blocker; kind defaults "blocks")
curl -X POST $API/v1/tasks/edges -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"from_id":"drafts.t2","to_id":"drafts.t1"}'

curl $API/v1/tasks/drafts.t2/edges -H "Authorization: Bearer $TOKEN"   # ?kind=all for every edge kind

curl -X POST $API/v1/tasks/drafts.t1/labels -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"add":["sprint-3"],"remove":[]}'
```

Paper links (design notes travel with the work) mirror labels: `POST /v1/tasks/:id/papers` `{"add":["design-notes"]}`.

**6. Filtered reads.**

```bash
bp task ready --limit 5                          # the unblocked queue
bp task ls --limit 20                            # everything, goals included
curl "$API/v1/tasks?lifecycle_status=open&label=sprint-3" -H "Authorization: Bearer $TOKEN"
curl "$API/v1/tasks?parent=drafts.g1" -H "Authorization: Bearer $TOKEN"   # a goal's rail, oldest first
```

Filters: `kind`, `lifecycle_status`, `phase_id`, `parent`, `label`, `type`, `limit` (index default 1000; `ready` and the bp verbs default 50).

**7. Watch the stream.** **Push:** SSE `/v1/data/listen/:dataset` — `task.claimed`/`task.criterion`/`task.pulse`/…, no polling. **Pull:** `bp task events --since <id>` → `GET /v1/tasks/events?since=<id>` replays task events **id-ASC, one page** (≤500): `{ok, events:[{id,event,doc_id,rev,at}], cursor, has_more}`. `id` is the **stable cursor** (monotonic `mutation_events` PK, lossless under concurrent commits). Pass the last `cursor` back as `--since` to resume; omit to replay from the start; `has_more:true` → poll again. Scoped one `dataset` (`?dataset=`, default `production`) + `type=task`.

## Task ↔ code linkage

Two optional content fields answer "what code is this task?" as a field read, not a git dig:

- **`code_refs`** = `{"prs":[int],"commits":["sha"],"branch":"name","worktree":"path-or-null"}` — PRs, merge commits, branch, and (while in flight) the worktree path.
- **`last_worked_at`** = ISO timestamp of the newest attached code activity — distinct from `updated_at`, which any edit bumps.

Stamp at three moments ([ledger rule 6](../../.claude/workflows/bp-loop-ledger.md)): **claim** sets `branch`+`worktree`; **PR-open** appends `prs`; **merge** appends the sha to `commits` and clears `worktree`→null; both bump `last_worked_at`. Patch flat via `/v1/data/mutate` (`set` merges into `content`):

```bash
# {"patch":{"id":"drafts.t1","type":"task","set":{"code_refs":{"prs":[941],"branch":"feat/x","worktree":null},"last_worked_at":"2026-07-03T00:00:00Z"}}}
```

Leave a field absent when unknown, never fabricate a ref.

## The cmux bridge — a pane that owns its task

A cmux pane can auto-own its Barkpark task. `bp cmux install --print` shows the four Claude Code hooks (SessionStart · PreToolUse · Stop · SessionEnd, each running `bp cmux hook <event>`) plus the worker-id line; `bp cmux install --merge --yes` folds them into `~/.claude/settings.json` additively (deduped, backup first). The worker is the *pane* (`cmux-<CMUX_SURFACE_ID>`), so subagents share one fencing lease: with `BARKPARK_TASK=<doc_id>` set, **SessionStart** claims (re-claim = renewal), **PreToolUse** renews ≤1/60s, **Stop**/**SessionEnd** close IFF every criterion is met (published met-flips need a re-publish) — else LEAVE it claimed. Every hook exits 0 with empty stdout, so a dead server can't harm the agent (a breadcrumb `bp cmux status` surfaces; auth in `~/.config/barkpark/`). No `uninstall` verb — delete the hook groups by hand (the `--merge` backup undoes).

## Working with your AI in Studio

Open `/studio` → the **Tasks ✅** group. You (form) flip `lifecycle_status`, set `priority`/`assignee`, edit titles/descriptions; the agent (API) claims/closes with fencing, adds edges, relabels, links papers. The TUI edits flat fields (`c`/`x`); composite fields (`acceptance_criteria`) are Studio/API-only, `dependencies`/`claim` read-only — the API is the single writer for structured values. Live via PubSub.

The live board at **`/admin/projects`** (`:ops` admin-gated) is a kanban over the same docs: five realtime columns — open · ready · in_progress · blocked · done (cancelled → tally); a claim/close flashes and slides the card, no refresh. **Drag** restages through the fenced `claim`/`close` primitives (foreign-held card refuses the drop; `ready` is derived, not a drop target). **Group** into swimlanes and **filter** by chips, both saved in a shareable URL (`?group=&goal=&priority=&label=&worker=`).

## Goals and phases

Everything is a task. The pattern:

- **Goal** = a root task (no `parent_id`).
- **Phase / subtask** = a task whose `content.parent_id` is the parent's doc id.
- **Rail** = a task's chronological children: `GET /v1/tasks?parent=<id>` (oldest first); `GET /v1/tasks/:id` inlines one level of `children` summaries + `child_count`.
- Scope a worker to one phase: `POST /v1/tasks/claim` `{"worker_id":…,"phase_id":…}`, or `GET /v1/tasks/ready?phase_id=…`.

### How to organize tasks (the rules — follow these when creating ANY task)

A scattered board is a defect. When you add a task, make it fit the structure:

1. **Every task belongs to a goal.** Never a floating orphan — if related tasks lack a parent, create a goal and set their `parent_id`; nest goals under epics for bigger missions.
2. **Goals are MISSIONS, named as the outcome a human wants** — e.g. *"Sheets reaches Excel parity"*. Never name one after provenance/process (`loop`, `cleanup`, `misc`) or a label — the goal states the outcome.
3. **Combine tasks with the same goal beneath each other** — group by ancestry first; the parent tree is the spine.
4. **Labels** (`content.labels`): `proj:<mission>` (required), `phase:<goal|design|decision|build|verify>`, `kind:<deferred|low|…>`, plus gates `needs-human`/`decision`/`security`.
5. **Real work tasks carry `acceptance_criteria`** — 1–3 concrete, checkable conditions that define done. Decisions and goals may omit them.
6. **Blockers are explicit** — `blocks` edges keep a gated task out of "ready"; a task waiting on a human carries `needs-human`/`decision`.

## Workspaces, projects, datasets — experiment without mess

Any write-tier token spins up an isolated sandbox in one command (deleting a workspace is [deferred](../decisions/deferred.md); spikes are abandoned in place):

```bash
bp workspace create Spike     # → workspace + you as owner + a Default project + production dataset
bp -w spike workspace project-create agents-v2    # member-gated; -w names the workspace
bp workspace ls                                   # what your token can reach
```

Scoped Studio: `/w/:workspace_slug/p/:project_slug/studio`; scoped data routes mirror the prefix; flat `/v1/tasks/*` uses the server's default scope. Membership is the boundary: non-members get 404, never a leak.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| No **Tasks** pane in Studio | Plugin not whitelisted (`BARKPARK_PLUGINS` set without `tasks`) **or** the `task` schema isn't registered here. Fix env, restart; the schema auto-registers on boot. |
| `404` on `/v1/tasks/*` | Plugin disabled — the routes mount only when the tasks plugin is on. |
| `404 task not found` on an id you just created | Rare — bare `t1` resolves to `drafts.t1` automatically; check plugin enabled + token access. |
| `400 worker_id is required` | Claim/stamp/pulse/close need `worker_id` — positional via bp, JSON body via curl. |
| `409 fenced_off` | Stale `observed_epoch` — the lease was swept, **or a blocker/move landed on your claimed task** (L4 fence). Renew: `bp task claim <id> <same-worker>`, close with the new epoch. |
| `409 stale_claim` | Lost a concurrent claim race. Call `/v1/tasks/claim` again. |
| `409 doc_changed_since_claim` | The brief was edited under your claim. Re-read (`bp task get <id>`), close again, or pass `observed_rev`. |
| `409 not_ready` | Targeted claim on an `in_progress`/`done`/`cancelled` task (your OWN in_progress re-claim is a **renewal**, not an error). |
| `409 blocked_by_unsatisfied_deps` | Targeted claim while a `blocks` edge points at a non-`done` task. |
| `{"ok":false,"reason":"no_ready"}` | Not an error — the queue is empty (HTTP 200). |
| Task invisible in Studio but in API | Tenancy: the doc carries a different workspace/project scope than the Studio you're looking at. |

Cheatsheet: [`../cheatsheets/tasks.md`](../cheatsheets/tasks.md) · CLI canon: [`../cli/HANDBOOK.md`](../cli/HANDBOOK.md) · HTTP contract: [`../api-v1.md`](../api-v1.md)
