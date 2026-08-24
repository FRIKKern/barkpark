<!-- doc-tier: human | canonical-for: task-system-guide | budget: 4000tok -->
# The Task System

Barkpark as your AI's task board: agents claim work over HTTP, you steer the queue in Studio, every change broadcasts live. Tasks are plain `type:task` docs — no second store; claims are atomic and fenced.

## What you get

| Surface | What |
|---|---|
| **Studio Tasks pane** | A **Tasks ✅** desk group at `/studio` with lifecycle tabs; editor = four-group dossier (brief · work · close · system); `dependencies`/`claim` read-only. |
| **`bp` verbs** | `bp task ls / ready / prime / events / get / next / claim / release / stamp / pulse / close / move` — manifest-driven. |
| **Terminal TUI** | `bp tasks` (= `bp task tui`) opens the reader; `c`/`x` claim/close (worker `BARKPARK_WORKER_ID`, default `tui-<hostname>`). Keys: [tui cheatsheet](../cheatsheets/tui.md). |
| **HTTP API** | Bearer endpoints under `/v1/tasks/*` (read tier): the verbs plus fetch, edges, labels, papers. |
| **Events** | Each op emits a `mutation_events` row — `task.{claimed,released,criterion,pulse,closed,mutated,relabeled,referenced,reparented,lease_expired,compacted,compaction_restored}`. **Push** SSE `/v1/data/listen/:dataset`; **pull** keyset feed `GET /v1/tasks/events?since=<id>` (§7). |

Lifecycle: `open · in_progress · blocked · done · cancelled`.

## Set up from zero

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp            # no config + TTY → the setup wizard, then the TUI
```

The wizard's **clean profile pre-checks `bulldocs` + `tasks`** (server unions `media`); accept and schema, routes and crons are live on first boot. A dev server on `:4000` blocks the local DB reset — stop it or pick **connect**.

**Existing installs** — enable via env and restart:

```bash
BARKPARK_PLUGINS=bulldocs,tasks    # CSV whitelist · unset = all plugins · empty = kill switch
```

The `task` schema auto-registers each boot (idempotent on `(name, dataset)`); two Oban crons ride along: lease sweeper, compaction (6 h).

## Point an AI agent at it

**1. Token.** Any bearer token works for the task endpoints (read tier); creating tasks uses the mutate endpoint (write tier). Dev default: `barkpark-dev-token`.

**2. Discover.** One call teaches the whole surface:

```bash
bp capabilities -o json          # or: curl -H "Authorization: Bearer $TOKEN" $API/v1/capabilities
```

**3. Create tasks.** Standard mutation envelope. Required content: `kind: "task"` + a valid `lifecycle_status`. Optional: `priority` (0–4, 0 = highest), `assignee`, `parent_id`, `labels`, `papers`, dossier fields (`brief`, `description`, `acceptance_criteria`, `purpose`, `estimate`, `due_at`, `outcome`, …); the `task` schema is authoritative. `brief` = the PortableDoc envelope (`{version: 1, blocks: [...]}`), `description` its text fallback. Author briefs as blocks, not a text wall.

```bash
curl -X POST $API/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"task","_id":"t1","title":"Ship the docs",
       "content":{"kind":"task","lifecycle_status":"open","priority":1}}}]}'
```

> **Draft prefix:** `create` lands as `drafts.t1`; the task endpoints resolve bare `t1` (published `t1` wins). Lifecycle is independent of draft/publish.

**4. Claim → stamp → close.** Use a stable `worker_id` per agent. Every prod write needs `--yes` — without it `bp` aborts with `prod write not confirmed` and sends nothing, so a batch script missing it no-ops every write.

```bash
# Queue claim: take the NEXT ready task (priority order)
bp task next agent-1                # prints doc_id + epoch; no_ready (HTTP 200, not an error) when the queue is empty

# Targeted claim: name the row
bp task claim t1 agent-1            # <doc_id> <worker_id>

# Voluntary walk-away (fenced)
bp task release t1 agent-1 1        # <doc_id> <worker> <epoch>

# Mid-claim: stamp a criterion — met or honestly missed
bp task stamp t1 agent-1 1 --criterion 0 --criterion-text "gate passes" --met --evidence "gate green"
bp task stamp t1 agent-1 1 --criterion 1 --miss --note "flaky under sandbox"

# ... pulse the now-line as you work (renews the lease)
bp task pulse t1 agent-1 --now "warm-up pinned, rerunning" --criterion 2

# Close (epoch-fenced)
bp task close t1 agent-1 1          # <doc_id> <worker> <epoch> [status] [reason]

# Close with evidence: flips ride the same rev-CAS — but a flip made HERE is not proof of itself.
bp task close t1 agent-1 1 --set 'criteria:=[{"index":0,"met":true,"evidence":"PR #123","criterion":"gate passes"}]'
```

The full contract — what each verb fences on, and every refusal it can emit —
is [the claim-lifecycle contract](../contracts/task-claim-lifecycle.md); how to
write the close receipt is [the close-packet convention](../contracts/close-packet.md).

**5. Dependencies, labels, papers.**

```bash
# t2 waits on t1 (from=dependent, to=blocker; kind defaults "blocks")
curl -X POST $API/v1/tasks/edges -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"from_id":"drafts.t2","to_id":"drafts.t1"}'

curl $API/v1/tasks/drafts.t2/edges -H "Authorization: Bearer $TOKEN"   # ?kind=all for every edge kind

curl -X POST $API/v1/tasks/drafts.t1/labels -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"add":["sprint-3"],"remove":[]}'
```

Paper links mirror labels: `POST /v1/tasks/:id/papers` `{"add":["design-notes"]}`.

**6. Filtered reads.**

```bash
bp task ready --limit 5 --offset 0     # deterministic queue page
bp task ready --all                    # aggregate pages; fail closed on repeat/cycle
bp task ls --limit 20                  # all tasks, goals included
```

Filters: `kind`, `label`, `lifecycle_status`, `parent`, `parent_id`, `phase_id`, `type`, `limit`, plus `offset` on `ready` and `ls` (floor 0). A misspelt key is a 400 `invalid_filter` naming the supported set, never a silent empty page. Order: priority/creation/UUID; `ls` order is total (updated_at DESC; with `parent`, inserted_at ASC; id tiebreak), pages disjoint; `--all` returns `pagination_stalled` on a repeated/cyclic full page.

**7. Watch the stream.** Both routes are in **What you get**. **Push:** SSE, `task.*`, no polling. **Pull:** `bp task events --since <id>` replays id-ASC, one page (≤500): `{ok, events:[{id,event,doc_id,rev,at}], cursor, has_more}`. `id` = the stable cursor (monotonic PK). Resume with the last `cursor` as `--since`; omit = from start, `has_more:true` → poll again. One `dataset` (default `production`), `type=task`.

## Task ↔ code linkage

Two optional content fields answer "what code is this task?" as a field read, not a git dig:

- **`code_refs`** = `{"prs":[int],"commits":["sha"],"branch":"name","worktree":"path-or-null"}` — PRs, merge commits, branch, and (in flight) the worktree path.
- **`last_worked_at`** = ISO timestamp of the newest attached code activity — unlike `updated_at`, which any edit bumps.

Stamp at three moments ([ledger rule 6](../../.claude/workflows/bp-loop-ledger.md)): **claim** sets `branch`+`worktree`, **PR-open** appends `prs`, **merge** appends the sha to `commits` and clears `worktree`→null; each bumps `last_worked_at`. Patch flat via `/v1/data/mutate` — a `patch` with `set` merging both fields into `content`. Leave a field absent when unknown; never fabricate a ref.

## The cmux bridge — a pane that owns its task

A cmux pane can auto-own its task. `bp cmux install --print` shows the four hooks + worker-id; `--merge --yes` folds them into `~/.claude/settings.json` (deduped, backup first). The worker is the *pane* (`cmux-<CMUX_SURFACE_ID>`), so subagents share one lease: with `BARKPARK_TASK=<doc_id>`, **SessionStart** claims, **PreToolUse** renews ≤1/60s, **Stop**/**SessionEnd** close IFF every criterion is met (published met-flips need a re-publish) — else LEAVE it claimed. Hooks exit 0 with empty stdout, so a dead server can't harm the agent (`bp cmux status`; auth in `~/.config/barkpark/`). No `uninstall` — remove hook groups by hand.

## Working with your AI in Studio

Open `/studio` → the **Tasks ✅** group. You (form) flip `lifecycle_status`/`priority`/`assignee` and edit titles/descriptions; the agent (API) claims/closes with fencing, adds edges, relabels, links papers. The TUI edits flat fields; composites (`acceptance_criteria`) are Studio/API-only — the API single-writes structured values. Live over PubSub.

The live board at **`/admin/projects`** (`:ops` admin-gated) is a kanban over the same docs: five realtime columns — open · ready · in_progress · blocked · done (cancelled → tally). **Drag** restages through the fenced `claim`/`close` primitives (foreign-held card refuses, as does a `done` drop over unmet criteria; `ready` is derived, no drop). **Group**/**filter** via chips in a shareable URL (`?group=&goal=&priority=&label=&worker=`).

## Goals and phases

Everything is a task. The pattern:

- **Goal** = a root task (no `parent_id`).
- **Phase / subtask** = a task whose `content.parent_id` is the parent's doc id.
- **Rail** = a task's chronological children: `GET /v1/tasks?parent=<id>` (oldest first); `GET /v1/tasks/:id` inlines one level of `children` summaries + `child_count`.
- Scope a worker to one phase: `POST /v1/tasks/claim` `{"worker_id":…,"phase_id":…}` or `GET /v1/tasks/ready?phase_id=…`.

### How to organize tasks (follow these when creating ANY task)

A scattered board is a defect — make every new task fit the structure:

1. **Every task belongs to a goal.** No floating orphans — give related tasks a goal parent (`parent_id`); nest goals under epics for bigger missions.
2. **Goals are MISSIONS, named as the outcome a human wants** — e.g. *"Sheets reaches Excel parity"* — never after provenance/process (`loop`, `cleanup`, `misc`) or a label.
3. **Group by ancestry** — tasks sharing a goal nest beneath it; the parent tree is the spine.
4. **Labels** (`content.labels`): `proj:<mission>` (required), `phase:<goal|design|decision|build|verify>`, `kind:<deferred|low|…>`, plus gates `needs-human`/`decision`/`security`.
5. **Real work tasks carry `acceptance_criteria`** — 1–3 concrete, checkable conditions that define done. Decisions and goals may omit them. Merge-gated criteria need `merge_gate:true` — a `landed` close auto-flips only the flag; wording alone just warns.
6. **Blockers are explicit** — `blocks` edges keep a gated task out of "ready"; one waiting on a human carries `needs-human`/`decision`.

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
| No **Tasks** pane in Studio | `BARKPARK_PLUGINS` set without `tasks`, or the `task` schema isn't registered. Fix env + restart; the schema auto-registers on boot. |
| `404` on `/v1/tasks/*` | Plugin disabled — the routes mount only when the tasks plugin is on. |
| `404 task not found` right after create | See **Draft prefix**; check plugin enabled + token access. |
| Task invisible in Studio but in API | Tenancy: the doc is scoped to a different workspace/project than this Studio. |


Claim/close refusals (`409 fenced_off`, `not_holder`, `criteria_unmet`, …) are in
[the claim-lifecycle contract](../contracts/task-claim-lifecycle.md).

Cheatsheet: [tasks](../cheatsheets/tasks.md) · CLI canon: [HANDBOOK](../cli/HANDBOOK.md) · HTTP contract: [api-v1](../api-v1.md)
