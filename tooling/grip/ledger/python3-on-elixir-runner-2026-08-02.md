# python3 on the Elixir CI runner — re-derivation recipe (PDS w43 verify)

VERDICT: python3 IS present on the ubuntu-latest runner that hosts every
elixir.yml job, including `Test (Elixir 1.18.1 / OTP 27.0)`. The
ledger-census door is NOT environment-blocked.

## Leg 1 — proven by a green job that dies without python3

`Elixir path-escape ratchet` runs `bash scripts/elixir-path-escape-check.sh
--selftest`, which `exec`s `scripts/elixir-path-escape-check.test.sh`, which
calls `python3` (and `import yaml`) at lines 364, 449, 450, 471, 587.

    gh api "repos/:owner/:repo/check-runs/91528677921" -q '"\(.name)\t\(.conclusion)"'
    # -> Elixir path-escape ratchet	success

Mutation proving the call is load-bearing (python3 removed from PATH):

    D=$(mktemp -d); cd "$D"
    git -C <repo> archive origin/main scripts .github | tar -x
    mkdir -p "$D/nopy"
    for b in bash sed grep awk cat mktemp dirname sort tr head tail cut wc git \
             rm mkdir touch env printf date find xargs uname stat cp mv ln chmod \
             diff comm join basename tee expr seq; do
      p=$(command -v $b) && ln -sf "$p" "$D/nopy/$b"
    done
    PATH="$D/nopy" bash scripts/elixir-path-escape-check.sh --selftest; echo rc=$?
    # -> rc=127 ; "scripts/elixir-path-escape-check.test.sh: line 364: python3: command not found"

## Leg 2 — the Test job's own apt log

    gh run view --job 91528735033 --log | grep -n "The following NEW packages will be installed" -A 12
    gh run view --job 91528735033 --log | grep -E 'Setting up python3'

`python3-mako` / `python3-markdown` arrive as libvips-dev deps and configure
cleanly; bare `python3` never appears in the NEW-packages list, i.e. it was
already on the image (`Image: ubuntu-24.04`, `Version: 20260720.247.2`).

## Leg 3 — the census selftest runs offline, tokenless, outside a git repo

    cd $(mktemp -d) && git -C <repo> archive origin/main scripts | tar -x
    env -u BARKPARK_TOKEN -u BARKPARK_SERVER bash -c \
      'TIMEFORMAT="user=%U sys=%S wall=%R"; time bash scripts/pds-ledger-census_test.sh; echo rc=$?'
    # -> SELFTEST PASS: 107 checks ; rc=0
    # -> best of 3 on a LOADED host (load 19-38): user=20.105 sys=4.013 wall=30.655

All 3 `"$CENSUS"` call sites pass `--fixture-dir`; the engine only reaches
`urllib.request` outside fixture mode. Ran under Python 3.9.6 locally, so no
3.10+ syntax bars the runner's 3.12.

## Caveat

Every second above was taken at load average 19-38. Treat 20.1 s user as a
CEILING, not the quiet-host number.
