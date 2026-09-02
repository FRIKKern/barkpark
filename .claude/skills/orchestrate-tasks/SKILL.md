---
name: orchestrate-tasks
description: Turn THIS session into the orchestrator of a 6-lead / 30-worker task campaign against the Barkpark ledger — six Fable team leads, each owning one fence-disjoint area of the backlog and running up to five Opus workers, all coordinated through the orchestrator with a file-and-message protocol. Invoke when the user says "orchestrate the tasks", "send out team leads", "clear the backlog with teams", "run /orchestrate-tasks", or asks for many leads each with their own workers to work the backlog AND improve the system. Distinct from bp-epic-cycle (one epic, one wave) and fleet-orchestrator (cross-machine listeners): this is one session, in-process leads, the whole ready backlog.
---

# orchestrate-tasks — six leads, thirty workers, one ledger

You are the **orchestrator**. You never build. You carve the backlog into lanes, launch
six **Fable** leads, keep them unblocked and disjoint, relay cross-lane needs, relaunch a
successor the moment a lead returns, and tally at the end. Leads triage, claim, dispatch
up to five **Opus** workers each, review, merge, and close. Workers build in their own
worktrees and never touch the ledger's close verb.

Shape: `you (1) → leads (6, fable) → workers (≤5 each, opus)`. Never Haiku, anywhere.

## 0. Preflight (2 minutes, always)

1. **bp must read `auth_tier: admin`.** `bp whoami | grep auth_tier`. If it says `none`
   while `~/.config/barkpark/config.json` holds an admin token, a stale
   `BARKPARK_TOKEN` in the environment is shadowing it (`~/.config/barkpark/env`, sourced
   by `.zshrc`). Fix at the source (comment the export, keep a dated backup) and tell every
   agent to prefix `env -u BARKPARK_TOKEN` anyway.
2. **Quota.** `cswap status`. Leads are Fable; if a lead dies with a message containing
   `switch models to continue`, relaunch that lead on `opus` (model-scoped cap). A bare
   `raise it at claude.ai/settings/usage` is account-wide: `cswap` to the next account.
3. **Snapshot the backlog.** `node .claude/skills/orchestrate-tasks/helpers/backlog-snapshot.mjs`
   writes `ready.json` into `$ORCH` and prints: counts by priority, the biggest parents,
   and the P0/P1 leaves. `$ORCH` is `<scratchpad>/orchestrate`; export it.
4. **Carve six lanes by FILE TREE, not by epic.** A lane is a set of paths plus the
   epics/leaves that live there. Lanes must be fence-disjoint so no two leads edit the
   same file. Registry files that everyone touches (`api/lib/barkpark_web/router.ex`,
   `api/priv/static/openapi*.json`, `api/.sobelow-*`, `CHANGELOG*`) belong to no lane:
   rebase onto `origin/main` immediately before the edit, keep it minimal, merge fast.
   The default carve that fit the 2026-09-01 backlog:

   | lane | fence | seeds |
   |---|---|---|
   | security | `api/lib/barkpark_web/{plugs,controllers}`, `api/lib/barkpark/{auth,tenancy,tokens,shares}` | cross-tenant P0s, `api-read-path-security-sweep`, `enterprise-ready-auth` |
   | gates | `.github/`, `scripts/`, `design/`, `api/test/support`, flaky tests | MAIN-IS-RED rows, `task-018046fbe07a2f0b` (honest gates), `ci-gate-script-integrity-audit` |
   | deploy | `deploy/`, `internal/cloud`, `api/lib/barkpark/fleet`, box ops | `task-fb4fb869490b4213` (69% deploy failures), `dr-backlog-never-started`, disk P0s |
   | console | `api/lib/barkpark_web/cloud*`, `api/lib/barkpark/cloud`, site spawner | `cloud-console-hardening-epic`, `cch-instruments-epic`, `bp-cloud-site-spawner-epic` |
   | cli | `internal/cli`, root Go, `api/lib/barkpark/tasks`, `api/lib/barkpark/plugins/tasks` | `task-c1a8a4080082a966` (phantom drafts), `task-ece47eb3c4ca8d7a`, `task-lifecycle-visibility-epic`, `fix(cli)` rows |
   | studio | `api/lib/barkpark_web/studio*`, `api/lib/barkpark/plugins/{bulldocs,search,media}`, `js/`, `web/` | `studio-space-priority-desk`, `pd-everything-editable`, `search-template-epic-goal`, `task-5c4e993bacb18a58` |

   Re-carve when the snapshot says otherwise. Six lanes is the shape; the fences move.

## 1. Launch — all six in ONE message

Copy `LEAD-BRIEF.md` (next to this file) to `$ORCH/LEAD-BRIEF.md`. For each lane call
`Agent` with `subagent_type: "general-purpose"`, `model: "fable"`, `name: "lead-<lane>"`,
and a prompt of this exact shape — short, because the brief carries the protocol:

```
You are lead-<lane>, one of six team leads in a Barkpark task campaign.
FIRST read $ORCH/LEAD-BRIEF.md in full — it is your operating manual and is binding.
Your lane: <one sentence>.
Your fence (paths you may edit): <list>.
Seed rows (verify before trusting): <ids + one-line titles>.
Repo root (read-only reference, on origin/main): <path>. Your worktrees go under $ORCH/wt/.
$ORCH = <absolute path>. Status file: $ORCH/lead-<lane>/status.md.
```

Six leads run concurrently. Do not do lane work yourself while they run.

## 2. Coordinate

- **Decisions file.** Every ruling, approval or routing you give a lead ALSO goes into
  `$ORCH/lead-<lane>/DECISIONS-FROM-MAIN.md` (append a dated table row). Measured 2026-09-01: a lead in a
  long turn showed six rows BLOCKED for two hours after eight inbox messages had answered them; the
  file is what it reads at the top of each loop.
- **Inbound.** Leads message you with `SendMessage(to: "main")` for anything that needs
  a decision or another lane; everything else lands in their `status.md`. Arm ONE monitor
  on the status dir so you see milestones without polling by hand:
  `bash .claude/skills/orchestrate-tasks/helpers/lane-status.sh --watch` (emits one line per
  status change; `--once` prints the table).
- **Cross-lane requests** (`REQUEST:` lines in `status.md`): forward with `SendMessage`
  to the owning lead; never edit the other lane's files yourself.
- **Decisions only the user can make** (rotate a live credential, delete data, email a
  third party, waive a security gate): hold ONLY that one task, tell the lead to continue
  on the rest, and put the question in your final message. Never idle a lane on it.
- **A lead returns → same turn: read its report, relaunch a successor `lead-<lane>-2`
  on the lane's next slice.** Landing and relaunching are one motion. The pipeline never
  idles while there is ready work and quota.
- **Fable death.** A lead that dies on the Fable cap is relaunched on `opus` with the
  same prompt; its workers were already Opus.

## 2b. Throttle the machine, not the fleet

Elixir compiles are the real ceiling: 30 workers each compiling `api/` in their own worktree took a
10-core Mac to load 33 and made everything slower. An ADVISORY throttle (`helpers/with-slot.sh`) is
bypassed by half the workers within an hour (measured 2026-09-02: 6 `mix test` processes, 2 slots
held). Install the UNAVOIDABLE one: copy `helpers/mix-slot-wrapper.sh` to `~/.local/bin/mix` and
`helpers/go-slot-wrapper.sh` to `~/.local/bin/go` (that dir precedes Homebrew on PATH; every new
shell picks them up), 3 slots each, `BP_NO_SLOT=1` bypasses, delete the files to disable. Tell the
owner: their own `mix test` waits for a slot too while the campaign runs.

## 3. Improve the system — a standing 1-of-5

Every lead keeps one worker slot for **system improvement**: a trap the lane hit while
working (a gate that lies, a `bp` verb that misleads, a doc that sent a worker the wrong
way, a flaky fixture). Each such trap becomes a filed task in the lead's lane, fixed the
same way as any other row, and listed under `System improvements` in the report. The
campaign is judged on those as much as on closes.

## 4. Close the campaign

1. Collect the six reports. Tally in ONE table: tasks closed, PRs merged, PRs open,
   system improvements, blocked-on-user.
2. `bp session log` the tally if a session is open; push every branch; nothing stays local.
3. Final message: the table, the blocked-on-user questions (2 options each, your pick),
   and where each open PR sits. Nothing else.

## Rules that are not optional

- Model on every `Agent` call: leads `fable`, workers `opus`. Never inherit, never Haiku.
- A worktree per worker: `git worktree add $ORCH/wt/<lane>-<slug> -b <lane>/<slug> origin/main`.
  Never `.claude/worktrees/<generic>` — peers take those over mid-run.
- Commit only your own paths (`git commit -- <paths>`), then `git log -1 --stat` and read
  the file list. A stray file means another writer; repair before pushing.
- Every PR carries `Task: <doc_id>` as a trailer and merges through `scripts/bp-merge.sh`.
- `bp task close <id> <worker> <epoch>` is the LEAD's verb after the merge; a worker
  stamps criteria (`bp task stamp`) and never closes.
- Skip `drafts.*` rows in `bp task ready` — they are unpublished phantoms.
- Never push to a contributor's branch; never open a PR for a peer's stranded work.

## 5. When the fleet dies (quota) — the campaign must survive its agents

Measured 2026-09-02 02:10Z: all 17 leads hit the Opus 5-hour limit within one minute. Design for it:

- **State lives in files, not in agents.** Each lane's `status.md`, `DECISIONS-FROM-MAIN.md`, `handoff.md`;
  every branch pushed; every PR with its `Task:` trailer. A lead is a cursor over those files.
- **Loops outlive leads.** Keep running from the orchestrator: the campaign-row pulse (18 min), the CI
  advisory sweep (`helpers/ci-advisory-sweep.sh`), and the merge sweep (`helpers/merge-sweep.sh`) —
  squash-merges any campaign PR whose FOUR required checks are green **by head sha and whose base is
  main** (a stacked PR merges into its parent otherwise), never closes ledger rows. Its first pass
  landed 31 reviewed PRs while every lead was down. Read required checks with `helpers/pr-required.sh`;
  `gh pr checks` renders cancelled/queued as fail.
- **Write `$ORCH/RESUME.md`** the moment the fleet drops: per lane, the live concerns and the relaunch
  prompt (`lead-<lane>-r`: read brief → status → decisions → merge-sweep.log; RE-CLAIM rows first, the
  leases lapsed; stamp + close what the sweep merged; continue).
- **Notify the owner once** (PushNotification): quota is theirs (`cswap`); relaunch on their word or at
  the reset time. Do not spend the outage idle: sweeps, triage reads, and the resume plan are free.
