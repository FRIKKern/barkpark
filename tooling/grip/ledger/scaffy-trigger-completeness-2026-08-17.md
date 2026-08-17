# Scaffy trigger-completeness — re-derivation recipe (2026-08-17)

Verifier assignment: enumerate every IN-op target across the 22 catalog
commands and diff against the CI path-trigger globs. All facts below are
re-derived against **origin/main** (worktree was behind on unrelated
taskboard/audit-actions paths; scaffy lines identical).

## The full IN-target set (22 commands)

    grep -h '^IN ' scaffy/commands/*.scaffy | awk '{print $2}' | sort -u

40 distinct targets. Non-code-glob extensions: `.heex`, `.js`, `.mjs`,
`.sh`; two token-only paths (`{{.TargetFile}}`, `.../{{.plugin}}.ex`)
that RepoCheck skips-and-counts in CI (no `--var`).

## (a) doc-gates D71 L3 claim — HOLDS

    git show origin/main:.github/workflows/doc-gates.yml | grep -n \
      'scaffy/commands\|app.js\|__app.test.mjs\|barkpark_web/\*\*/\*.heex\|pd-parity-completeness'

Anchor-drift gate step: doc-gates.yml:614 `scaffy validate --repo . scaffy/commands/`.
Every anchored target rides a workflow-level path glob:
- code exts → `**/*.ex|exs|go|ts|tsx|md`
- root.html.heex → `api/lib/barkpark_web/**/*.heex` (104/254) + explicit (43/183)
- pd-parity-completeness.sh → own trigger (147/297)
- cloud/priv/static/app.js + __app.test.mjs → explicit (157-159 / 307-309) —
  the ONLY two anchored surfaces with no code glob.
NO anchored target is unglobbed.

## (b) go-tests.yml census-trap — CONFIRMED, two gaps

    git show origin/main:.github/workflows/go-tests.yml | grep -n 'scaffy\|paths'
    # -> only `paths:` at 18 & 57; ZERO scaffy path.

Go tests that assert against scaffy fixtures, read in place (D30, no embed):
- internal/scaffy/corpus_test.go:25,30 — `../../scaffy/commands`, count pin 22
- internal/scaffy/corpus_jsassert_test.go — JS-assert order guard
- internal/scaffy/lint_test.go:196 / parse_test.go:13 / format_test.go:37 /
  apply_test.go:17 — read `testdata/{red,green,fmt}` (36 non-.go fixtures)

Gap 1: `scaffy/commands/**` — a catalog-only PR runs ZERO Go jobs → ADD.
Gap 2: `internal/scaffy/testdata/**` — a fixture-only PR runs ZERO Go jobs
        (same #963→#969 class as the pdrender/taskboard carve-outs) → ADD.
`scaffy/seed/**` — NO Go test reads it (grep empty); already on
scaffy-catalog-drift.yml → do NOT add to go-tests (inert).

## (c) scaffy-catalog-drift.yml — COMPLETE

    git show origin/main:.github/workflows/scaffy-catalog-drift.yml | grep -n -A6 paths:
    # scaffy/commands/** ; scaffy/seed/** ; internal/scaffy/** ; self ; +daily cron

Covers every surface whose change should re-run drift (command source, served
seed corpus, engine). Server-side out-of-band edits are caught only by the
06:17 cron — correct, no repo path exists for them.
