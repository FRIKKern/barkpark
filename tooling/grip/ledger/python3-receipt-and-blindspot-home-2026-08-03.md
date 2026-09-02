# python3 receipt + D633 blind-spot home — re-derivation recipes (wave 44 verify)

Every row below is a single command that re-derives the fact from scratch. Run from
the repo root. `origin/main` was `3f18ab048` when these were taken.

**RE-DERIVED 2026-09-02 against `origin/main` `c93c48654a`.** Every command in this
file was re-run on that sha, or is marked below as a historical transcript with the
reason it can no longer be run. Notes stamped **[2026-09-02]** are appended
corrections and re-measurements; the 2026-08-03 lines above them stand verbatim,
because a record must quote what it observed. One command was WRONG AS WRITTEN and
is corrected under §3. The recipes materialise into `/tmp/pdsx` and `/tmp/nopy3`;
the 2026-09-02 re-runs substituted a private scratch directory for both (`/tmp` is
shared between concurrent agents on this host) and are otherwise byte-identical.

## 1. The task's python3 mutation claim is FALSE (grep leg)

    git show origin/main:scripts/elixir-path-escape-check.sh | grep -c python3   # => 0
    git show origin/main:.github/workflows/elixir.yml        | grep -c python3   # => 0

**[2026-09-02] RE-RUN, HOLDS.** Both still `0` on `c93c48654a`.

## 2. The same claim is FALSE by RUN (mutation leg — the honest one)

Build a PATH containing every binary on the real PATH EXCEPT python3/python. A naive
minimal PATH also loses `dirname`/`cut` and yields a CONFOUNDED rc=127.

    bash -c '
    rm -rf /tmp/nopy3; mkdir -p /tmp/nopy3
    IFS=":" read -ra dirs <<< "$PATH"
    for d in "${dirs[@]}"; do [ -d "$d" ] || continue
      for f in "$d"/*; do b=$(basename "$f"); case "$b" in python3*|python) continue;; esac
        [ -e /tmp/nopy3/$b ] || ln -sf "$f" /tmp/nopy3/$b 2>/dev/null; done; done
    PATH=/tmp/nopy3 command -v python3 || echo "python3: NONE"
    PATH=/tmp/nopy3 bash scripts/elixir-path-escape-check.sh >/dev/null 2>&1
    echo "escape-check rc=$?"'      # => python3: NONE ; escape-check rc=0   (NOT 127)

**[2026-09-02] RE-RUN, HOLDS.** Identical output: `python3: NONE` then
`escape-check rc=0`. Note for anyone re-running §3 and §4: the `/tmp/nopy3` those
sections use is the FULL PATH MIRROR built here, not an empty directory. The
distinction matters and is measured at the end of §3.

## 3. python3 IS a hard dependency of the ledger census (rc=3, honest refusal)

The local checkout is behind origin/main; materialize first.

    rm -rf /tmp/pdsx && mkdir -p /tmp/pdsx/scripts
    for f in pds-ledger-census.sh pds-ledger-census_test.sh; do
      git show origin/main:scripts/$f > /tmp/pdsx/scripts/$f; done
    (cd /tmp/pdsx && PATH=/tmp/nopy3 bash scripts/pds-ledger-census.sh; echo rc=$?)
    # => "pds-ledger-census: python3 is required (stdlib only, no new deps)" ; rc=3

**[2026-09-02] CORRECTED — this recipe documented a flag that does not exist.**
As recorded on 2026-08-03 the invocation carried `--selftest`:

    (cd /tmp/pdsx && PATH=/tmp/nopy3 bash scripts/pds-ledger-census.sh --selftest; echo rc=$?)

`--selftest` is not an argument of `scripts/pds-ledger-census.sh`. Its usage block
offers `--lens`, `--assert-round-done`, `--anchor-from-paper`, `--anchor`, `--json`,
`--fixture-dir`, `--server` and `--token`, and nothing else. The census's selftest is
the SEPARATE harness `scripts/pds-ledger-census_test.sh` — the one §4 and §5 below
already invoke correctly, and the one `.github/workflows/shell-harnesses.yml` runs as
the `pds-harnesses` job. That separation is deliberate (most gate scripts in this repo
bundle their own `--selftest`, which is very likely where the flag came from by muscle
memory), so the fix belongs HERE and NOT in the census: no `--selftest` flag is being
added to `pds-ledger-census.sh` to make an old transcript true.

**THE RECORDED rc WAS RIGHT FOR THE WRONG REASON**, which is precisely why this
survived. The interpreter guard in `pds-ledger-census.sh` sits immediately after
`set -euo pipefail` and above the `PDS_CENSUS_SCRIPT_DIR` assignment — i.e. before
`exec python3 -I -`, and therefore before argparse ever sees argv. With python3 off
PATH the guard exits 3 and the bogus flag is never parsed. Restore python3 and the
same line exits **2** with `pds-ledger-census.sh: error: unrecognized arguments:
--selftest`, which is NOT the honest refusal this section claims to demonstrate. A
documented command that errors is worse than no command at all in a file like this
one: it is read exactly when python3 behaviour is already under suspicion, so its
spurious rc lands in the middle of someone's real investigation. The recipe above now
runs flag-free, which reaches the guard for the reason the section states.

**[2026-09-02] THE rc=3 WAS RE-RUN, NOT CARRIED FORWARD.** Three legs on
`c93c48654a`, scripts materialised as the recipe describes:

| invocation | PATH | observed |
|---|---|---|
| `bash scripts/pds-ledger-census.sh` (the corrected recipe) | mirror minus python3 | `pds-ledger-census: python3 is required (stdlib only, no new deps)` ; **rc=3** |
| `bash scripts/pds-ledger-census.sh --selftest` (as recorded 2026-08-03) | mirror minus python3 | same message ; **rc=3** — the guard masks the bogus flag |
| `bash scripts/pds-ledger-census.sh --selftest` | normal | `pds-ledger-census.sh: error: unrecognized arguments: --selftest` ; **rc=2** |

So the 2026-08-03 FINDING survives intact — the census does fail closed, loudly and
with its own message, when python3 is absent. Only the command that reached it was
wrong, and the third row is the proof that the flag was never the thing being tested.

**[2026-09-02] THE GUARD NEEDS NOTHING FROM PATH**, measured because §2's warning
about a confounded rc=127 invites the opposite assumption. Repeating leg one with
`PATH` pointed at an EMPTY directory still yields the guard's message and **rc=3**,
not 127: `command -v` and `echo` are bash builtins, and `dirname` is only called
AFTER the guard returns. The refusal is therefore not confounded by missing
coreutils, and the full mirror of §2 is a convenience here rather than a
requirement. (With an empty PATH, `bash` itself must be invoked as `/bin/bash`.)

## 4. The harness fails CLOSED but MISDIAGNOSES

    (cd /tmp/pdsx && PATH=/tmp/nopy3 bash scripts/pds-ledger-census_test.sh; echo rc=$?)
    # => rc=1, "SELFTEST FAILED: 139 of 144 checks failed"
    # FAIL prose reads "exit 3 was right but the reason was not" — a content bug,
    # not a missing-interpreter bug. The jq fallback at :247-252 is in the HARNESS
    # only; the census itself (:348-353) has no fallback.

**[2026-09-02] RE-RUN. The BEHAVIOUR holds; the COUNT and the LINE ANCHORS do not.**
Still `rc=1`, and the FAIL prose still reads verbatim `exit 3 was right but the reason
was not`, so the misdiagnosis this section names is unfixed. The tally has grown with
the harness: **`SELFTEST FAILED: 210 of 222 checks failed`**, not 139 of 144. The two
line citations have drifted off their targets and should be read as symbols instead:
the jq-with-python3-fallback in `pds-ledger-census_test.sh` is the `command -v jq`
branch under its "jq is the validator when it exists; python3 is the fallback"
comment, and the census's lack of one is re-confirmed structurally —
`grep -c 'command -v jq' scripts/pds-ledger-census.sh` returns **0**, and the only
`command -v` in the census is the python3 guard itself.

## 5. The harness price (OS meter around a SHELL — the only legal method, PDS-D633)

    (cd /tmp/pdsx && /usr/bin/time -p bash scripts/pds-ledger-census_test.sh)
    # trial 1: real 114.50 / user 34.87 / sys 7.65 ; rc=0 ; 144 checks ; load avg 117.97
    # trial 2: real 151.20 / user 38.88 / sys 9.15 ; rc=0 ; 144 checks ; load avg 108.31
    # The task's stated "107 checks ... 20.1-23.1 s USER CPU CEILING" is stale on BOTH axes.

**[2026-09-02] RE-MEASURED, and the section's own point gets a third data point.**
One trial on `c93c48654a`: **real 76.45 / user 43.38 / sys 12.23 ; rc=0 ;
`SELFTEST PASS: 222 checks` ; load avg 55.54 at start, 55.47 at end.** Read the two
axes separately, because they moved in OPPOSITE directions:

- **USER CPU rose** 34.87 → 43.38 s, tracking the harness growing 144 → 222 checks.
  That is the price, and it is the number PDS-D605 says to quote.
- **REAL FELL** 114.50 → 76.45 s on MORE work, purely because the box was half as
  busy (load 55 versus 118). Wall clock here measures the host, not the harness.

The 2026-08-03 verdict therefore stands and strengthens: the stated
"107 checks ... 20.1-23.1 s USER CPU CEILING" is stale on both axes, and is now
stale by a wider margin than when that line was written.

## 6. The one live D605 violation on main, and nothing asserts on it

    git show origin/main:scripts/pds-elixir-receipt-census.exs | grep -n 'p("wall clock'
    # => 6605:    p("wall clock  #{ms} ms  (build-free: ...)")
    git grep -n 'wall clock' origin/main -- 'api/test/**' 'scripts/pds-*'
    # => no assertion anywhere on that line; no grep -v / filter of it in the census.
    git show origin/main:scripts/pds-elixir-receipt-census.exs | sed -n '41,42p'
    # => "defmodule PDS.Census do" with NO @moduledoc — D633's @moduledoc half needs one CREATED.

**[2026-09-02] RE-RUN — THIS SECTION IS SPENT. BOTH HALVES ARE CLOSED ON MAIN.**
It is kept as history, not as a live finding.

- The first command now returns **NOTHING**: `p("wall clock` no longer occurs in
  `scripts/pds-elixir-receipt-census.exs`. The file itself now carries a comment
  saying the `wall clock` label "is a line this run no longer prints", so the
  violation was removed rather than merely moved.
- The second command is consequently no longer a probe of anything — with the cited
  line gone there is no line for an assertion to be missing on. It now returns 18
  incidental prose matches across `api/test/**` and `scripts/pds-*`, none of which
  are the construct this section was about. The recorded empty result is a
  HISTORICAL TRANSCRIPT and cannot be reproduced.
- The third command's line anchor has drifted and its finding is reversed:
  `defmodule PDS.Census do` no longer sits at the cited offset, and the module now
  HAS an `@moduledoc`, deliberately declared below a list the doc string
  interpolates. D633's `@moduledoc` half is satisfied; nothing needs creating.

## 7. python3 on ubuntu-latest — the honest proof that DOES exist

Not from a comment. `deploy/site-deploy.sh:758` tests `command -v python3`, and under
`BARKPARK_SELFTEST_REQUIRE_E2E=1` (:765) prints FAIL and `exit 1` (:766-768). The same
shape repeats at :901-904 and :1398-1399.

    git show origin/main:deploy/site-deploy.sh | sed -n '758,769p'
    git show origin/main:.github/workflows/deploy-harnesses.yml | sed -n '63,66p'  # sets the flag
    gh run list --workflow=deploy-harnesses.yml --limit 5 \
      --json conclusion,headSha,createdAt -q '.[]|.conclusion+"  "+.headSha[0:9]'
    # => five consecutive "success" on ubuntu-latest => python3 IS present.
    # CAVEAT: deploy-harnesses.yml is `on: paths:`-filtered (deploy/**) and is NOT a
    # required check — it proves the image, it does not gate the image.

**[2026-09-02] RE-RUN. The SUBSTANCE holds; every line anchor is dead, and the third
command is a moving window that cannot be re-run to the same answer.**

- The two `sed -n` ranges now print unrelated text — read them as symbols. The guard
  is the `if ! command -v python3 ... || ! command -v curl` block whose body prints
  `[selftest] FAIL - the HEALTH gate proofs ... are REQUIRED here
  (BARKPARK_SELFTEST_REQUIRE_E2E=1) but python3 and/or curl are missing from PATH`
  and then `exit 1`. It occurs twice in `deploy/site-deploy.sh`, with a third,
  non-fatal `command -v python3` test earlier in the file. The FAIL-and-`exit 1`
  shape the section claims is intact.
- `BARKPARK_SELFTEST_REQUIRE_E2E: "1"` is set on two jobs in
  `.github/workflows/deploy-harnesses.yml`, so the flag half also holds.
- `gh run list --limit 5` reads the LAST FIVE RUNS AT THE INSTANT OF THE QUERY, so
  the recorded "five consecutive success" is a HISTORICAL TRANSCRIPT by construction.
  Today it returns `success / success / cancelled / cancelled / success` — three
  successes and two runs a human stopped. That does not weaken the conclusion (a
  cancelled run is not a python3 failure), but the recipe as written over-claims: a
  reader who needs "python3 is present on the image" should filter to
  `conclusion == "success"` rather than assume the top five are clean.
- The CAVEAT is re-confirmed: `deploy-harnesses.yml` appears nowhere in
  `.github/required-checks.json`.

## 8. No required job exercises python3

    git grep -n 'python3' origin/main -- '.github/workflows/*'
    # reland-check.yml :78/:84 are `|| true`-guarded; :97 is unreachable while findings==0.
    git show origin/main:.github/required-checks.json | grep '"context"'
    # => Cloud gate, Console gate, Elixir gate, PR references an active task. No python3 anywhere.

**[2026-09-02] RE-RUN. The CONCLUSION holds, on a much wider base than in 2026-08-03,
but BOTH recorded outputs are stale and neither reproduces.**

- The first command's recorded reading is spent: the `reland-check.yml` line anchors
  are gone, and the grep now spans far more of the tree —
  `.github/workflows/shell-harnesses.yml` alone carries roughly a dozen explicit
  "python3 is present" name-check steps that did not exist when this was written.
  None of those workflows are required (see below), so the reading changed while the
  verdict did not.
- The second command's recorded four-context output is badly stale: the required set
  has grown from **4 contexts to 32**, spanning ten workflows —
  `breakglass-watch.yml`, `cloud.yml`, `compose-smoke.yml`, `console-harness.yml`,
  `doc-gates.yml`, `elixir.yml`, `go-format.yml`, `pr-task-gate.yml`,
  `required-checks-drift.yml`, `security.yml`.
- **RE-DERIVED HEADLINE:** `git show origin/main:.github/workflows/<w>.yml | grep -c
  python3` returns **0 for all ten** of those workflows. So the section's title is
  still true, and now on eight times the base it was measured against.
- **SCOPE THE CLAIM HONESTLY.** This method greps workflow YAML only. A required job
  that shells out to a script which itself calls python3 would not be seen by it.
  The safe reading of §8 is "no required workflow NAMES python3", which is what the
  command measures; the transitive claim was never derived here and is not derived
  now.
