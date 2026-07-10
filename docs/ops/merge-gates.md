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

7. **`pr-task-gate` CI job** — `.github/workflows/pr-task-gate.yml`. Enforces
   task-obsession layer 1: every PR must carry a `Task: <doc_id>` trailer in its
   description naming a task that is `in_progress` (claimed) on the
   ledger-of-record (guerrilla). No task / task not found / not in_progress →
   the check fails. The pure ledger decision is the unit-tested
   `scripts/pr-task-gate.sh` (`bash scripts/pr-task-gate.test.sh`, hermetic);
   the workflow only plumbs PR context in. Three designed behaviours:
   **merge-base cutoff** — a PR whose base predates the gate (workflow absent at
   base SHA) is grandfathered, so turning the gate on does not red the open-PR
   fleet; **hotfix lane** — a `hotfix!` label passes AND auto-files an override
   task (needs the `BARKPARK_TASK_TOKEN` secret; without it the lane still
   passes but logs that the record was not filed); **ledger-outage neutral** —
   a 5xx / unreachable ledger warns and passes (an infra blip must not freeze
   merges), while only a definitive "no task / not found / not in_progress"
   fails. Optional `.github/pr-task-workers.json` (`{ "<gh-login>": "<worker>" }`)
   tightens the check to require the task be claimed by the author's mapped
   worker. **Currently advisory** until made required-by-name (below).

8. **`reland-check` CI job** — `.github/workflows/reland-check.yml`. **Advisory
   only** (`continue-on-error: true`): flags when a PR changes files a
   recently-closed task already landed. Each task's `content.landed.files`
   digest is written at close (the land-digest close path); the check diffs the
   PR's changed files against every closed task's digest. Two dampers keep it
   readable (both in the unit-tested `tooling/task-obsession/reland_check.py`,
   `bash tooling/task-obsession/reland_check.test.sh`): **hot-file
   down-weighting** (files in a large fraction of digests + a seed list carry no
   signal) and **dependency-edge suppression** (a finding against a task the
   PR's own task depends on is dropped — reverts/follow-ups are expected;
   best-effort, needs `BARKPARK_TASK_TOKEN` to read edges). Ledger unreachable →
   no findings. Surfaces as a `::warning::` + job summary; never blocks — add a
   `blocks` edge to the prior task to silence an intentional overlap.

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

## Security gates (Sobelow + mix_audit)

`.github/workflows/security.yml` (filed by `task-a41fc4590b2c2eb1`) adds two
Elixir security gates, path-triggered on `api/**`:

9. **`sobelow` job** — Phoenix-aware static analysis (XSS.Raw / SendResp,
   SQL injection, unsafe `String.to_atom`, missing CSRF/CSP, hardcoded secrets,
   `binary_to_term`, directory traversal…). **Advisory** (`continue-on-error:
   true`) — Sobelow fingerprints are derived from compiled AST and are NOT
   stable across Elixir toolchains, so a baseline generated on a dev machine's
   Elixir does not match CI's 1.18.1/OTP27 and a blocking gate would red the
   fleet on fingerprint drift rather than real regressions. Findings stay
   VISIBLE in CI; flip to blocking once the baseline is regenerated **in CI**
   (matched toolchain) or the 30 real high/medium findings are remediated
   (task-c9d6d29cc0059d2a). The 98 findings that existed on main at wiring time
   (21 high / 9 medium / 68 low confidence) are captured in
   `api/.sobelow-skips` — the **reviewed baseline**. Command:
   `mix sobelow --skip --exit Low` (`--skip` reads the baseline; `--exit Low`
   fails on any non-baselined finding at Low confidence or above, so even a
   low-confidence new `raw()` reds it — proven by planting a
   `send_resp(conn, 200, params["body"])`). Regenerate the baseline **only**
   after a reviewed cleanup: `cd api && mix sobelow --mark-skip-all`, then commit
   the shrunk `.sobelow-skips`. The baselined high-confidence findings are real
   and tracked for remediation (follow-up task); baselining them here is the
   standard "gate catches regressions, backlog fixes history" split — NOT an
   acceptance that they are safe.

10. **`mix-audit` job** — dependency CVE scan (`mix deps.audit`, the `mix_audit`
    dep) over `mix.lock`. **Blocking** (no `continue-on-error`). The 8
    pre-existing CVEs were remediated by a version bump (task-726cab56d9a84551),
    NOT by accepting them: mint 1.7.1→1.9.1 (×4 advisories), postgrex
    0.22.0→0.22.3, phoenix 1.8.5→1.8.9, decimal 2.3.0→3.1.1 (the last needed
    ecto 3.13.5→3.13.6 + ex_json_schema 0.11.2→0.11.5 to relax decimal to
    `~> 3.0`). The 8th — **esaml GHSA-4g2h-vm7x-747c** (XXE, local-file
    disclosure/SSRF) — has **no upstream fix** (every release ≤ 4.6.0 is
    affected), so it is the single `--ignore-advisory-ids GHSA-4g2h-vm7x-747c`
    suppression in the audit step, justified because OTP 27+ neutralises the XXE
    (xmerl disables external entities by default) and both CI (OTP 27.0) and
    prod run OTP 27+. Every OTHER CVE must be fixed by a bump — never ignored.
    Protective proof: `mix deps.audit` exits 1 on the pre-bump lock and on any
    new CVE; drop the esaml id the moment upstream ships a patch. To suppress
    additional accepted advisories, mix_audit also takes `--ignore-file <path>`
    (advisory IDs, one per line).

Both deps are `only: [:dev, :test], runtime: false` in `api/mix.exs` — analysis
tooling that never ships in the release.

### Making `pr-task-gate` binding (required-by-name)

The gate ships **advisory** — a red check does not yet block a merge, because
`main` has no branch protection. It becomes binding only when added to the
required-status-checks list **by name**. Required-by-name is load-bearing (D3):
a workflow that silently never runs on a conflicting PR must read as
"not satisfied", not as an absent/passing check.

```bash
# One-time, needs repo admin. Adds pr-task-gate to the required checks.
gh api -X PATCH repos/:owner/:repo/branches/main/protection/required_status_checks \
  -f 'checks[][context]=PR references an active task'
```

Two human-provisioned prerequisites before flipping it on:
- **`BARKPARK_TASK_TOKEN`** repo secret — a guerrilla write token, so the
  `hotfix!` lane can auto-file its override task. Without it the lane still
  passes (logs a warning); the token only closes the record-keeping gap.
- Optionally `BARKPARK_LEDGER_BASE` repo **variable** to point the gate at a
  different ledger instance (defaults to `https://guerrilla.barkpark.cloud`).

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
