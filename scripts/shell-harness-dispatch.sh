#!/usr/bin/env bash
# shell-harness-dispatch.sh — the `changes` dispatcher of
# .github/workflows/shell-harnesses.yml, as a FILE rather than as an
# interpolated `run:` scalar.
#
# ── WHY IT LIVES HERE AND NOT IN THE WORKFLOW (task-ca50ed283930706a) ────────
# This logic used to be the body of that workflow's `Compute the changed-path
# set per harness` step. It carried two `${{ }}` interpolations, so GitHub
# compiled the WHOLE scalar into one expression and measured it against the
# 21000-character max expression length. On origin/main it was 19968 bytes:
# 1032 under GitHub's cap and 32 under scripts/workflow-run-block-length-check.sh's
# 20000 fail floor. Over the cap the failure is not a red step — it is a
# STARTUP FAILURE with ZERO jobs, every harness in the file dark at once, and
# no local YAML gate can see it because the file is valid YAML (measured
# 2026-09-18, #19291: `Invalid workflow file … Exceeded max expression length
# 21000`).
#
# The roster grows every wave — it is a partition of ~260 workflow paths over
# ~53 harness legs — so the block was on a path to detonate. #19227, #19291 and
# #19317 each had to trade per-file roster rows for globs to stay under it, and
# #19446 had to BACK OUT two rows it needed (98 bytes against 32 available).
# That is the cap deciding the repo's dispatch policy.
#
# Moving the body into this file removes the interpolation entirely: the step
# is now `run: bash scripts/shell-harness-dispatch.sh` with the two GitHub
# values passed as step `env:`, so the scalar is a LITERAL and the expression
# parser never sees it. The roster can grow again.
#
# ── THE CONTRACT WITH THE WORKFLOW ──────────────────────────────────────────
#   EVENT_NAME     github.event_name. Anything other than `pull_request` means
#                  every harness set is true — main is what every PR is
#                  compared against and there is no reviewer left to notice a
#                  partial main.
#   BASE_SHA       github.event.pull_request.base.sha. Empty on a pull_request
#                  is a REFUSAL, never a guess.
#   GITHUB_OUTPUT  the file the per-leg verdicts are appended to.
# cwd is the repo checkout; the git commands read it.
#
# BOTH the workflow file and THIS file are implicit in every set: an edit to
# either changes what every harness means. Neither is a roster row (clause A of
# scripts/shell-harnesses-dispatch.test.sh), and both are entries in the
# workflow's two `paths:` lists so an edit to either starts a run at all — the
# header rule D26, "every script a job here executes gets its own entry".
#
# TESTED BY scripts/shell-harnesses-dispatch.test.sh, which extracts this
# path from the workflow step rather than hardcoding it, runs THIS file over
# mktemp git repos (clause E), and mutates the unresolvable-base guard (its
# MUT anchor, below) out of a scratch copy of it (clause F). That anchor must
# appear EXACTLY ONCE in this file, so do not quote it in prose. `--selftest` below is the
# hermetic arm this file carries on its own.
#
# EXIT CODES: 0 verdicts emitted · 1 refused (an annotated `::error::`) ·
#             2 unknown flag / selftest failure.

# ── selftest ────────────────────────────────────────────────────────────────
# Hermetic: mktemp git repos, no network, no bp. It runs THIS file (via "$0")
# and asserts the exit code AND a substring, so an arm cannot pass on a verdict
# that was reached for the wrong reason. The full 25-arm partition matrix lives
# in scripts/shell-harnesses-dispatch.test.sh — this arm exists so an edit to
# THIS file alone has a gate of its own.
selftest() {
  local tmp rc=0 out code n_legs r self_abs
  # ABSOLUTE. Every arm runs this file from INSIDE a mktemp repo, where a
  # relative "$0" resolves to nothing and every arm would fail rc=127.
  self_abs="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/shdisp.XXXXXX")" || return 2
  local repo="$tmp/repo"
  mkdir -p "$repo"
  g() { git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
  g init -q >/dev/null 2>&1 || { echo "selftest: git init failed" >&2; rm -rf "$tmp"; return 2; }
  mkdir -p "$repo/scripts" "$repo/.github/workflows"
  printf 'a\n' >"$repo/scripts/doctor.sh"
  printf 'a\n' >"$repo/README.md"
  g add -A >/dev/null && g commit -qm base >/dev/null || { echo "selftest: seed commit failed" >&2; rm -rf "$tmp"; return 2; }
  local base; base="$(g rev-parse HEAD)"

  run() { # $1=event $2=base $3=outfile ; sets $code, log at $3.log
    : >"$3"
    ( cd "$repo" && EVENT_NAME="$1" BASE_SHA="$2" GITHUB_OUTPUT="$3" bash "$self_abs" >"$3.log" 2>&1 )
    code=$?
  }
  arm() { # $1=label $2=cond-result(0/1) $3=detail
    if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1: $3"; rc=1; fi
  }

  # 1. NON-PR EVENT — every leg true, and the leg count is DERIVED from the
  #    roster, so a roster that failed to parse cannot green this arm.
  run push "" "$tmp/push.out"
  n_legs="$(grep -c '=true$' "$tmp/push.out" | tr -d ' ')"
  if [ "$code" -eq 0 ] && [ "$n_legs" -ge 20 ] && [ "$(grep -c '=false$' "$tmp/push.out" | tr -d ' ')" -eq 0 ]; then r=0; else r=1; fi
  arm "a push event dispatches every leg ($n_legs legs, none false)" "$r" "rc=$code true=$n_legs false=$(grep -c '=false$' "$tmp/push.out" | tr -d ' ')"

  # 2. A ROSTERED LITERAL selects exactly its own leg. The negative half is
  #    arm 3: same fixture shape, an unrostered path, zero legs true.
  g checkout -q -B case-doctor >/dev/null 2>&1
  printf 'b\n' >"$repo/scripts/doctor.sh"
  g add -A >/dev/null && g commit -qm doctor >/dev/null
  run pull_request "$base" "$tmp/doctor.out"
  out="$(grep '=true$' "$tmp/doctor.out" | sed 's/=true$//' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$code" -eq 0 ] && [ "$out" = "doctor-matrix" ]; then r=0; else r=1; fi
  arm "scripts/doctor.sh dispatches doctor-matrix and nothing else" "$r" "rc=$code true={$out}"

  # 3. NEGATIVE CONTROL — a path no roster row names selects NOTHING, and every
  #    output is still emitted (an absent output reads as a silent false).
  g checkout -q "$base" >/dev/null 2>&1; g checkout -q -B case-none >/dev/null 2>&1
  printf 'b\n' >"$repo/README.md"
  g add -A >/dev/null && g commit -qm none >/dev/null
  run pull_request "$base" "$tmp/none.out"
  if [ "$code" -eq 0 ] && [ "$(grep -c '=true$' "$tmp/none.out" | tr -d ' ')" -eq 0 ] \
    && [ "$(grep -c '=false$' "$tmp/none.out" | tr -d ' ')" -eq "$n_legs" ]; then r=0; else r=1; fi
  arm "an unrostered path selects zero legs, all $n_legs outputs still emitted" "$r" \
    "rc=$code true=$(grep -c '=true$' "$tmp/none.out" | tr -d ' ') false=$(grep -c '=false$' "$tmp/none.out" | tr -d ' ')"

  # 4. THIS FILE IS IMPLICIT IN EVERY SET. It is not a roster row, so if the
  #    implicit branch is ever dropped an edit to the dispatcher would select
  #    NOTHING — the exact silent-skip this whole file exists to prevent.
  g checkout -q "$base" >/dev/null 2>&1; g checkout -q -B case-self >/dev/null 2>&1
  printf 'b\n' >"$repo/scripts/shell-harness-dispatch.sh"
  g add -A >/dev/null && g commit -qm self >/dev/null
  run pull_request "$base" "$tmp/self.out"
  if [ "$code" -eq 0 ] && [ "$(grep -c '=true$' "$tmp/self.out" | tr -d ' ')" -eq "$n_legs" ]; then r=0; else r=1; fi
  arm "an edit to this dispatcher itself dispatches every leg" "$r" \
    "rc=$code true=$(grep -c '=true$' "$tmp/self.out" | tr -d ' ') (want $n_legs)"

  # 5. THE WORKFLOW FILE is implicit too — the property arm 4 inherited.
  g checkout -q "$base" >/dev/null 2>&1; g checkout -q -B case-wf >/dev/null 2>&1
  printf 'b\n' >"$repo/.github/workflows/shell-harnesses.yml"
  g add -A >/dev/null && g commit -qm wf >/dev/null
  run pull_request "$base" "$tmp/wf.out"
  if [ "$code" -eq 0 ] && [ "$(grep -c '=true$' "$tmp/wf.out" | tr -d ' ')" -eq "$n_legs" ]; then r=0; else r=1; fi
  arm "an edit to the workflow file dispatches every leg" "$r" \
    "rc=$code true=$(grep -c '=true$' "$tmp/wf.out" | tr -d ' ')"

  # 6. REFUSALS, both named. A missing base and an unresolvable base each exit 1
  #    with ZERO outputs — a partial output file would read as a set of falses.
  run pull_request "" "$tmp/nobase.out"
  if [ "$code" -eq 1 ] && grep -q 'no base sha' "$tmp/nobase.out.log" && [ ! -s "$tmp/nobase.out" ]; then r=0; else r=1; fi
  arm "an empty base sha is refused (rc=1, zero outputs)" "$r" "rc=$code"
  run pull_request "dddddddddddddddddddddddddddddddddddddddd" "$tmp/badbase.out"
  if [ "$code" -eq 1 ] && grep -q 'is not resolvable in this checkout' "$tmp/badbase.out.log" && [ ! -s "$tmp/badbase.out" ]; then r=0; else r=1; fi
  arm "an unresolvable base sha is refused (rc=1, zero outputs)" "$r" "rc=$code"

  # 7. AN UNKNOWN ARGUMENT NEVER PASSES. A typo'd flag that exits 0 is a
  #    dispatcher that silently stopped dispatching.
  out="$( "$self_abs" --nope 2>&1 )"; code=$?
  if [ "$code" -eq 2 ] && printf '%s' "$out" | grep -q "unknown argument"; then r=0; else r=1; fi
  arm "an unknown argument exits 2" "$r" "rc=$code out=$out"

  rm -rf "$tmp"
  if [ "$rc" -eq 0 ]; then echo "selftest: 8/8 arms passed"; else echo "selftest: FAILED"; fi
  return "$rc"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") ;;
  *)
    echo "shell-harness-dispatch: unknown argument '$1'" >&2
    echo "usage: $0 [--selftest]   (normal use: EVENT_NAME=… BASE_SHA=… GITHUB_OUTPUT=… $0)" >&2
    exit 2 ;;
esac

set -euo pipefail

# One row per (job, path). The first column is the job id, the second
# a VERBATIM entry of this workflow's on.pull_request.paths (globs
# included — bash `case` matches them, and `**` reads as `*`). Rows
# come from the grouped comments of that list plus each job's steps:
# a script a job sources or reads (scripts/lib/check-runs.sh,
# scripts/pr-task-gate.sh, .github/workflows/*.yml for the corpus
# readers) is a row for every job that consumes it. When in doubt a
# path is IN — over-running a harness is cheap; a false skip is the
# defect. This workflow file is in every set implicitly (see below)
# and is deliberately not a row.
#
# AXIS D'S CORPUS IS TWO GLOBS, AND THEY ARE ROWS (task-74f54db3b1f353d2).
# scripts/pds-record-parity.sh --axis d resolves the PDS-D literals carried
# in `scripts/pds-*.sh` + `tooling/pds/**` against the charter, and the
# pds-harnesses job runs that arm. Both globs were added to the paths lists
# when axis d landed; NEITHER got a roster row, so the half that dispatches
# the workflow and the half that selects the job disagreed: an edit to
# scripts/pds-secret-scan.sh started a run in which every one of the 48 jobs
# was skipped. Neither glob is an exclusion — a PREDICATE, not the
# enumerated pds rows above, is what makes the corpus and the roster the
# same set. The enumerated rows stay: they are cheap, and several name
# inputs (the charter, docs/setup/personal-local.md) the globs do not cover.
roster='
node-test-floor scripts/node-test-floor.mjs
node-test-floor scripts/node-test-floor.test.sh
node-test-floor sdk/package.json
node-test-floor web/package.json
node-test-floor apps/hundesteder/package.json
node-test-floor templates/search-starter/package.json
node-test-floor templates/astro-search-starter/package.json
node-test-floor .github/workflows/hundesteder.yml
node-test-floor .github/workflows/astro-search-finder-test.yml
node-test-floor .github/workflows/search-starter-smoke.yml
task-dup-sweep scripts/task-dup-sweep.mjs
task-dup-sweep scripts/fixtures/task-dup-sweep-selftest.json
doctor-matrix scripts/doctor.sh
doctor-matrix scripts/doctor.test.sh
doctor-matrix scripts/lib/bp-staleness.sh
merge-verb-table scripts/bp-merge.sh
merge-verb-table scripts/bp-merge.test.sh
merge-verb-table scripts/merge-check.sh
merge-verb-table scripts/required-checks-verify.sh
merge-verb-table scripts/lib/check-runs.sh
merge-verb-table scripts/lib/check-runs.test.sh
release-scan-verdict scripts/release-scan.sh
release-scan-verdict scripts/release-scan.test.sh
release-curator-draft-guard scripts/release-curator-draft.sh
release-curator-draft-guard scripts/release-curator-draft.test.sh
release-curator-draft-guard .github/workflows/release-curator-draft.yml
zero-criteria-census scripts/epic-zero-criteria-census.sh
zero-criteria-census scripts/ledger-epic-roster.sh
webhook-fanout-guard scripts/webhook-fanout-watch.sh
webhook-fanout-guard scripts/webhook-fanout-watch.test.sh
seal-run-guard scripts/seal-run.sh
seal-run-guard scripts/seal-run.test.sh
seal-run-guard cloud/priv/static/__preview__/seal-predicate.mjs
seal-run-guard .github/workflows/cloud.yml
registration-sample-bar scripts/registration-sample.sh
registration-sample-bar scripts/registration-sample.test.sh
registration-sample-bar scripts/lib/check-runs.sh
registration-sample-bar scripts/cloud-path-escape-check.sh
registration-sample-bar scripts/console-path-escape-check.sh
deploy-convergence scripts/deploy-convergence-check.sh
deploy-convergence scripts/deploy-convergence-check.test.sh
deploy-convergence .github/workflows/deploy.yml
deploy-concurrency scripts/deploy-concurrency-check.sh
deploy-concurrency scripts/deploy-concurrency-check.test.sh
deploy-concurrency scripts/main-run-concurrency-check.sh
deploy-concurrency scripts/deploy-supersede-exit.sh
deploy-concurrency scripts/deploy-supersede-exit.test.sh
deploy-concurrency .github/workflows/deploy.yml
deploy-concurrency .github/workflows/*.yml
console-path-ratchet scripts/console-path-escape-check.sh
console-path-ratchet scripts/console-path-escape-check.test.sh
console-path-ratchet .github/workflows/console-harness.yml
console-path-ratchet scripts/cloud-console-gate-shape.test.sh
console-path-ratchet .github/workflows/cloud.yml
console-path-ratchet .github/workflows/elixir.yml
console-refusal-capture scripts/console-refusal-capture.mjs
console-refusal-capture scripts/*.test.mjs
weekly-changelog-backfill-guard scripts/weekly-changelog-backfill.test.sh
weekly-changelog-backfill-guard .github/workflows/weekly-changelog.yml
pds-harnesses scripts/pds-ledger-census.sh
pds-harnesses scripts/pds-ledger-census_test.sh
pds-harnesses scripts/pds-record-parity.sh
pds-harnesses scripts/pds-record-parity.test.sh
pds-harnesses scripts/pds-secret-scan.sh
pds-harnesses scripts/pds-secret-scan_test.sh
pds-harnesses .claude/workflows/bp-pds-charter.md
pds-harnesses tooling/pds/d-number-reservations.tsv
pds-harnesses .claude/workflows/bp-deploy-reliability-charter.md
pds-harnesses deploy/d-number-reservations.tsv
pds-harnesses deploy/d-number-arbiter.sh
pds-harnesses scripts/pds-*.sh
pds-harnesses tooling/pds/**
pds-harnesses scripts/pds-scratch-target.sh
pds-harnesses scripts/pds-scratch-target_test.sh
pds-harnesses scripts/pds-read-preflight-audit.sh
pds-harnesses scripts/pds-read-preflight-audit_test.sh
pds-harnesses scripts/pds-threshold-move-guard.sh
pds-harnesses scripts/pds-threshold-move-guard_test.sh
pds-harnesses scripts/pds-crown-stamp.sh
pds-harnesses scripts/pds-personal-local-smoke_test.sh
pds-harnesses docs/setup/personal-local.md
pds-harnesses scripts/pr-task-gate.sh
pds-harnesses api/lib/barkpark/tasks/*.ex
pds-harnesses internal/taskboard/*.go
pds-harnesses internal/cli/tasks_next_cmd.go
pds-harnesses docs/contracts/canonical-impl-markers.md
pds-harnesses scripts/pds-*.py
ci-failure-issue-filer scripts/file-ci-failure-issue.sh
ci-failure-issue-filer scripts/file-ci-failure-issue.test.sh
distribution-harnesses scripts/install-cli.sh
distribution-harnesses scripts/install-cli.test.sh
distribution-harnesses scripts/fetch-prebuilt.sh
distribution-harnesses scripts/fetch-prebuilt.test.sh
distribution-harnesses scripts/deploy-rebuild.sh
distribution-harnesses scripts/deploy-rebuild.test.sh
distribution-harnesses deploy/site-runtime-install.sh
distribution-harnesses deploy/site-runtime-install_test.sh
tooling-harnesses tooling/task-obsession/reland_check.py
tooling-harnesses tooling/task-obsession/reland_check.test.sh
tooling-harnesses tooling/task-obsession/reland_fetch.py
tooling-harnesses tooling/task-obsession/reland_workflow_sim.py
tooling-harnesses tooling/task-obsession/reland_loudfail.test.sh
tooling-harnesses tooling/task-obsession/fixtures/*.json
tooling-harnesses .github/workflows/reland-check.yml
tooling-harnesses tooling/fleet/fleet-run.sh
tooling-harnesses tooling/fleet/fleet-run-verdict-test.sh
tooling-harnesses tooling/fleet/spend-aggregate.py
tooling-harnesses tooling/fleet/spend-aggregate.test.sh
tooling-harnesses scripts/audit-paper-readers.sh
tooling-harnesses scripts/audit-paper-readers-test.sh
tooling-harnesses scripts/paper_structure.py
tooling-harnesses scripts/paper_structure_test.py
tooling-harnesses tooling/gate-map/gate-map.mjs
tooling-harnesses tooling/gate-map/gate-map.test.mjs
tooling-harnesses scripts/relandcheck-diff-producer.test.sh
tooling-harnesses .github/workflows/go-tests.yml
tooling-harnesses scripts/go-path-escape-check.sh
tooling-harnesses scripts/go-path-escape-check.test.sh
tooling-harnesses scripts/main-red-breaker.sh
tooling-harnesses scripts/main-red-breaker.test.sh
tooling-harnesses scripts/main-red-breaker.runner-local.json
tooling-harnesses scripts/breaker-capture.sh
tooling-harnesses scripts/stale-tree-regression-check.sh
tooling-harnesses scripts/stale-tree-ci-wiring.test.sh
tooling-harnesses scripts/breaker-step-names-drift.test.sh
tooling-harnesses .github/workflows/required-checks-drift.yml
tooling-harnesses .github/workflows/doc-gates.yml
tooling-harnesses .github/workflows/security.yml
tooling-harnesses .github/workflows/compose-smoke.yml
tooling-harnesses .github/workflows/go-format.yml
tooling-harnesses scripts/console-slice-gate.mjs
tooling-harnesses scripts/console-slice-gate.test.mjs
launcher-boot-selftest bin/barkpark
launcher-boot-selftest scripts/barkpark-boot-selftest.sh
workflow-portability scripts/workflow-portability-check.sh
workflow-portability scripts/workflow-portability-check.test.sh
workflow-portability scripts/workflow-module-exec-smoke.sh
workflow-portability scripts/workflow-module-exec-smoke.test.sh
workflow-portability .claude/workflows/*.workflow.js
workflow-portability scripts/workflow-run-shell-check.sh
workflow-portability .github/workflows/*.yml
breaker-measure-precondition scripts/breaker-measure-precondition.sh
breaker-measure-precondition scripts/breaker-measure-precondition.test.sh
breaker-measure-precondition scripts/ci-measure.sh
breaker-measure-precondition scripts/main-red-breaker.sh
exit-runner-guard scripts/deploy-reliability-exit-run.sh
exit-runner-guard scripts/deploy-reliability-exit-run.test.sh
exit-runner-guard internal/cloudclient/client.go
exit-runner-guard internal/cli/cloud_deploy_census_cmd.go
exit-runner-guard scripts/deploy-reliability-exit-2026-08-10.md
exit-runner-guard scripts/check-doc-budgets.sh
exit-runner-guard scripts/seal-run.sh
cloud-static-gz scripts/cloud-static-gz-guard.sh
cloud-static-gz cloud/priv/static/**
cloud-static-gz cloud/.gitignore
cloud-static-gz cloud/Dockerfile
cloud-static-gz cloud/lib/barkpark_cloud/web/router.ex
pds-hetzner-offline scripts/pds-live-hetzner-placement-group.sh
pds-hetzner-offline scripts/pds-live-hetzner-placement-group_test.sh
pds-hetzner-offline scripts/lib/pds-live-lib.sh
pds-hetzner-offline internal/cli/testdata/pds_live_hetzner_*.json
task-lease-renew scripts/task-lease-renew.sh
task-lease-renew scripts/task-lease-renew.test.sh
task-lease-renew scripts/task-lease-sweep.sh
task-lease-renew scripts/task-lease-sweep.test.sh
task-lease-renew .github/workflows/task-lease-renew.yml
task-lease-renew scripts/pr-task-gate.sh
merge-sweep-review-hold .claude/skills/orchestrate-tasks/helpers/merge-sweep.sh
merge-sweep-review-hold .claude/skills/orchestrate-tasks/helpers/merge-sweep.test.sh
landed-mark scripts/landed-mark.sh
landed-mark scripts/landed-mark.test.sh
landed-mark scripts/fixtures/landed-mark/**
landed-mark scripts/pr-task-gate.sh
landed-mark .github/workflows/landed-mark.yml
landed-mark scripts/landed-open-report.sh
landed-mark scripts/landed-open-report.test.sh
landed-mark scripts/lib/landed_open_report.py
landed-mark scripts/landed-open-report-schedule.sh
landed-mark scripts/landed-open-report-schedule.test.sh
landed-mark .github/workflows/landed-open-report.yml
landed-mark scripts/stale-pr-citation-detector.sh
doc-gates-paths-parity scripts/doc-gates-paths-parity-check.sh
doc-gates-paths-parity .github/workflows/doc-gates.yml
merge-gate-bridge scripts/github-webhook-subscription-parity.sh
merge-gate-bridge scripts/github-webhook-subscription-parity.test.sh
merge-gate-bridge scripts/merge-gate-autostamp-liveness.sh
merge-gate-bridge scripts/merge-gate-autostamp-liveness.test.sh
merge-gate-bridge api/lib/barkpark_web/controllers/github_webhook_controller.ex
merge-gate-bridge scripts/github-app-bootstrap.py
merge-gate-bridge docs/ops/github-sync.md
fleet-coordination-harnesses scripts/already-fixed.sh
fleet-coordination-harnesses scripts/already-fixed.test.sh
fleet-coordination-harnesses scripts/branch-owner.sh
fleet-coordination-harnesses scripts/branch-owner.test.sh
fleet-coordination-harnesses scripts/pr-overlap.sh
fleet-coordination-harnesses scripts/pr-overlap.test.sh
principal-gate-harnesses scripts/media-smoke.sh
principal-gate-harnesses scripts/pdf-efficiency-proof.sh
principal-gate-harnesses scripts/pdf-kill-listener-proof.sh
principal-gate-harnesses scripts/lib/principal-gate.sh
compose-smoke-dispatcher scripts/compose-smoke-dispatch.test.sh
compose-smoke-dispatcher .github/workflows/compose-smoke.yml
compose-smoke-dispatcher scripts/env-census.py
compose-smoke-dispatcher scripts/compose-smoke.sh
compose-smoke-dispatcher scripts/compose-smoke.test.sh
workflow-trigger-coverage scripts/workflow-trigger-coverage.sh
workflow-trigger-coverage scripts/workflow-trigger-coverage.test.sh
workflow-trigger-coverage .github/workflows/*.yml
undispatched-target scripts/undispatched-target-check.sh
undispatched-target scripts/*-path-escape-check.sh
undispatched-target .github/workflows/*.yml
dispatch-selftest scripts/shell-harnesses-dispatch.test.sh
dispatch-selftest .github/shell-harness-legs.json
dispatch-selftest .github/shell-harness-check-runs.txt
dispatch-selftest scripts/shell-harness-matrix.py
dispatch-selftest scripts/shell-harness-run.sh
dispatch-selftest scripts/shell-harness-name-census.sh
orphan-harnesses scripts/local-update.sh
orphan-harnesses scripts/local-update.test.sh
orphan-harnesses scripts/lib/bp-staleness.sh
orphan-harnesses scripts/pdf-efficiency-proof.sh
orphan-harnesses scripts/pdf-efficiency-proof.test.sh
orphan-harnesses scripts/refute-on-absence-capture-log-check.sh
orphan-harnesses scripts/refute-on-absence-capture-log-check.test.sh
selftest-wiring-census scripts/selftest-wiring-census.sh
selftest-wiring-census scripts/*.test.sh
selftest-wiring-census scripts/*.test.mjs
selftest-wiring-census scripts/*_test.sh
selftest-wiring-census scripts/*-selftest.sh
claim-health scripts/ledger/claim-health.sh
claim-health scripts/ledger/claim-health-selftest.sh
selftest-wiring-census .github/workflows/*.yml
registry-impact-check scripts/registry-impact-check.sh
registry-impact-check scripts/registry-impact-check.test.sh
exit-laundering-sweep scripts/exit-laundering-sweep.sh
workflow-owner scripts/workflow-owner-check.sh
workflow-owner scripts/ci-pr-checkrun-floor.sh
workflow-owner .github/workflow-owners.json
workflow-owner .github/workflows/*.yml
workflow-owner .github/required-checks.json
which-gates scripts/which-gates.sh
which-gates scripts/which-gates.test.sh
which-gates scripts/cloud-path-escape-check.sh
which-gates cloud/test/barkpark_cloud/payload_key_set_census_test.exs
which-gates internal/cloudclient/**
which-gates scripts/console-path-escape-check.sh
which-gates scripts/go-path-escape-check.sh
which-gates .github/workflows/cloud.yml
which-gates .github/workflows/console-harness.yml
which-gates .github/workflows/go-tests.yml
orchestrate-launch-recipe scripts/orchestrate-launch-recipe.test.sh
orchestrate-launch-recipe .claude/skills/orchestrate-tasks/SKILL.md
orchestrate-launch-recipe .claude/skills/orchestrate-tasks/LEAD-BRIEF.md
orchestrate-launch-recipe .claude/skills/orchestrate-tasks/helpers/*.sh
bp-curl scripts/lib/bp-curl.sh
bp-curl scripts/lib/bp-curl.test.sh
migration-version-collision scripts/migration-version-collision-check.sh
migration-version-collision .github/workflows/cloud.yml
main-workflow-rollup scripts/main-workflow-rollup.sh
main-workflow-rollup scripts/main-workflow-rollup.test.sh
main-workflow-rollup .github/required-checks.json
scheduled-arm-health scripts/scheduled-arm-health.sh
scheduled-arm-health scripts/scheduled-arm-health.test.sh
scheduled-arm-health .github/workflows/studio-journey-smoke.yml
landed-mark scripts/lib/bp-curl.sh
task-lease-renew scripts/lib/bp-curl.sh
deploy-receipt-honesty scripts/deploy-receipt-failure.test.sh
deploy-receipt-honesty Makefile
deploy-receipt-honesty .githooks/post-merge
deploy-receipt-honesty scripts/deploy-rebuild.sh
deploy-receipt-honesty scripts/merged-at-committer-tripwire.sh
deploy-receipt-honesty scripts/merged-at-committer-tripwire.test.sh
deploy-receipt-honesty .github/workflows/deploy.yml
place-directory-install templates/place-directory/install.sh
place-directory-install templates/place-directory/seed-places.json
place-directory-install templates/place-directory/schemas/place.json
place-directory-install scripts/*.test.sh
sunset-route-consumers scripts/sunset-route-consumers.test.sh
sunset-route-consumers scripts/deploy-rebuild.sh
sunset-route-consumers scripts/compose-smoke.sh
sunset-route-consumers scripts/pds-scratch-target.sh
sunset-route-consumers scripts/create-quickstart-smoke.sh
sunset-route-consumers docker-compose.yml
sunset-route-consumers internal/cli/cloud/support.go
sunset-route-consumers deploy/README.md
sunset-route-consumers deploy/uptime-kuma/README.md
mix-test-strict scripts/mix-test-strict.sh
mix-test-strict scripts/mix-test-strict.test.sh
scratchpad-reaper scripts/scratchpad-reaper.sh
scratchpad-reaper scripts/scratchpad-reaper.test.sh
scratchpad-reaper scripts/disk-headroom-guard.sh
'
self=".github/workflows/shell-harnesses.yml"
self_script="scripts/shell-harness-dispatch.sh"

refuse() {
  echo "::error::dispatcher: $1"
  exit 1
}

# The job list is DERIVED from the roster, in first-appearance order,
# so a job cannot be dispatched without at least one row.
jobs="$(printf '%s\n' "$roster" | awk 'NF { print $1 }' | awk '!seen[$0]++')"
[ -n "$jobs" ] || refuse "the roster is empty — nothing to dispatch."

emit_all() {
  for j in $jobs; do
    echo "${j}=$1" >> "$GITHUB_OUTPUT"
  done
  echo "verdict: every harness=$1"
}

event="${EVENT_NAME:-}"
if [ "$event" != "pull_request" ]; then
  # push-to-main (and anything else): NEVER skip. Main is what every
  # PR is compared against and there is no reviewer left to notice a
  # partial main.
  echo "event '$event' is not a pull_request — every harness set is true."
  emit_all true
  exit 0
fi

base="${BASE_SHA:-}"
[ -n "$base" ] || refuse "the PR carries no base sha. Refusing to guess — a guessed base skips harnesses and reports green."

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  # Absent during burst merges. Try once, then give up LOUDLY.
  git fetch --no-tags --quiet origin "$base" 2>/dev/null || true
fi
git cat-file -e "${base}^{commit}" 2>/dev/null || refuse "PR base sha ${base} is not resolvable in this checkout. Refusing to emit a path verdict from an unknown base." # MUT: unresolvable-base

# No common ancestor makes the three-dot diff exit 128 with a raw
# `fatal:` and no annotation. Name it, and refuse a two-dot fallback,
# which sweeps in the base's ENTIRE content and dispatches true for
# the wrong reason.
git merge-base "$base" HEAD >/dev/null 2>&1 || refuse "PR base ${base} and HEAD share NO common ancestor, so the three-dot diff is undefined. Rebase the branch onto its base branch."

echo "diff base: ${base} (three-dot against HEAD)"
# `-z` + `--no-renames` are both load-bearing (measured in
# security.yml): plain --name-only QUOTES odd paths so they miss the
# match, and rename detection prints only the destination.
changed="$(git -c core.quotepath=false diff -z --name-only --no-renames "${base}...HEAD" | tr '\0' '\n')"
echo "changed files:"
printf '%s\n' "$changed"

if [ -z "$changed" ]; then
  # RARE BUT LEGAL: a revert pair or a branch-sync PR nets to nothing.
  # Run everything: expensive, never wrong. Never false.
  echo "::warning::dispatcher: the changed-file set is EMPTY against ${base}. Dispatching every harness rather than skipping any — a skip here would green a check nothing measured."
  emit_all true
  exit 0
fi

hits=" "
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ "$f" = "$self" ] || [ "$f" = "$self_script" ]; then
    # BOTH of these are in EVERY set: an edit to the roster, the gating or
    # a step changes what every harness means. The roster moved OUT of the
    # workflow into this file, so this file inherits that property — it is
    # deliberately NOT a roster row (see clause A).
    echo "$f changed — every harness set is true."
    emit_all true
    exit 0
  fi
  while read -r job pat; do
    [ -n "$job" ] || continue
    # The roster entry IS a glob (cloud/priv/static/**, *.yml) and
    # must match as one; quoting it would match literally. SC2254.
    # shellcheck disable=SC2254
    case "$f" in
      $pat)
        case "$hits" in
          *" $job "*) ;;
          *) hits="${hits}${job} " ;;
        esac
        ;;
    esac
  done <<EOF
$roster
EOF
done <<EOF
$changed
EOF

for j in $jobs; do
  case "$hits" in
    *" $j "*) v=true ;;
    *) v=false ;;
  esac
  echo "verdict: ${j}=${v}"
  echo "${j}=${v}" >> "$GITHUB_OUTPUT"
done