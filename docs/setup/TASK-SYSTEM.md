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

The wizard's **clean profile pre-checks `bulldocs` + `tasks`** (server unions `media`); accept and schema, routes and crons go live on first boot. A dev server on `:4000` blocks the local DB reset — stop it or pick **connect**.

**Existing installs** — enable via env and restart:

```bash
BARKPARK_PLUGINS=bulldocs,tasks    # CSV whitelist · unset = all plugins · empty = kill switch
```

The `task` schema auto-registers each boot (idempotent on `(name, dataset)`); two Oban crons ride along: lease sweeper, compaction (6 h).

## Point an AI agent at it

**Register the movement.** Every unit of work runs under a claimed task: if no row names it, create one and claim it FIRST, then work. The doctrine, why unregistered work is unrecoverable, and the three ways a registration silently does not land: [AGENT-ONRAMPS](AGENT-ONRAMPS.md#register-the-movement); in this repo it also gates merge ([merge-gates](../ops/merge-gates.md)).

**1. Token.** Any bearer token works for the task endpoints (read tier); creating tasks uses the mutate endpoint (write tier). Dev default: `barkpark-dev-token`. A stale `BARKPARK_TOKEN` SHADOWS `~/.config/barkpark/config.json`: `bp whoami` reads `auth_tier: none` and every `bp task` verb says *hidden at your tier* — `unset BARKPARK_TOKEN` (or `env -u BARKPARK_TOKEN bp …`) before blaming the server.

**2. Discover.** One call teaches the whole surface:

```bash
bp capabilities -o json          # or: curl -H "Authorization: Bearer $TOKEN" $API/v1/capabilities
```

**3. Create tasks.** Standard mutation envelope. Required content: `kind: "task"` + a valid `lifecycle_status`. Optional: `priority` (0–4, 0 = highest), `assignee`, `parent_id`, `labels`, `papers`, dossier fields (`brief`, `description`, `acceptance_criteria`, `purpose`, `estimate`, `due_at`, `outcome`, …) — the `task` schema is authoritative. `brief` = the PortableDoc envelope (`{version: 1, blocks: [...]}`), `description` its text fallback; author briefs as blocks, not a text wall. `bp task create "<title>" --yes` files a draft; `--publish` also needs `--description` (20+ chars) and 1–12 tags already registered as `type:tag` docs (`bp doc ls tag --all`) — an invented tag is refused before anything is created.

```bash
curl -X POST $API/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"task","_id":"t1","title":"Ship the docs",
       "content":{"kind":"task","lifecycle_status":"open","priority":1}}}]}'
```

> **Draft prefix:** `create` lands as `drafts.t1`; the task endpoints resolve bare `t1` (published `t1` wins). That is *resolution*, not *listing*: an unpaired `drafts.<id>` task IS listed as itself; only a draft with a published twin is collapsed into it. Lifecycle is independent of draft/publish. `bp doc patch` (like `create --set`) writes the DRAFT: the published row — the one boards and `bp task get` read — does not change until `bp doc publish task <id> --yes`.

**4. Claim → stamp → close.** Use a stable `worker_id` per agent. Every prod write — `create`, `claim`, `pulse`, `stamp`, `release`, `close`, `doc patch`/`publish` — needs `--yes`; without it `bp` aborts (`prod write not confirmed`) and sends nothing, so a batch script missing it no-ops every write. Reading a row back: in `bp task get <id> -o json` criteria sit under `doc.content.acceptance_criteria`, the lease under `doc.claim` — a reader walking the top level sees an empty row.

```bash
# Queue claim: take the NEXT ready task (priority order)
bp task next agent-1                # prints doc_id + epoch; no_ready (HTTP 200, not an error) when the queue is empty

# Targeted claim: name the row
bp task claim t1 agent-1            # <doc_id> <worker_id>

# Voluntary walk-away (fenced)
bp task release t1 agent-1 1        # <doc_id> <worker> <epoch>

# Mid-claim: stamp a criterion — met, honestly missed, or WITHDRAWN (--criterion N is ZERO-based: 0 = the first)
bp task stamp t1 agent-1 1 --criterion 0 --criterion-text "gate passes" --met --evidence "gate green"
bp task stamp t1 agent-1 1 --criterion 1 --miss --note "flaky under sandbox"
bp task stamp t1 agent-1 1 --criterion 0 --criterion-text "gate passes" --withdraw --note "review: the gate ran on the wrong branch"

# ... pulse the now-line as you work (renews the lease)
bp task pulse t1 agent-1 --now "warm-up pinned, rerunning" --criterion 2

# Close (epoch-fenced)
bp task close t1 agent-1 1          # <doc_id> <worker> <epoch> [status] [reason]

# Close with evidence: flips ride the same rev-CAS — but a flip made HERE is not proof of itself.
bp task close t1 agent-1 1 --set 'criteria:=[{"index":0,"met":true,"evidence":"PR #123","criterion":"gate passes"}]'
```

**Withdrawing a proof.** `--withdraw` is the only verb that LOWERS a met flag —
review usually refutes a proof *after* the close. It sets `met: false`, leaves
the original evidence exactly where it was, and appends a signed withdrawal
record; a bare `met:true → met:false` patch is refused everywhere.

**Lease + epoch.** A claim is a **45 min** lease (`:task_lease_ttl_seconds`, 2700 s) that `claim`/`next`/`pulse` print. Every pulse renews it **and** bumps `claim.epoch` — pass the pulse's epoch, not the claim's, to `stamp`/`close`.

The full contract — what each verb fences on, every refusal it can emit (`409
fenced_off`, `not_holder`, `criteria_unmet`, …), and the
withdrawal's sealed-row rules — is [the claim-lifecycle
contract](../contracts/task-claim-lifecycle.md); how to write the close receipt
is [the close-packet convention](../contracts/close-packet.md).

**5. Dependencies, labels, papers.** Same bearer + JSON headers as the mutate call above:

```bash
POST /v1/tasks/edges              {"from_id":"drafts.t2","to_id":"drafts.t1"}  # t2 waits on t1 (from=dependent, to=blocker; kind defaults "blocks")
GET  /v1/tasks/drafts.t2/edges                                                 # ?kind=all for every edge kind
POST /v1/tasks/drafts.t1/labels   {"add":["sprint-3"],"remove":[]}
POST /v1/tasks/drafts.t1/papers   {"add":["design-notes"]}
```

**6. Filtered reads.**

```bash
bp task ready --limit 5 --offset 0     # deterministic queue page
bp task ready --all                    # aggregate pages
bp task ls --limit 20                  # all tasks, goals included
```

Filters: `kind`, `label`, `lifecycle_status`, `parent`, `parent_id`, `phase_id`, `type`, `limit`, plus `offset` on `ready` and `ls` (floor 0). **Never cap paging at a round number** — a run stopped at offset 3000 read its cap as the end; the set held 7,652. A misspelt key is a 400 `invalid_filter` naming the supported set, never a silent empty page. Order: priority/creation/UUID; `ls` order is total (updated_at DESC; with `parent`, inserted_at ASC; id tiebreak), pages disjoint; `--all` returns `pagination_stalled` on a repeated/cyclic full page.

**7. Watch the stream.** Both routes are in **What you get**. **Push:** SSE, `task.*`, no polling. **Pull:** `bp task events --since <id>` replays id-ASC, one page (≤500): `{ok, events:[{id,event,doc_id,rev,at}], cursor, has_more}`. `id` = the stable cursor (monotonic PK). Resume with the last `cursor` as `--since`; omit = from start, `has_more:true` → poll again. One `dataset` (default `production`), `type=task`.

## Task ↔ code linkage

Two optional content fields answer "what code is this task?" as a field read, not a git dig:

- **`code_refs`** = `{"prs":[int],"commits":["sha"],"branch":"name","worktree":"path-or-null"}` — PRs, merge commits, branch, and (in flight) the worktree path.
- **`last_worked_at`** = ISO timestamp of the newest attached code activity — unlike `updated_at`, which any edit bumps.

Stamp at three moments ([ledger rule 6](../../.claude/workflows/bp-loop-ledger.md)): **claim** sets `branch`+`worktree`, **PR-open** appends `prs`, **merge** appends the sha to `commits` and clears `worktree`→null; each bumps `last_worked_at`. Patch flat via `/v1/data/mutate` — a `patch` with `set` merging both fields into `content`. Leave a field absent when unknown; never fabricate a ref.

## PR ↔ task contract — one trailer, one live claim

`.github/workflows/pr-task-gate.yml` runs `scripts/pr-task-gate.sh` as the REQUIRED check "PR references an active task" on `opened`, `synchronize`, `reopened` and `edited`. Three rules a green PR obeys:

- **Exactly one `Task: <doc_id>` at column 0** of the PR body. Two DISTINCT ids make `extract_task_id` exit 4 (ambiguous) and the check reds. A PR landing several rows keeps ONE `Task:` and lists the rest as `Also-closes: <doc_id>`, closed by hand. Repeating one id is fine; ids are deduplicated.
- **The claim is read when the gate RUNS, not when the PR opened.** Pass = the row is `in_progress` with a `claim.worker`, `done` with a `claim.closed_by`, or `open` with a claim live at the PR's `created_at`. Never claimed, lapsed BEFORE the PR opened, cancelled, or wrong worker = fail. Hold the claim until the PR MERGES — pulse every ~18 min (bumps the epoch; re-read before stamp/close), or let CI call `task.renew` (`POST /v1/tasks/:doc_id/renew {"pr":<n>}`): a non-holder, self-expiring lease window the sweeper honours with epoch/worker/`ts_iso` untouched, so a CI queue longer than the 45-min lease stops redding this gate.
- **A body-caused red is fixed by editing the body**, not by pushing a commit — `edited` re-triggers the workflow. Exit 2 (ledger down) and 3 (credential refused) are the workflow's, not yours: re-run once the ledger is up.

## The cmux bridge — a pane that owns its task

A cmux pane can auto-own its task. `bp cmux install --print` shows the four hooks + worker-id; `--merge --yes` folds them into `~/.claude/settings.json` (deduped, backup first). The worker is the *pane* (`cmux-<CMUX_SURFACE_ID>`), so subagents share one lease: with `BARKPARK_TASK=<doc_id>`, **SessionStart** claims, **PreToolUse** **pulses** ≤1/60s (holder-only renew; now-line from `tool_name` + cwd basename, never the transcript; a lost lease answers `not_holder`, never a re-claim), **Stop**/**SessionEnd** close on the epoch pulse stamped (re-claiming only if that stamp is stale) IFF every criterion is met (published met-flips need a re-publish) — else LEAVE it claimed. Hooks exit 0 with empty stdout, so a dead server can't harm the agent (`bp cmux status`; auth in `~/.config/barkpark/`). No `uninstall` — remove hook groups by hand.

## Working with your AI in Studio

In `/studio` → **Tasks ✅**: you (form) flip `lifecycle_status`/`priority`/`assignee` and edit titles/descriptions; the agent (API) claims/closes with fencing, adds edges, relabels, links papers. The TUI edits flat fields; composites (`acceptance_criteria`) are Studio/API-only — the API single-writes structured values. Live over PubSub.

**`/admin/projects`** (`:ops` admin-gated) is a live kanban over the same docs: five realtime columns — open · ready · in_progress · blocked · done (cancelled → tally). **Drag** restages through the fenced `claim`/`close` primitives (a foreign-held card refuses, as does a `done` drop over unmet criteria; `ready` is derived, no drop). **Group**/**filter** via chips in a shareable URL (`?group=&goal=&priority=&label=&worker=`).

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
5. **Real work tasks carry `acceptance_criteria`** — 1–3 checkable conditions that define done. **State a CHECK TO RE-RUN, not a predicted state** — "X is in state Y" has a shelf life and nothing re-checks it. Decisions and goals may omit them; a row with none closes `done` only if `close_reason` names the PR + sha or pastes the run. Merge gates need `merge_gate:true` — a `landed` close flips only the flag; wording alone warns.
6. **Blockers are explicit** — `blocks` edges keep a gated task out of "ready"; one waiting on a human carries `needs-human`/`decision`.

## Workspaces, projects, datasets — experiment without mess

Any write-tier token spins up an isolated sandbox in one command (deleting a workspace is [deferred](../decisions/deferred.md); spikes are abandoned in place):

```bash
bp workspace create Spike     # → workspace + you as owner + a Default project + production dataset
bp -w spike workspace project-create agents-v2  # member-gated; -w names the workspace
bp workspace ls                                 # what your token can reach
```

Scoped Studio: `/w/:workspace_slug/p/:project_slug/studio`; scoped data routes mirror the prefix; flat `/v1/tasks/*` uses the server's default scope. Membership is the boundary: non-members get 404, never a leak.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| No **Tasks** pane in Studio, or `404` on `/v1/tasks/*` | Plugin off — pane and routes mount only when `tasks` is on: `BARKPARK_PLUGINS` set without it, or the `task` schema isn't registered. Fix env + restart; the schema auto-registers on boot. |
| `404 task not found` right after create | See **Draft prefix**; check plugin enabled + token access. |
| Task invisible in Studio but in API | Tenancy: the doc is scoped to a different workspace/project than this Studio. |

Cheatsheet: [tasks](../cheatsheets/tasks.md) · CLI canon: [HANDBOOK](../cli/HANDBOOK.md) · HTTP contract: [api-v1](../api-v1.md)
