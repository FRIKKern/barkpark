# PDS wave 47 — duplicated charter D-numbers: re-derivation recipe

Every row below re-derives from a clean read. `git show origin/main:` is the authority;
a worktree read is NOT. Taken at `origin/main = 49345a98c1dbd9c768f3312185be0f5483878241`
(charter = 13,698 lines).

```sh
git show origin/main:.claude/workflows/bp-pds-charter.md > /tmp/charter.md
wc -l /tmp/charter.md                                    # 13698
```

| # | claim | command | expected |
|---|---|---|---|
| 1 | 21 D-numbers carry two `PDS-D### —` occurrences | `grep -oE 'PDS-D[0-9]{3} —' /tmp/charter.md \| sort \| uniq -c \| awk '$1>1'` | 21 lines, each count 2: D145 D146 D397-D400 D492-D495 D553-D556 D559 D570-D573 D664 D665 |
| 2 | 577 distinct D-numbers are defined, and every number ever mentioned has an em-dash definition | `grep -oE 'PDS-D[0-9]{3} —' /tmp/charter.md \| grep -oE 'D[0-9]{3}' \| sort -u > /tmp/defs; grep -oE 'PDS-D[0-9]{3}' /tmp/charter.md \| grep -oE 'D[0-9]{3}' \| sort -u > /tmp/all; wc -l < /tmp/defs; comm -13 /tmp/defs /tmp/all \| wc -l` | `577` then `0` — no phantom numbers |
| 3 | D559 is a FALSE duplicate: one definition + one inline parenthetical | `grep -n 'PDS-D559 —' /tmp/charter.md` | `:11859` is inline prose `(CORRECTED wave 39, PDS-D559 — this entry read …)`; only `:12003` is a definition |
| 4 | the collision is systematic — REVIEW-phase vs next-wave DECIDE-phase allocate from the same pointer | `grep -n 'PDS-D664 —\|PDS-D665 —' /tmp/charter.md` | `2654`/`2664` under `### Wave 45 … REVIEWED`; `13311`/`13358` under `## WAVE 46 … DECIDED` |
| 5 | the wave-30 recipe's line numbers for the D399 pair are STALE (charter grew 6,888 → 13,698) | `grep -n '^- \*\*PDS-D399' /tmp/charter.md` | `8625` and `8708` — NOT the `6503`/`6586` recorded in `tooling/grip/ledger/pds-w30-charter-coverage-rederivation.md:14` |
| 6 | `pds-record-parity.sh` axis A resolves citations with `sort -u`, so a number defined TWICE reads as resolved | `git show origin/main:scripts/pds-record-parity.sh \| sed -n '333,335p'` | `grep -oE '^[[:space:]]*([-*][[:space:]]+)?\*\*PDS-D[0-9]+' … \| sort -u > "$defs"` |
| 7 | 24 D-numbers are defined ONLY as `### PDS-D### —` headings and are invisible to that gate lens | `grep -oE '^[[:space:]]*([-*][[:space:]]+)?\*\*PDS-D[0-9]+' /tmp/charter.md \| grep -oE 'PDS-D[0-9]+' \| sort -u > /tmp/bold; comm -13 /tmp/bold <(grep -oE 'PDS-D[0-9]{3} —' /tmp/charter.md \| grep -oE 'PDS-D[0-9]+' \| sort -u)` | 24: D643-D647 D649-D652 D656-D658 D660-D663 D666-D673 |
| 8 | axis A reds TODAY with six FALSE unresolved citations over the real merged-commit corpus | `git log --format=%B origin/main \| grep -oE 'PDS-D[0-9]+' \| sort -u > /tmp/cites; bash scripts/pds-record-parity.sh --axis a --charter /tmp/charter.md --commits-file /tmp/cites` | `defined: 652 · cited: 216 · unresolved: 6` — D644 D649 D656 D661 D666 D667, all six DEFINED as headings; exit 1 |
| 9 | a commit citing PDS-D669 (the decision wave 47 leans on) reds the same arm | `printf 'per PDS-D669 and PDS-D664\n' > /tmp/c2; bash scripts/pds-record-parity.sh --axis a --charter /tmp/charter.md --commits-file /tmp/c2` | `unresolved: 1 · UNRESOLVED-CITATION PDS-D669`; D664 "resolves" — to `:2654`, the wave-45-review finding, not `:13311` |
| 10 | the sharpest live mis-resolution: a criterion demands "the four refutations in PDS-D664" | `sed -n '13311,13330p' /tmp/charter.md` vs `sed -n '2654,2663p' /tmp/charter.md` | `:13311` enumerates exactly four ("Proven from the artifact, four independent ways"); `:2654` (`A REPAIRED PREDICATE CARRIES ITS OLD DEFECT FOR EXACTLY ONE LINE`) has none — and `:2654` is the one the gate lens finds |
| 11 | duplicated numbers are cited in SHIPPED CODE, not only in task bodies | `for n in D145 D397 D398 D399 D400 D493 D559 D572 D573; do echo -n "$n "; git grep -nE "PDS-$n([^0-9]\|$)" origin/main -- . ':!*bp-pds-charter.md' \| wc -l; done` | D400 **9**, D399 6, D145 4, D397 2, D493 2, D559 2, D573 2, D398 1, D572 1 |
| 12 | `pds-record-parity.sh` is NOT wired into CI — the arm is advisory | `git grep -rn 'pds-record-parity' origin/main -- .github/` | no output |
| 13 | the duplicate was already filed and is still open at 0/4 | `bp task get pds-bl-charter-d399-duplicate-identifier` | `lifecycle_status: open`, 0 of 4 criteria met, parent `task-2ac1f95237c4a8e5` |

## Trap recorded

Row 11's obvious shortcut is wrong: `git grep -c PAT REV -- <pathspec> | awk -F: '{s+=$NF}'` printed
`0` for every number while `git grep -n` printed nine real hits — the `-c` form emits
`REV:path:count` and the arithmetic silently ate it. Count the *deciding command's own lines*.
