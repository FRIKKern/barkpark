# PDS wave 28 — grip-adapter-e2e re-derivation recipe

Verifier `grip-adapter-e2e`, 2026-07-31, from the primary checkout at
`/Volumes/SATECHI/github/barkpark` (local HEAD `a31faa52d`, `origin/main`
`34aca5844`). Node v22.22.0. No grip source was modified; no repo file other
than this one was written.

## 0. The corpus (live board, re-derivable)

    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    for o in 0 1000 2000 3000 4000; do
      curl -s -H "Authorization: Bearer $TOK" \
        "https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=1000&offset=$o&order=_createdAt:asc" \
        -o page$o.json
    done

4022 unique `type:task` rows. Transitive `parent_id` closure from
`task-2ac1f95237c4a8e5` = **357**; live (lifecycle not in the terminal set) =
**190**; live carrying a non-empty `disposition_reason` = **172**.

## 1. The adapter — eleven lines, no fork

    function toFact(row, rerun) {
      return {
        subject: `pds/${row._id}`,
        quantity: null,
        claim: row.title,
        evidence: row.disposition_reason,  // grip's L6-by-construction prose field
        rerun,                             // the ONLY authority input
        observed_at: row._updatedAt,
        deps: [],
      };
    }

Consumed by a direct
`import { adjudicateAll } from "./tooling/grip/adjudicate.mjs"`.

## 2. Re-run the three measurements

    node --version
    node -e 'import("./tooling/grip/adjudicate.mjs").then(m=>console.log(Object.keys(m)))'
    node -e 'import("./tooling/grip/census.mjs").then(m=>console.log(m.CENSUS_TIMEOUT_MS))'

**First contact, all 172 real rows, no reruns** (`{execute:false}`):
`DEMOTED 171 / REJECTED 1`, 1 ms. The single rejection is
`PATHLESS-REF` on `pds-w11-router-export-comment-drift`, whose title is
`router.ex:2460 …` — no directory component. `INADMISSIBLE-CONTINUOUS` = 0.

**24 real rows with hand-authored reruns** (`{execute:true}`): 583 ms,
24 ms/row — `ADMITTED 9 / FAILED 5 / NULL-READ 3 / REJECTED 2 / DEMOTED 5`.

**213 rows all executing an L2 `git show`**: 4886 ms wall, 22.9 ms/row,
3114 ms under `CENSUS_TIMEOUT_MS` 8000. Admission-only over the same 213: 5 ms.

## 3. The refusals, verbatim from the run

    REJECTED:UNSAFE-RERUN  git merge-base --is-ancestor 99f713846 origin/main
      → refused at the caller boundary before execution — write shape: git write verb

    REJECTED:UNSAFE-RERUN  test 0 -eq $(git show …| grep -c completeness)
      → shell metacharacter: command substitution $( )

Admitted substitutes, measured this run: `git branch -r --contains <sha>` L3
ADMITTED; `git rev-list --count <sha>..origin/main` L3; `git cat-file -t <sha>`
L3 ADMITTED (`git cat-file -e` is NULL-READ — it is silent by design);
`git show origin/main:<path> | sed -n Np` L2.

## 4. Two true refutations the floor produced

    git show origin/main:api/.sobelow-skips | wc -l   # 58
    # pds-bl-sobelow-baseline-line-shift-reconcile cites :118 → FAILED

    git show origin/main:api/lib/barkpark/content/close.ex   # path does not exist
    # …| sed -n '544p' exits 0 through the pipe → grip ruled NULL-READ, not a pass
    git ls-tree -r --name-only origin/main | grep -E 'close\.ex$'
    # api/lib/barkpark/tasks/close.ex — the real owner

## 5. The exit-code question, settled

    grep -n 'process.exit' tooling/grip/adjudicate.mjs tooling/grip/record.mjs \
                           tooling/grip/level.mjs tooling/grip/rerun.mjs
    # (no output)

A `FAILED` ruling is fully machine-readable in-process while the node process
exits 0 (`process.exitCode === undefined`, shell `rc=0`). The exit code carries
no verdict on the import path; it exists only in `cli.mjs:375`.
