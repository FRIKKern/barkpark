<!-- doc-tier: human | canonical-for: task-system-guide | budget: 4000tok -->
# The Task System

Barkpark as your AI's task board: agents claim work over HTTP, you steer the queue in Studio, live. Tasks are plain `type:task` docs — no second store; claims are atomic and fenced.

## What you get

| Surface | What |
|---|---|
| **Studio Tasks pane** | A **Tasks ✅** desk group at `/studio` with lifecycle tabs; editor = four-group dossier (brief · work · close · system); `dependencies`/`claim` read-only. |
| **`bp` verbs** | `bp task ls / ready / prime / events / get / next / claim / release / stamp / pulse / landed / close / move` — manifest-driven. |
| **Terminal TUI** | `bp tasks` (= `bp task tui`); `c`/`x` claim/close as `BARKPARK_WORKER_ID` (default `tui-<hostname>`). Keys: [tui cheatsheet](../cheatsheets/tui.md). |
| **HTTP API** | Bearer endpoints under `/v1/tasks/*` (read tier): the verbs plus fetch, edges, labels, papers. |
| **Events** | Each op emits a `mutation_events` row: `task.{claimed,released,criterion,pulse,closed,mutated,relabeled,referenced,reparented,lease_expired,compacted,compaction_restored}`. **Push** SSE `/v1/data/listen/:dataset`; **pull** keyset feed `GET /v1/tasks/events?since=<id>` (§7). |

## Set up from zero

Install and run the wizard per [QUICKSTART](QUICKSTART.md). Its **clean profile pre-checks `bulldocs` + `tasks`** (server unions `media`); accept and schema, routes and crons go live on first boot.

**Existing installs** — enable via env and restart:

```bash
BARKPARK_PLUGINS=bulldocs,tasks  # CSV whitelist · unset = all plugins · empty = kill switch
```

The `task` schema auto-registers each boot (idempotent on `(name, dataset)`); two Oban crons ride along: lease sweeper, compaction (6 h).

## Point an AI agent at it

**Register the movement.** Every unit of work runs under a claimed task: if no row names it, create one and claim it FIRST, then work. Doctrine, and the three ways registration silently does not land: [AGENT-ONRAMPS](AGENT-ONRAMPS.md#register-the-movement).

Gates come from the PATHS, not the lane: `bash scripts/which-gates.sh` prints what your diff dispatches.

**1. Token.** Any bearer token reaches the task endpoints (read tier); creating tasks needs the mutate endpoint (write tier). Dev default: `barkpark-dev-token`. A stale `BARKPARK_TOKEN` SHADOWS `~/.config/barkpark/config.json`: `bp whoami` reads `auth_tier: none` and every `bp task` verb says *hidden at your tier* — `unset BARKPARK_TOKEN` (or `env -u BARKPARK_TOKEN bp …`) first.

**2. Discover.** One call teaches the surface:

```bash
bp capabilities -o json  # = GET $API/v1/capabilities, bearer
```

**3. Create tasks.** Required: `kind: "task"` + a valid `lifecycle_status`. Optional: `priority` (0–4, 0 = highest), `assignee`, `parent_id`, `labels`, `papers`, dossier fields (`brief`, `description`, `acceptance_criteria`, `purpose`, `estimate`, `due_at`, `outcome`, …) — the `task` schema is authoritative. `brief` = the PortableDoc envelope (`{version: 1, blocks: […]}`), `description` its text fallback; author briefs as blocks, not a text wall. `bp task create "<title>" --yes` files a draft; `--publish` also needs `--description` (20+ chars) and 1–12 tags already registered as `type:tag` docs (`bp doc ls tag --all`) — an invented tag is refused before anything is created. Raw HTTP: the same fields as a `create` mutation (`_type: "task"`, dossier under `content`) in the [api-v1 §6](../api-v1.md) batch envelope, `POST $API/v1/data/mutate/production`, bearer.

**Adjudication at birth.** `bp task create` takes `--disposition <open|parked|closed>`, `--reopen-trigger <when>` and `--disposition-rerun <cmd>`, screened client-side against the vocabulary the api's birth fence uses — an off-vocabulary term and a hollow park (parked, no trigger) are refused before the write; `--set disposition=…` uses the same screen. The CLI reads it from `internal/cli/task_adjudication_vocabulary.json`, locked against `Barkpark.Tasks.Stage` by a Go test.

> **Draft prefix:** `create` lands as `drafts.t1`; the task endpoints resolve bare `t1` (published `t1` wins). *Resolution*, not *listing*: an unpaired `drafts.<id>` task IS listed as itself; only a twinned one collapses. Lifecycle is independent of draft/publish. `bp doc patch` writes the DRAFT (`bp doc publish <type> <id> --yes` lands it) — except a `type:task`, which lands published.

**4. Claim → stamp → close.** Use a stable `worker_id` per agent. Every prod write — `create`, `claim`, `pulse`, `stamp`, `release`, `close`, `doc patch`/`publish` — needs `--yes`; without it `bp` aborts (`prod write not confirmed`) and sends nothing (a batch missing it no-ops silently). Reading back (`-o json`): criteria at `doc.content.acceptance_criteria`, lease at `doc.claim` (§6).

```bash
bp task next agent-1          # queue claim, priority order; prints doc_id + epoch; no_ready (HTTP 200, not an error) if empty
bp task claim t1 agent-1      # targeted claim: <doc_id> <worker_id>
bp task release t1 agent-1 1  # voluntary walk-away, fenced: <doc_id> <worker> <epoch>

# Mid-claim: stamp a criterion. --criterion N is ZERO-based (0 = the first). Take the wording from a
# FILE (`-` = stdin): a double-quoted `code span` is COMMAND SUBSTITUTION FROM THE ROW, matching any
# index and leaving the guard INERT.
bp task get t1 -o json | jq -r '.doc.content.acceptance_criteria[0].criterion' > crit.txt
bp task stamp t1 agent-1 1 --criterion 0 --criterion-text-file crit.txt --met --evidence "gate green"
# A MISS keeps its reason in --note and NOWHERE ELSE: it lands at
# .content.acceptance_criteria[N].attempts[].note (last 5 kept) and NEVER at .evidence, which a
# miss does not write. So a readback keyed on (.evidence|length) reads 0 on every LANDED miss —
# read attempts[].note beside it. `--miss --evidence ...` is refused: the server drops that field.
bp task stamp t1 agent-1 1 --criterion 1 --miss --note "flaky"
bp task stamp t1 agent-1 1 --criterion 0 --criterion-text-file crit.txt --withdraw --note "wrong branch"
# A pulse BUMPS claim.epoch: stamp/close on the PULSE's epoch, not the claim's.
bp task pulse t1 agent-1 --now "warm-up pinned, rerunning" --criterion 2

bp task close t1 agent-1 1    # epoch-fenced: <doc_id> <worker> <epoch> [status] [reason]
# Close with evidence: flips ride the same rev-CAS — but a flip made HERE is not proof of itself.
bp task close t1 agent-1 1 --set 'criteria:=[{"index":0,"met":true,"evidence":"PR #123","criterion":"gate passes"}]'
# Landing from CI: no worker, no epoch; --criterion N seals ONE merge-shaped row
bp task landed t1 --commit a1b2c3d --pr 123 --note "merged to main" --criterion 6
```

Full contract — lease TTL, what each verb fences on, every refusal (`409 fenced_off`, `not_holder`, `criteria_unmet`, …), and `--withdraw`, the only verb that LOWERS a met flag (a bare `met:true → met:false` patch is refused), plus its sealed-row rules: [claim-lifecycle](../contracts/task-claim-lifecycle.md); close receipt: [close-packet](../contracts/close-packet.md).

**5. Dependencies, labels, papers.** Same bearer + JSON headers; routes in the [cheatsheet](../cheatsheets/tasks.md). `POST /v1/tasks/edges` `{"from_id":"t2","to_id":"t1"}` = t2 waits on t1 — from = dependent, to = blocker, `kind` defaults `blocks`. `GET /v1/tasks/:id/edges` takes `?kind=all`.

**6. Filtered reads.**

```bash
bp task ready --limit 5 --offset 0  # deterministic queue page
bp task ready --all                 # aggregate pages
bp task ls --limit 20               # all tasks, goals included
```

Filters: `kind`, `label`, `lifecycle_status`, `parent`, `parent_id`, `phase_id`, `type`, `limit`, plus `offset` on `ready`/`ls`; unknown key → 400 `invalid_filter`. **Default pages:** `ls` 100, `ready` 50, cap 1000; `has_more` = `returned == limit`; a filled default page warns on stderr — use `--all` or a bigger `--limit`. Order: priority/creation/UUID; `ls` is total-ordered (updated_at DESC; `parent` → inserted_at ASC; id tiebreak), pages disjoint; `--all` fails `pagination_stalled` on a repeated full page.

**Ready rows are not `get` rows.** `ready`/`ls` rows are FLAT — `doc_id`, `priority`, `criteria_met`, `criteria_total`, `labels`, `parent_id`, `claim`, … at the TOP level, **no `content` object** — inside `{"docs":[…]}`; `bp task get` nests the same facts under `doc.content`, criterion text keyed `criterion`, never `text`. **`lifecycle_status` is OMITTED on a ready row**, emitted only when the row is NOT ready (`blocked`): absence means ready, presence NOT ready, so `select(.lifecycle_status == "open")` returns EXACTLY ZERO over a page full of work — a zero indistinguishable from an empty lane. Both arms and a `CANNOT READ:` refusal are pinned by `TestTaskReadyPageShape*` over `internal/cli/testdata/task_ready_page.json`.

**7. Watch the stream.** Both routes are in **What you get**. **Push:** SSE, `task.*`, no polling. **Pull:** `bp task events --since <id>` replays id-ASC, one page (≤500): `{ok, events:[{id,event,doc_id,rev,at}], cursor, has_more}`; `id` is the stable cursor (monotonic PK). Resume with the last `cursor`; omit = from start; `has_more:true` → poll again. One `dataset` (default `production`), `type=task`.

## Task ↔ code linkage

Two optional content fields answer "what code is this task?" without a git dig:

- **`code_refs`** = `{"prs":[int],"commits":["sha"],"branch":"name","worktree":"path-or-null"}` — `commits` holds merge shas; `worktree` is set only in flight.
- **`last_worked_at`** = ISO timestamp of the newest attached code activity — unlike `updated_at`, which any edit bumps.

Stamp at three moments: **claim** sets `branch`+`worktree`, **PR-open** appends `prs`, **merge** appends the sha to `commits` and clears `worktree`→null; each bumps `last_worked_at`. Patch via `/v1/data/mutate` — a `patch` whose `set` merges both into `content`; on a `type:task` it hits the PUBLISHED row, so pass `ifRevisionID` = the `rev` `bp task get` served. A pre-existing `drafts.<id>` twin 422s naming it. Never fabricate a ref; leave unknown fields absent.

## PR ↔ task contract — one trailer, one live claim

`.github/workflows/pr-task-gate.yml` runs `scripts/pr-task-gate.sh` as the REQUIRED check "PR references an active task" on `opened`, `synchronize`, `reopened`, `edited`. When it PASSES a claim (lapsed-claim rule, `hotfix!` waiver, ledger-outage red) is owned by [merge-gates §7](../ops/merge-gates.md). Three rules are yours:

- **Exactly one `Task: <doc_id>` at column 0** of the PR body. Two DISTINCT ids make `extract_task_id` exit 4 (ambiguous) and the check reds. A PR landing several rows keeps ONE `Task:` and cites the rest as `Discharges:` (below). Restating the same id twice is fine; ids are deduplicated.
- **A second row the merge discharged: `Discharges: <doc_id> c<N>`** at column 0, repeatable; the gate matches `^Task:` only. Push-to-main POSTs it to `/v1/tasks/<primary>/discharges`, noting `discharge_marks` on criterion N (PR, sha, primary); never `met`.
- **A red in the body is fixed by editing the body**, not by a commit — `edited` re-triggers the workflow. Exit 3 (credential refused) is the workflow's, not yours. Hold the claim until the PR MERGES — pulse every ~18 min.

## The cmux bridge — a pane that owns its task

A cmux pane can auto-own its task. `bp cmux install --print` prints the four hooks + worker-id; `--merge --yes` folds them into `~/.claude/settings.json` (deduped, backup first). The worker is the *pane* (`cmux-<CMUX_SURFACE_ID>`), so subagents share one lease. With `BARKPARK_TASK=<doc_id>`: **SessionStart** claims; **PreToolUse** **pulses** ≤1/60s (holder-only renew; now-line = `tool_name` + cwd basename, never the transcript; a lost lease answers `not_holder`, never a re-claim); **Stop**/**SessionEnd** close on the pulse's stamped epoch IFF every criterion is met (published met-flips need a re-publish), else LEAVE it claimed — so a `merge_gate:true` criterion is the fence, `met:false` until a merge autostamps it (#3039, #15090). Hooks exit 0 with empty stdout, so a dead server can't harm the agent (`bp cmux status`). No `uninstall`: remove hook groups by hand.

## Working with your AI in Studio

In `/studio` → **Tasks ✅**: you (form) flip `lifecycle_status`/`priority`/`assignee` and edit titles/descriptions; the agent (API) claims/closes with fencing, adds edges, relabels, links papers. The TUI edits flat fields; composites (`acceptance_criteria`) are Studio/API-only — the API single-writes structured values. Live over PubSub.

**`/admin/projects`** (`:ops` admin-gated) is a live kanban over the same docs: five realtime columns — open · ready · in_progress · blocked · done (cancelled → tally). **Drag** restages through the fenced `claim`/`close` primitives (a foreign-held card refuses, as does a `done` drop over unmet criteria; `ready` is derived — no drop). **Group**/**filter** via URL chips (`?group=&goal=&priority=&label=&worker=`).

## Goals and phases

Everything is a task. The pattern:

- **Goal** = a root task (no `parent_id`).
- **Phase / subtask** = a task whose `content.parent_id` is the parent's doc id.
- **Rail** = a task's chronological children: `GET /v1/tasks?parent=<id>` (oldest first); `GET /v1/tasks/:id` inlines one level of `children` summaries + `child_count`.
- Scope a worker to one phase: `POST /v1/tasks/claim` `{"worker_id":…,"phase_id":…}` or `GET /v1/tasks/ready?phase_id=…`.

### How to organize tasks (follow these for ANY task)

A scattered board is a defect; fit every task to this structure:

1. **Every task belongs to a goal.** No floating orphans — give related tasks a goal parent (`parent_id`); nest goals under epics for bigger missions.
2. **Goals are MISSIONS, named as the outcome a human wants** — e.g. *"Sheets reaches Excel parity"* — never after provenance/process (`loop`, `cleanup`, `misc`) or a label.
3. **Group by ancestry** — tasks sharing a goal nest beneath it; the parent tree is the spine.
4. **Labels** (`content.labels`): `proj:<mission>` (required), `phase:<goal|design|decision|build|verify>`, `kind:<deferred|low|…>`, plus gates `needs-human`/`decision`/`security`.
5. **Real work tasks carry `acceptance_criteria`** — 1–3 checkable conditions. **State a CHECK TO RE-RUN, not a predicted state**: one opening **If / Once / When / Should** names the OBSERVABLE that flips it (a file, a symbol, a PR, a command exiting 0); sweep: `scripts/ledger/conditional-criteria-census.py`. Name REAL test files and gate them with `scripts/mix-test-strict.sh`; bare `mix test` drops a missing path silently whenever another matches. Decisions/goals may omit them; a row with none closes `done` only if `close_reason` names the PR + sha or the run. Merge gates need `merge_gate:true`: a `landed` close flips only the flag, wording alone warns.
6. **Blockers are explicit** — `blocks` edges keep a gated task out of "ready"; one waiting on a human carries `needs-human`/`decision`.
7. **Cite code by SYMBOL** (`api/lib/x.ex fun/2`); a line number is a hint that carries its sha; a basename is not an address. **A claim about code carries the grep or run behind it** — line checkers miss claim rot. Report stale anchors (`scripts/pds-task-anchor-report.sh`), never auto-rewrite: a moved anchor and a gone finding differ.

## Workspaces, projects, datasets

Sandbox scoping (`bp workspace create/ls`, `bp -w <slug> workspace project-create`, `/w/:ws/p/:proj`, flat → `Default`/`Default`): [tenancy](../contracts/tenancy.md) · [api-v1](../api-v1.md) §1a · [HANDBOOK](../cli/HANDBOOK.md).

## Troubleshooting

No **Tasks** pane in Studio, or `404` on `/v1/tasks/*` — the plugin is off: pane and routes mount only when `tasks` is on. Fix env + restart.

Cheatsheet: [tasks](../cheatsheets/tasks.md) · CLI canon: [HANDBOOK](../cli/HANDBOOK.md) · HTTP contract: [api-v1](../api-v1.md)
