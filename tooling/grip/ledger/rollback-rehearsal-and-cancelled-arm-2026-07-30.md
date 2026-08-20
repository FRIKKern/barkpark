# Rollback rehearsal + the cancelled arm — re-derivation recipes (wave 10, 2026-07-30)

Every row below was executed on 2026-07-30. `$D` is a clean origin/main tree:

    cd /Volumes/SATECHI/github/barkpark && D=$(mktemp -d) && git archive origin/main | tar -x -C "$D"

The primary checkout was 110 commits behind origin/main (`git rev-list --count HEAD..origin/main` → 110).
Never read scripts/ from the primary checkout for this epic.

## R1 — the undo IS one attributable command, on origin/main only

    cd "$D" && bash scripts/breakglass.sh --open --total --dry-run --reason r --task t; echo "rc=$?"

Expect rc=0 and step `[5/5] WOULD then DELETE repos/FRIKKern/barkpark/branches/main/protection`.

## R2 — the same command REFUSES from the stale primary checkout

    cd /Volumes/SATECHI/github/barkpark && bash scripts/breakglass.sh --open --total --dry-run --reason x --task y; echo "rc=$?"

Expect rc=1 and `REFUSED: unknown argument: --total (try --help)`.
Cause: `--total` / `--narrow` were added to the arg parser after the checkout's HEAD.

    diff <(git show HEAD:scripts/breakglass.sh   | grep -n '^ *--[a-z-]*)') \
         <(git show origin/main:scripts/breakglass.sh | grep -n '^ *--[a-z-]*)')

## R3 — the stale default is NARROW, not total (different DELETE endpoint)

    cd /Volumes/SATECHI/github/barkpark && bash scripts/breakglass.sh --open --dry-run --reason x --task y | tail -4

Expect `DELETE …/protection/enforce_admins` — admin-bypass only. It does NOT remove a
deadlocked required context; it only lets an admin merge past one.

## R4 — apply.sh has NO --dry-run arm, and the committed runbook line refuses

    cd "$D" && grep -c 'dry.run\|DRY_RUN' scripts/required-checks-apply.sh   # expect 0
    cd "$D" && bash scripts/required-checks-apply.sh --disable --confirm; echo "rc=$?"

Expect rc=1, `FAIL: --disable needs --reason`. That command string is the one committed in
`.github/required-checks.json` `_readme[1]`. The runbook must name `breakglass.sh --open --total`.

## R5 — the three decide() bodies are byte-identical

    for f in console-harness cloud elixir; do
      git show origin/main:.github/workflows/$f.yml \
        | sed -n '/^          decide() {/,/^          }/p' | shasum
    done

Expect the same digest three times (measured: `14d6fd82eac9…`, 32 lines each).
The arm is `failure | cancelled)` — FUSED, so a cancelled upstream still concludes `failure`.
honest-gates charter D57 is the governing decision.

## R6 — live protection set (N today)

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      -q '{enforce_admins:.enforce_admins.enabled, checks:[.required_status_checks.checks[].context]}'

Measured: `enforce_admins=true`, checks = `Elixir gate`, `PR references an active task` (N=2).
Registering both aggregators takes N to 4, where honest-gates D38's plural refusal forms
carry counts and categories but never names.

## R7 — a run evicted while PENDING emits NO check run

    for sha in 23313e9a5 1dd553b09 dc17c949e; do
      gh api repos/FRIKKern/barkpark/commits/$sha/check-runs \
        -q '.check_runs[] | select(.name|test("gate$")) | "\(.name)=\(.conclusion)"'
    done

Expect: 23313e9a5 → empty (not even `Elixir gate`); 1dd553b09 → Cloud gate=failure;
dc17c949e → all three success.
