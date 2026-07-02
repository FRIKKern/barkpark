<!-- doc-tier: agent | canonical-for: merge-gates | budget: 800tok -->
# Merge Gates (Phase 2 onward)

> Why a PR cannot be merged until every gate below is green, and how to run
> them locally before pushing.

## Pre-merge gates (as of Phase 2)

A PR targeting `main` must clear:

1. **Static audit** — Reviewer reads the diff for logic, security, and
   architectural fit. Catches most defects but not all (see lessons-learned
   below).
2. **`format` CI job** — `.github/workflows/elixir.yml`, runs
   `mix format --check-formatted`. Currently **advisory** (`continue-on-error:
   true`; the job is named "Format … advisory"). Its own dedicated, fast job
   (~30s, no DB, no full compile) so drift is visible in <60s. It was split out
   of `mix-test` to *become* a blocking gate once format drift is cleared, but
   today a red `format` check does not block merge.
3. **`mix-prod-compile` CI job** — same workflow, depends on `mix-test`.
   Cleans `api/_build/prod`, force-recompiles deps, then runs
   `MIX_ENV=prod mix compile --warnings-as-errors`. **This is the gate.**
4. **`validation-perf` CI job** — same workflow, independent of `mix-test`.
   Runs the synthetic 200-field / 100-rule bench, takes the median of 5 timed
   runs, fails if the median exceeds 100ms. Treated as a hard gate — a red
   perf bench should stop a merge even while the test suite is advisory (but
   see the branch-protection note below: nothing mechanically enforces it).
5. **`plugin-node` CI job** — `.github/workflows/plugin-node.yml`. Discovers
   plugins under `api/priv/plugins/` whose `plugin.json` declares a top-level
   `"node"` object and runs `npm ci` + lint + typecheck per plugin. Emits a
   no-op success when no plugin declares Node, so the workflow is always
   present in the required-status list.
6. **`vendored-assets` CI job** — `.github/workflows/vendored-assets.yml`,
   path-triggered on `deploy.sh` / `internal/cli/setup/assets/**`. Runs
   `make cli-assets-check` so the go:embedded deploy.sh copy can never drift
   from the root copy again (it diverged both ways on main, fixed 2026-07-02).
   Edit the ROOT deploy.sh, then `make cli-assets-sync`.

The **`mix-test` CI job** (`.github/workflows/elixir.yml`) — dev-mode
`mix compile --warnings-as-errors` + `mix test` against Postgres — is
**blocking** (no `continue-on-error`). The test-infra remediation was
completed 2026-06-10 (`continue-on-error` dropped at that point); a failing
test suite now prevents merge.

`main` has **no branch protection or rulesets** configured (verified
2026-06-21, re-checked 2026-07-01, via the GitHub branches/rulesets APIs), so none of these gates
mechanically blocks a merge — PR #123 merged with the advisory `format` check
red. They are the team's merge discipline, enforced by review rather than by
GitHub. The checks that *should* be green before merge are `mix-prod-compile`,
`mix-test`, and `validation-perf`; `format` is advisory; `plugin-node`
matters only when the PR touches `api/priv/plugins/**`. If these are meant to
be enforced, add a branch-protection rule requiring those status checks.

## Local pre-merge check

Run this before pushing — it mirrors the CI gate exactly:

```bash
make precheck
# or, equivalently:
cd api && rm -rf _build/prod && MIX_ENV=prod mix deps.get && \
  MIX_ENV=prod mix deps.compile --force && \
  MIX_ENV=prod mix compile --warnings-as-errors
```

### Why a partial clean is not enough

`CLAUDE.md` golden rule #1 and "Past Mistakes" #1: cleaning only
`_build/prod/lib/barkpark` (or any subset) leaves stale `.beam` artifacts for
HEEx templates and dependent modules. The compiler is happy with the
existing artifacts and does not re-evaluate the module graph; the bug then
surfaces only on the production server after a fresh deploy. **Always
`rm -rf _build/prod` first.**

### Why dev-mode `mix compile` is insufficient

`MIX_ENV=dev` enables compile-time leniency that `:prod` does not — most
notably, certain macro-vs-function ambiguities in `runtime.exs` `when`
guards. `mix test` runs under `:test` and is similarly lenient. Only
`MIX_ENV=prod mix compile` exercises the prod compiler; only the prod
compiler rejects the PR #42 bug class.

## Lessons-learned: PR #42 macro-in-guard (2026-04-25)

PR #42 (Phase 1 — Oban + plugin_settings + Cloak encryption) introduced a
`when`-guard in `config/runtime.exs` that referenced a macro instead of a
plain function. The construct compiled cleanly under `:dev` and `:test`,
the test suite passed, and the Reviewer's static audit did not flag it.
The defect surfaced only on the production server during the rebuild
that followed merge: `MIX_ENV=prod mix compile` failed, the systemd
service failed to restart, and PR #43 (`966fcd98 fix(api): move
config_env() out of when-guard`) was filed the same day as a hotfix.

What the new gate catches:

- **Macro-vs-function misuse in `when`-guards** that the prod compiler
  rejects but `:dev`/`:test` accept.
- **Missing or stale `_build/prod` artifacts** that a partial clean would
  hide on a developer's machine.
- **Forgotten `--warnings-as-errors`** drift across config branches.

What it does **not** catch (still requires Reviewer + tests):

- Logic errors that compile cleanly in every environment.
- Schema/data migrations that compile but fail at runtime.
- Anything that requires the database, the BEAM runtime, or external
  services to be active.

## When to override

The `mix-prod-compile` gate may be bypassed only by an explicit Boss
decision **recorded as a task in the task system** (dogfood it — the task
*is* the durable decision record; do not write to `.doey/plans/`, that
directory is retired). Capture the reason and the follow-up
to remove the override on the task itself:

A task is a `type:"task"` document created through the standard mutate
endpoint (`content.kind` must equal `"task"`); there is no bespoke
`POST /v1/tasks` create verb — the `bp task` verbs are read/lifecycle only
(`ls`, `ready`, `prime`, `get`, `claim`, `close`, `next`).

```bash
TOKEN=barkpark-dev-token

# 1. Record the override decision as a task. Pick a stable doc id (<task_id>).
curl -sS -X POST http://localhost:4000/v1/data/mutate/production \
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
#   is <task_id> below.
```

Optionally attach a written paper (a Bulldocs paper the task references) when
the rationale needs prose longer than a task body — author it through the
Bulldocs ingest API, then link it:

```bash
curl -sS -X POST http://localhost:4000/v1/tasks/<task_id>/papers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"add": ["merge-gate-override-<pr>"]}'
```

Any merge that lands without the gate green must be reverted within 24h
unless that override task exists.

## Documentation review rules (doc-gates)

PRs touching `*.md` **or any source file** (`.ex`, `.exs`, `.go`, `.ts`,
`.tsx`) also run `.github/workflows/doc-gates.yml` — code changes trigger it
because `@canonical capability:` markers in source files must be re-checked
when a code rename rots a marker. The workflow also fires on changes to the
two gate scripts themselves and to the workflow file. It runs two scripts:
`scripts/check-doc-budgets.sh` (byte caps + 7-card cap) and
`scripts/docs-anchors-check.sh` (routing/INDEX targets, card Code anchors,
G1 doc-tier headers, canonical-for uniqueness, ARCHIVED banners). Both are
**blocking**. Reviewer rules on top of the scripts:

a. A new top-level feature requires a routing-table row or a card update in
   the **same PR**.
b. A new card requires retiring or merging one (G2 — hard cap at 7 cards;
   enforced as a count in `check-doc-budgets.sh`).
c. A PR touching a file that a card anchors must update the card, or the
   anchor check fails.
d. Golden Rules and Past Mistakes in root `CLAUDE.md` are verbatim-exempt —
   any edit to them requires explicit owner sign-off.
e. Retired docs are deleted, not archived in-tree; git history is the
   archive, and recovering one is a `git checkout <rev> -- <path>`.

On byte-cap overflow: split to the owning contract/runbook or retire
content — never raise the cap.

## Quick reference

| Need to do                 | Command                                        |
|----------------------------|------------------------------------------------|
| Run the gate locally       | `make precheck`                                |
| Run the dev test suite     | `cd api && mix test`                           |
| Run the plugin matrix test | `bash api/test/scripts/test-plugin-node-matrix.sh` |
| Lint the workflows         | `actionlint .github/workflows/*.yml`           |

`actionlint` is not installed by default in this repo's environment. To add
it locally: `brew install actionlint` (macOS) or
`go install github.com/rhysd/actionlint/cmd/actionlint@latest`. CI does not
currently run `actionlint`; add it as a separate workflow if drift becomes
common.
