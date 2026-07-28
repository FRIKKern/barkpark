# felix W23 — gate topology + D75 re-derivation recipes (2026-07-28)

Verifier assignment v4-gate-topology-and-d75. Every row re-derives a load-bearing
fact from scratch. Run from the repo root.

| # | Claim | Command |
|---|---|---|
| 1 | main has NO branch protection | `gh api repos/:owner/:repo/branches/main/protection` → 404 `Branch not protected` |
| 2 | main has NO rulesets | `gh api repos/:owner/:repo/rulesets` → `[]` |
| 3 | S4 excludes paths-filtered checks | `grep -n 'S4 PATHS-FILTERED' scripts/required-checks-generate.sh` |
| 4 | pf is WORKFLOW-level, so it binds every job in security.yml | `sed -n '226,232p' scripts/required-checks-generate.sh` |
| 5 | A BLOCKING security.yml job is still S4-excluded (mix-audit) | `git show origin/main:.github/required-checks.json \| jq -r '.exclusions[] \| select(.reason\|test("security.yml")) \| "\(.context) :: \(.reason)"'` |
| 6 | Nothing is enforced at all today | `git show origin/main:.github/required-checks.json \| jq .enforced` → `false` |
| 7 | D75's only extant written statement is merge-gates.md | `git show origin/main:docs/ops/merge-gates.md \| sed -n '136,145p'`; `grep -rn 'D75' .claude/workflows/*.md` finds no charter defining it |
| 8 | `api/**` MATCHES the dotfile `api/.sobelow-skips` (live GitHub) | `gh pr view 5380 --json files -q '[.files[].path]'` (only `api/.sobelow-skips` + `docs/ops/merge-gates.md`) then `gh run list --commit afc104f01bf3596a814acb24e80486e154a0dd80 --json workflowName,event` → `security pull_request` present |
| 9 | A baseline-only PR also pays the full Elixir suite | same run list: `elixir pull_request success` |
| 10 | Sobelow JOB is still failure on main after #6412 | `gh api repos/:owner/:repo/actions/runs/30342320311/jobs -q '.jobs[]\|[.name,.conclusion]\|@tsv'` |
| 11 | Baseline = 108 entries; unannotatable residue = 10 | `git show origin/main:api/.sobelow-skips \| grep '^[A-Za-z]' \| sed 's/:.*//' \| sort \| uniq -c \| sort -rn` (8 `Config.*` + 2 heex `XSS.Raw`) |
| 12 | elixir.yml is deliberately un-path-filtered; `Elixir gate` aggregates a fixed needs set | `git show origin/main:.github/workflows/elixir.yml \| sed -n '23,33p;606,620p'` |
| 13 | `api/.sobelow-skips` is already inside ELIXIR_COMPILE_PATHS | `printf 'api/.sobelow-skips\n' \| bash scripts/elixir-path-escape-check.sh --match compile` → `true` |
