<!-- doc-tier: agent | canonical-for: branch-protection-and-overrides | budget: 2600tok -->
# Branch protection and overrides

> How a check becomes required-by-name on `main`, and the two sanctioned ways
> past a required context: break-glass, and a recorded `mix-prod-compile`
> override. The gate roster itself stays in
> [merge-gates.md](merge-gates.md).

## Making `pr-task-gate` binding (required-by-name)

**This gate is now BINDING** — `PR references an active task` is one of the four
required contexts live on `main` (2026-07-28; see *Pre-merge gates* in
[merge-gates.md](merge-gates.md); it read "two" until 2026-08-07, stale since
`Cloud gate` and `Console gate` were
registered, and contradicting that page's own count in the same section). The
bootstrap below is kept as the account of how a context becomes required, not
as pending work. A check becomes binding only when added to the
required-status-checks list **by name**. Required-by-name is load-bearing (D3):
a workflow that silently never runs on a conflicting PR must read as
"not satisfied", not as an absent/passing check.

**Bootstrap is a `PUT` on `protection` itself — there is no `PATCH` route.**
This file previously prescribed
`gh api -X PATCH .../branches/main/protection/required_status_checks`; run
verbatim against this repo **before protection existed** (measured pre-2026-07-28)
it returned `{"message":"Branch not protected","status":"404"}`, because
`required_status_checks` is a **child** of protection and cannot create its
parent. `gh api -X PATCH .../branches/main/protection` is a plain
`404 Not Found` — that route does not exist at all. The only bootstrap verb is
`PUT /branches/main/protection`, carrying the **whole** protection object: all
four required-and-nullable keys must be sent explicitly (omit one and the PUT
422s), and because `PUT` **replaces** rather than merges, every later edit must
re-send the full body too — a partial re-PUT silently drops the keys it omits.

```bash
# One-time, needs repo admin. Creates branch protection on `main` with
# pr-task-gate in the required-checks list.
# app_id 15368 is GitHub Actions. The pin is load-bearing: GitHub validates
# NEITHER the context string nor the app id (a typo'd id reads back as
# `app_id: null`, i.e. "any app may satisfy this context"), and Vercel's app
# 8329 already publishes check runs on this repo — an unpinned context is
# therefore spoofable by anything holding `checks:write`.
# The context string must be COPIED from a check run observed on a real PR,
# never hand-typed: GitHub appends unconsumed matrix values to a job's display
# name, so a typed name matches no check, sits Pending forever, and deadlocks
# the branch. The example below is illustrative — the AUTHORITY is
# `.github/required-checks.json`, which is GENERATED from observed check runs
# by `scripts/required-checks-generate.sh` and applied by
# `scripts/required-checks-apply.sh --confirm`. Prefer those to hand-running
# this curl; they also verify the read-back and detect a deadlock by set
# difference, which no refusal message will tell you (charter D38).
# Sent as a JSON body, not `-f checks[][…]` flags: those build the array
# positionally and can split one check into two half-specified entries.
gh api -X PUT repos/:owner/:repo/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "checks": [{"context": "PR references an active task", "app_id": 15368}]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
# `strict: false` — do not require the branch to be up to date with main; that
# is a serialization tax, not a correctness gate.
# `enforce_admins: true` — the admin bypass is refused server-side, so it is no
# longer a merge protocol. THE MERGE VERB IS `scripts/bp-merge.sh`: argument-
# free, run from the PR branch's worktree, deadlock pre-flight first, then a
# plain `gh pr merge --squash --delete-branch` once the required set is green.
# `enforce_admins: false` would have been bypassed by 100% of the fleet's
# merges — a gate that cannot block.
# Verify by round-tripping the read back: the context must match byte for byte
# and app_id must be 15368, never null.
gh api repos/:owner/:repo/branches/main/protection/required_status_checks \
  --jq '.checks[] | select(.context == "PR references an active task")'
gh api repos/:owner/:repo/branches/main/protection --jq '.enforce_admins.enabled'
```

Two human-provisioned prerequisites, both settled — the flip itself happened
2026-07-28:
- **`BARKPARK_TASK_TOKEN`** repo secret — a guerrilla write token, so the
  `hotfix!` lane can auto-file its override task. **PROVISIONED 2026-08-25**
  (`gh secret list`). This bullet said "It is **not provisioned**, and without
  it the lane **reds**" until 2026-09-01; with the secret set that is inverted —
  the label now WAIVES a merge-blocking required context, see the hotfix-lane
  item under *Pre-merge gates* in [merge-gates.md](merge-gates.md). The token
  was never a record-keeping nicety —
  it is what the lane needs to exist at all — so provisioning it armed the
  bypass, and that is a lead-level merge-authority fact, not a CI detail. Two
  limits survive: the lane cannot rescue a guerrilla outage (it writes its
  record to guerrilla), and fork PRs receive no secret.
- Optionally `BARKPARK_LEDGER_BASE` repo **variable** to point the gate at a
  different ledger instance (defaults to `https://guerrilla.barkpark.cloud`).

## Break-glass — the armed override

When a required context must be lowered, the mechanism with an enforced record
is `scripts/breakglass.sh`, run by a repo admin from a checkout. (This sentence
read "the mechanism that actually works is **not** the `hotfix!` lane (see
above: it reds)" until 2026-09-01. The lane has been armed since 2026-08-25 and
does waive the gate; it is the *unreviewed* override — its record is filed by
CI onto the very ledger an outage would have taken down. Break-glass refuses
without `--reason` and `--task` and reads its record back off disk first, which
is why it stays the one to reach for.)

```
scripts/breakglass.sh --open  --reason "…" --task <task-id> [--total]
# … merge …
scripts/breakglass.sh --close --reason "…" --task <task-id>
```

It refuses without both `--reason` and `--task`, writes an attributable record
to `docs/ops/break-glass-log.md` and reads it back off disk **before** it
touches protection (a crash leaves a record with no open glass — a false
positive, which is recoverable; the reverse ordering would leave a silent open).
`--open` without `--total` drops only `enforce_admins`, so required checks still
apply to non-admins. `.github/workflows/breakglass-watch.yml` polls live
protection every 30 minutes on `BREAKGLASS_TOKEN` and hard-fails on a credential
fault, so an unarmed watcher cannot read as "all clear". `scripts/breakglass.sh
--status` and `scripts/breakglass.test.sh` are the read-only entry points.

**Closing a glass never touches `enforced`** — break-glass moves *live*
protection only, and `--disable` `exec`s into `--open --total` writing no flag.
`verify --ci` now reads live protection on `enforced=false` too, so committing
that flag while `main` is protected **reds the spec gate**: flip it back in the
PR that restores protection.

## When to override

The `mix-prod-compile` gate may be bypassed only by an explicit Boss
decision **recorded as a task in the task system** (dogfood it — the task
*is* the durable decision record; do not write to `.doey/plans/`, that
directory is retired). Capture the reason and the follow-up
to remove the override on the task itself:

A task is a `type:"task"` document created through the standard mutate
endpoint (`content.kind` must equal `"task"`); there is no bespoke
`POST /v1/tasks` create verb — the `bp task` verbs are read/lifecycle/progress
only (`ls`, `ready`, `prime`, `get`, `events`, `claim`, `release`, `next`,
`move`, `stage`, `pulse`, `stamp`, `close`). Run `bp task <verb> --help` for
the current contract of any one of them.

**Write to the ledger of record, not to a dev box.** The commands below target
`https://guerrilla.barkpark.cloud` — the instance every gate and board reads.
The older form of this runbook pointed at `http://localhost:4000` with
`barkpark-dev-token`, so an agent following it at 3am recorded the override
into a database that does not exist and left the merge unjustified. Use your
own guerrilla token (`bp login`, or the same write token CI uses as
`BARKPARK_TASK_TOKEN`); the `curl` here is the no-`bp` fallback — with the CLI
on hand, `bp doc create task … && bp doc publish task <task_id>` is the shorter
path, and boards read only the **published** ledger.

```bash
LEDGER=https://guerrilla.barkpark.cloud
TOKEN=<your guerrilla write token>   # never barkpark-dev-token

# 1. Record the override decision as a task. Pick a stable doc id (<task_id>).
curl -sS -X POST "$LEDGER/v1/data/mutate/production" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{
        "_id": "merge-gate-override-<pr>",
        "_type": "task",
        "title": "merge-gate override: mix-prod-compile bypassed for <PR #>",
        "content": {
          "kind": "task",
          "lifecycle_status": "open",
          "decision": "Boss approved bypassing the mix-prod-compile gate.",
          "reason": "<why>",
          "follow_up": "<remove the override: what + when>",
          "merge_sha": "<sha>",
          "labels": ["merge-gate-override", "ops"]
        }
      }}]}'
# → the create lands as drafts.merge-gate-override-<pr>; the doc id you chose
#   is <task_id> below. Publish it — a draft override is invisible to every
#   board and to the pr-task-gate:
#   bp doc publish task merge-gate-override-<pr> --yes
```

Optionally attach a written paper (a Bulldocs paper the task references) when
the rationale needs prose longer than a task body — author it through the
Bulldocs ingest API, then link it:

```bash
curl -sS -X POST "$LEDGER/v1/tasks/<task_id>/papers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"add": ["merge-gate-override-<pr>"]}'
```

Any merge that lands without the gate green must be reverted within 24h
unless that override task exists.
