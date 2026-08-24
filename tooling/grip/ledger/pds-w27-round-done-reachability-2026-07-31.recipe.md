# PDS w27 — re-derivation recipe: is `--assert-round-done` exit 0 reachable?

Verifier `round-done-reachability`, 2026-07-31. Every number below is re-derived by
running these commands; none is quoted from a Paper or a charter line.

> **The census self-test now runs in CI** — `.github/workflows/shell-harnesses.yml`,
> job `pds-harnesses`, step `pds-ledger-census ordering + response-shape matrix`,
> triggered on any change to `scripts/pds-ledger-census*.sh`. Re-running the recipe
> below by hand is no longer how the instrument is kept honest
> (pds-bl-census-runs-in-no-ci-gate).

## 1. The certifying run (TRUE exit code — never pipe it to `tail`)

    # A DEDICATED scratch dir, never a bare `cd /tmp`: /tmp is the most
    # scratch-file-polluted directory on the host, and the census reads code
    # relative to its CWD — the shadowing hazard pds-w28-census-isolation fixed.
    work=$(mktemp -d) && cd "$work"
    git -C <repo> show origin/main:scripts/pds-ledger-census.sh > c.sh
    bash c.sh --assert-round-done --anchor-from-paper pds-wave-27-2026-07-31 > cen27.txt 2>&1; echo "REAL_RC=$?"
    tail -22 cen27.txt

`bash c.sh ... | tail -14` prints the FAIL block and exits **0** — `tail`'s code, not the
census's. That is the epic's own law violated in the proof harness. Always capture `$?`
from the census itself.

Baseline 2026-07-31: `REAL_RC=1`; clause 1 `183 == 183 PASS`, clause 3 `15 FAIL`,
clause 4(a) `156/186 FAIL`, RESIDUE `0`, 4(b) `156/156 PASS`, 4(c) `29/29 PASS`.

## 2. The 45 rows, by name

    python3 -c "import json;d=json.JSONDecoder().raw_decode(open('/tmp/cen27.json').read(),0)[0];print(len(d['live_bare']));[print(x) for x in d['live_bare']];print(d['off_vocabulary'])"

(`--json` emits the JSON object followed by the human report — decode with
`raw_decode(txt, 0)`, not `json.load`.)

30 `live_bare` + 15 off-vocabulary (`OPEN` 8, `in-flight` 7) = 45.

## 3. The pinned shard counters (durable successors of the /tmp pair)

    git show origin/main:tooling/grip/ledger/pds-w25-shard-count.py > sc.py
    git show origin/main:tooling/grip/ledger/pds-w25-board-manifest-2026-07-30.tsv > mf.tsv
    for c in bare open-normalise parked terminal-with-disposition; do
      python3 sc.py $c mf.tsv; echo "$c rc=$?"; done

Both committed files are byte-identical to `/tmp/w25-count.py` and `/tmp/w25-manifest.tsv`
(`diff` clean, 2026-07-31), so the `/tmp` paths named in `pds-w25-round-bare` criterion 6
have a durable equivalent. Baseline: bare 33/34 rc=1 (sole failure
`pds-w12-crown-climb-preconditions`), open-normalise 103/103 rc=0, parked 27/27 rc=0,
terminal 0/15 rc=1.

## 4. Is the blocked row stageable?

    git show origin/main:api/lib/barkpark/tasks/transitions.ex | sed -n '42p;89,96p'
    git show origin/main:api/lib/barkpark/tasks/stage.ex | sed -n '375,380p'

`@statuses` contains `blocked`; `legal?` returns `from in @statuses` when `from == to`;
`check_stageable` admits `from == to`. `blocked → blocked` is therefore a legal
adjudication door — wave 25's "non-stageable" premise for `pds-w12-crown-climb-preconditions`
is stale post-#8218.

## 5. The epic row is NOT in the predicate's population

    git show origin/main:scripts/pds-ledger-census.sh | sed -n '507,517p'

`build_closure` seeds its frontier with `kids[root]`; the root
(`task-2ac1f95237c4a8e5`) is never appended. Confirmed empirically: the epic row is
absent from `live_bare` while sitting `lifecycle open`, `disposition None`. Exit 0
neither requires nor permits adjudicating it.
