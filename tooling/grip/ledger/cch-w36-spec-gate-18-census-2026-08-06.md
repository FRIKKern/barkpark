# cch-w36 — §18 protection-claim census: re-derivation recipes (2026-08-06)

Scope: why `Required-check spec gate` is RED on origin/main `070c7584b`, and the two
candidate fixes measured side by side. Every row below is a command, not a claim.

NOTE ON THIS FILE: it is a dated record (class C/D under §18's own taxonomy). It
deliberately avoids re-typing §18's matched phrasings outside a tool argument, so
that it does not itself become an UNPINNED census row. See row 7.

## 1. The local checkout is NOT main — check before quoting anything

    cd /Volumes/SATECHI/github/barkpark
    git rev-parse HEAD origin/main
    git merge-base HEAD origin/main | xargs git log --oneline -1

Measured: HEAD `a31faa52d`, origin/main `070c7584b`, merge-base `98f95be6b`.
Running `scripts/required-checks-verify.sh` in that tree prints
`2 required context(s), enforced=false` — a PRE-FLIP spec. On origin/main the same
script prints `4 required context(s), enforced=true` and exits OK. Quote the tree.

## 2. Reproduce the failure on origin/main, in a detached worktree

    git worktree add --detach /tmp/om070 070c7584b
    cd /tmp/om070 && bash scripts/required-checks.test.sh --hermetic 2>&1 | tail -30

Deciding line: `required-checks: 115 passed, 1 failed (hermetic — the API stage was skipped)`.
Sole failing clause: §18, `11 UNPINNED + 2 STALE`.

## 3. The four non-ledger UNPINNED rows (read the file, not the CI log)

The §18 header block itself predicts `bp-cloud-console-hardening-charter.md:4496`.
On origin/main the real line is `:4567`. Pins are keyed on `sha12(path|text)`, so
line numbers in the pin list are decorative annotations — content-hash is truth.

    UNPINNED 89ed1af64d9b  .claude/workflows/bp-cloud-console-hardening-charter.md:1539
    UNPINNED 6d06875ebcb3  .claude/workflows/bp-cloud-console-hardening-charter.md:4567
    STALE    ce745c039e38  (pinned as charter:1412)
    STALE    562eb5d348c9  (pinned as charter:4282)

## 4. Is `tooling/grip/ledger/**` in scope by design?

    git log --oneline --all -S'PROTECTION_SCAN=' -- scripts/required-checks.test.sh

One commit: `25b00e4c2` (#9790) — the same commit that CREATED §18. Not a widening.
§18's own header names the standing cost and names ledger-scoping as the honest
alternative if the per-wave pin chore stops being paid.

## 5. The two candidate fixes, measured

Harness (writes nothing into the repo; drives §18's own scan shape):

    R=/tmp/om070
    RE='(no|No|NO|zero|Zero) branch protection|main is NOT PROTECTED|no CI check in this repo can block a merge'
    SCAN=(.claude/workflows .github docs scripts tooling/grip/ledger CLAUDE.md ':!scripts/required-checks.test.sh')
    ( cd "$R" && git grep --untracked -lE "$RE" -- "${SCAN[@]}" ) \
      | ( cd "$R" && tr '\n' '\0' | xargs -0 grep -nHE "$RE" )   # -> 41 rows

| design | rows | removes |
|---|---|---|
| raw (today) | 41 | — |
| LEDGER-SCOPING (`grep -v '^tooling/grip/ledger/'`) | 27 | all 14 ledger rows |
| QUOTED-PATTERN FENCE v4 | 33 | exactly 8 pattern-quoting rows |

Fence v4 predicate — the phrase must sit INSIDE the quoted argument of a search
tool (or a regex assignment) on that line; mere co-occurrence is not enough:

    Q="[\"'\\\`]"
    F4="((git[[:space:]]+)?(grep|rg|ag)[[:space:]][^|]*|[A-Z_]*RE=)${Q}[^\"'\\\`]*(${RE})"
    ... | grep -vE "$F4"

Removed by v4 (8): charter:391 (D106, currently PINNED as `965d722b53f6`) and the
seven wave-35 ledger rows at `cch-w35-merge-half-gate:102,117` and
`cch-w35-protection-claim-census:21,36,48,110,111`.

Consequence for the fix commit: UNPINNED drops 11 -> 4, and `965d722b53f6` must be
dropped as STALE in the SAME commit, alongside `ce745c039e38` and `562eb5d348c9`.
The four survivors (`89ed1af64d9b`, `6d06875ebcb3`, `798c02f0775f`, `041309eecfc1`)
are genuine dated retractions/records and are exactly what a human pin is for.

## 6. PROOF THAT EACH DESIGN CAN STILL LOSE

Three untracked specimens, then delete them:

    printf 'Merge freely: this repo has %s, so nothing blocks main.\n' \
      "$(printf 'no branch pro'; printf 'tection')" > $R/docs/ops/_planted-live-claim.md
    printf 'Reminder for reviewers: main has %s (grep -rn to confirm).\n' \
      "$(printf 'no branch pro'; printf 'tection')" > $R/docs/ops/_planted-evasive-claim.md
    printf 'note: main %s today\n' "$(printf 'is NOT PROT'; printf 'ECTED')" \
      > $R/tooling/grip/ledger/_planted-ledger-claim.md

Result (each specimen either FIRES or ESCAPES):

| specimen | ledger-scoping | fence v4 |
|---|---|---|
| plain live claim in `docs/ops/` | FIRES | FIRES |
| evasive claim co-mentioning a tool | FIRES | FIRES |
| live claim written into a ledger file | **ESCAPES** | FIRES |

Ledger-scoping is a real hole: a ledger is exactly where a wave writes its
"main is …" reading, so the class the census exists to catch is the class the
exemption blinds it to. The fence keeps the whole corpus scanned. RECOMMEND the
fence; the fix commit must ship both planted specimens as MUTATION clauses beside
§18's existing two.

Known escape of the fence, written down rather than discovered: a live claim typed
INSIDE a fake tool invocation (`grep -rn "…"` with a real assertion in the quotes)
is exempted. That is the same pinned-census limit §18 already states for
paraphrase, and it is narrower than the ledger hole.

## 7. The exclusions block is GENERATED — regeneration would destroy narrative

    git show origin/main:scripts/required-checks-generate.sh | grep -c "CORRECTED IN REVIEW 2026-07-31"   # -> 0
    git show origin/main:.github/required-checks.json        | grep -c "CORRECTED IN REVIEW 2026-07-31"   # -> 4

Four hand-maintained corrections live ONLY in the committed JSON (`_readme[4]`, and
the `Required-check spec gate`, `Security gate`, `Dependency CVE audit …` exclusion
reasons). The generator's `EXCLUDED_BY_DECISION_REASONS` (generate.sh:145-148) holds
DIFFERENT, older wording. A plain regeneration rewrites all four. Any wave that
regenerates must re-apply them by hand or move them into the generator first.

## 8. The spec-gate exclusion's own re-evaluation trigger is dead

    gh pr view 8222 --json number,state,mergedAt   # -> {"state":"CLOSED","mergedAt":null}

The reason says "Re-evaluate once #8222 lands or is rebased." #8222 is CLOSED and
never merged, so the trigger can never fire. The same reason asserts the job is
"structurally clean and green on main" — falsified by row 2. Registering
`Required-check spec gate` as a fifth required context today would deadlock main
under `enforce_admins: true`.
