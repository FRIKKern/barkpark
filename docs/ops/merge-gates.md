# Merge Gates (Phase 2 onward)

> Why a PR cannot be merged until every gate below is green, and how to run
> them locally before pushing.

## Pre-merge gates (as of Phase 2)

A PR targeting `main` must clear:

1. **Static audit** — Reviewer reads the diff for logic, security, and
   architectural fit. Catches most defects but not all (see lessons-learned
   below).
2. **`mix-test` CI job** — `.github/workflows/elixir.yml`, runs:
   `mix format --check-formatted`, `mix compile --warnings-as-errors`,
   `mix test` in the `:dev` environment.
3. **`mix-prod-compile` CI job** — same workflow, depends on `mix-test`.
   Cleans `api/_build/prod`, force-recompiles deps, then runs
   `MIX_ENV=prod mix compile --warnings-as-errors`. **This is the gate.**
4. **`plugin-node` CI job** — `.github/workflows/plugin-node.yml`. Discovers
   plugins under `api/priv/plugins/` whose `plugin.json` declares a top-level
   `"node"` object and runs `npm ci` + lint + typecheck per plugin. Emits a
   no-op success when no plugin declares Node, so the workflow is always
   present in the required-status list.

The branch protection on `main` requires `mix-test` and `mix-prod-compile`
to be green. `plugin-node` is required only when the PR touches
`api/priv/plugins/**`.

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
service failed to restart, and PR #43 (`be53a98 fix(api): move
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
decision documented in the decision log
(`.doey/plans/decision-log.md`) with a reason and a follow-up task to
remove the override. Any merge that lands without the gate green must
be reverted within 24h unless the override entry exists.

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
