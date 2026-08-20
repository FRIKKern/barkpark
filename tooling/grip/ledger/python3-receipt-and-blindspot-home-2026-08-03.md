# python3 receipt + D633 blind-spot home — re-derivation recipes (wave 44 verify)

Every row below is a single command that re-derives the fact from scratch. Run from
the repo root. `origin/main` was `3f18ab048` when these were taken.

## 1. The task's python3 mutation claim is FALSE (grep leg)

    git show origin/main:scripts/elixir-path-escape-check.sh | grep -c python3   # => 0
    git show origin/main:.github/workflows/elixir.yml        | grep -c python3   # => 0

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

## 3. python3 IS a hard dependency of the ledger census (rc=3, honest refusal)

The local checkout is behind origin/main; materialize first.

    rm -rf /tmp/pdsx && mkdir -p /tmp/pdsx/scripts
    for f in pds-ledger-census.sh pds-ledger-census_test.sh; do
      git show origin/main:scripts/$f > /tmp/pdsx/scripts/$f; done
    (cd /tmp/pdsx && PATH=/tmp/nopy3 bash scripts/pds-ledger-census.sh --selftest; echo rc=$?)
    # => "pds-ledger-census: python3 is required (stdlib only, no new deps)" ; rc=3

## 4. The harness fails CLOSED but MISDIAGNOSES

    (cd /tmp/pdsx && PATH=/tmp/nopy3 bash scripts/pds-ledger-census_test.sh; echo rc=$?)
    # => rc=1, "SELFTEST FAILED: 139 of 144 checks failed"
    # FAIL prose reads "exit 3 was right but the reason was not" — a content bug,
    # not a missing-interpreter bug. The jq fallback at :247-252 is in the HARNESS
    # only; the census itself (:348-353) has no fallback.

## 5. The harness price (OS meter around a SHELL — the only legal method, PDS-D633)

    (cd /tmp/pdsx && /usr/bin/time -p bash scripts/pds-ledger-census_test.sh)
    # trial 1: real 114.50 / user 34.87 / sys 7.65 ; rc=0 ; 144 checks ; load avg 117.97
    # trial 2: real 151.20 / user 38.88 / sys 9.15 ; rc=0 ; 144 checks ; load avg 108.31
    # The task's stated "107 checks ... 20.1-23.1 s USER CPU CEILING" is stale on BOTH axes.

## 6. The one live D605 violation on main, and nothing asserts on it

    git show origin/main:scripts/pds-elixir-receipt-census.exs | grep -n 'p("wall clock'
    # => 6605:    p("wall clock  #{ms} ms  (build-free: ...)")
    git grep -n 'wall clock' origin/main -- 'api/test/**' 'scripts/pds-*'
    # => no assertion anywhere on that line; no grep -v / filter of it in the census.
    git show origin/main:scripts/pds-elixir-receipt-census.exs | sed -n '41,42p'
    # => "defmodule PDS.Census do" with NO @moduledoc — D633's @moduledoc half needs one CREATED.

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

## 8. No required job exercises python3

    git grep -n 'python3' origin/main -- '.github/workflows/*'
    # reland-check.yml :78/:84 are `|| true`-guarded; :97 is unreachable while findings==0.
    git show origin/main:.github/required-checks.json | grep '"context"'
    # => Cloud gate, Console gate, Elixir gate, PR references an active task. No python3 anywhere.
