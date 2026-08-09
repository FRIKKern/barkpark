# The merge-gated close is NOT tool-blocked — 2026-08-09 (wave 58 verify)

Measured live against `guerrilla.barkpark.cloud`, bp `dev`/`0789ab90a`, tree at
`origin/main` `989b19577`. Subject row: `cch-w55-s3-four-console-assertions-the-plane-cannot-support`.

## Verdict

Five waves of zero-close were a **navigation failure**, not a broken verb. A
working recipe exists, was never tried, and closed the row in two commands.
The trap is real: every route the epic's own claim notes and D679 prescribe is
an unrunnable sentence, so "blocked" was a reasonable-looking wrong conclusion.

## The three walls (all reproduced, exit codes verbatim)

| # | Command | Exit | Body |
|---|---|---|---|
| a | `bp task stamp <id> <w> <e> --criterion 11 --met --evidence … --criterion-text "<MERGE-GATED …>"` | **5** | `{"error":{"code":"merge_gated_criterion",…}}` — CLIENT-side (`internal/cli/tasks_stamp_cmd.go`:57), nothing sent |
| b | `bp task close <id> <w> <e> done "…" --merge-gated` | **2** | `{"error":{"code":"usage","message":"unknown flag --merge-gated for task close"}}` |
| c | `bp task close <id> <w> <e> done "…" --set 'criteria:=[{"index":11,"met":true,…}]'` | **2** | `{"error":{"code":"criteria_unmet:11","message":"… not met on the task AS STORED, and criteria flipped in this very close command do not count …"}}` |

## THE WORKING RECIPE

```sh
bp task claim <id> <worker> -o json --yes                    # lapsed claims need this; note the new epoch
bp task stamp <id> <worker> <epoch> --criterion <N> --met \
  --evidence "PR #NNNNN merged <ts>; merge commit <sha>, ancestor of origin/main <sha>. Four required contexts green on HEAD <sha>." \
  --criterion-text "<acceptance_criteria[N].criterion, VERBATIM>" \
  --merge-gated -o json --yes                                # exit 0
bp task get <id> -o json                                     # read met BACK — a printed rev is not persistence
bp task close <id> <worker> <epoch> done "<reason>" -o json --yes   # exit 0
bp task get <id> -o json                                     # lifecycle_status must read 'done'
```

`--merge-gated` is a **stamp-only** flag. It is stripped before dispatch
(`parseStampArgs`, `tasks_stamp_cmd.go`:~295 `continue // CLI-only`), so the
POST carries no override marker — wave 56's audit-trail objection is factually
correct. But the conclusion drawn from it was wrong: the **evidence string is
the audit trail**, it is persisted verbatim, and refusing to use the verb left
the row open instead of leaving it honest.

## Corrections to the charter

- **D679 is wrong on route (c).** It calls `close --set 'criteria:=[…]'` "a
  documented, fully-supported route around the guard". It is not — the server
  refuses it by name. The guard is NOT bypassable that way.
- **D679 is right on route (b)**: exit 2, and the reason is `unknown flag`.
  Four wave-55 claim notes prescribe it verbatim.
- **`bp task close --help` overstates.** It says "Unmet criteria never block a
  close (soft warning only)." Observed: a hard `criteria_unmet:11` at exit 2
  when criteria are flipped in-close. NOT tested: a plain close over a stored
  unmet row. The help text is itself an unsupportable promise.
- **Exit code**: the stamp refusal is **5**, not 2.

## Blast radius

`bp task ls --all --limit 1000` → family 796; live 412 (403 open + 8
in_progress + 1 considering) after this close, from 413. **23 live rows carry
exactly one unmet criterion and it is the MERGE-GATED row** — every one of them
is unblocked by the recipe above, subject to its PR actually being merged.

## Re-derivation

```sh
bp task get cch-w55-s3-four-console-assertions-the-plane-cannot-support -o json
git show origin/main:internal/cli/tasks_stamp_cmd.go | sed -n '50,65p;315,335p'
git grep -n "func runTaskClose" origin/main -- internal/cli/    # EMPTY: no close wrapper, no close tripwire
bp capabilities -o json | grep -c merge                          # 0
bp task close --help                                             # no --merge-gated
```
