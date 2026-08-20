# PDS wave 40 — gate ground re-derivation recipes (2026-08-02)

Tree under measurement: clean `git archive` of origin/main `28f4cd4730c96667ad0f3bddd406e2ce754a1273`.
Working copy used: `$M = <scratchpad>/m40`. The PRIMARY checkout at /Volumes/SATECHI/github/barkpark
is **327 commits behind and 48 ahead** of origin/main — nothing measured there is a claim about main.

## R1 — mix format on origin/main (GREEN)

The clean tree has no `deps/`, and `.formatter.exs` carries
`import_deps: [:ecto, :ecto_sql, :phoenix]`, so the formatter cannot run without them.
Version-checked first: ecto 3.13.6 / ecto_sql 3.13.5 / phoenix 1.8.9 are IDENTICAL in
`origin/main:api/mix.lock` and in the local deps tree, so the borrow does not change the verdict.

    # per-dep symlink farm (never a single deps symlink: `mix deps.get` would then
    # write into the real repo's deps/)
    mkdir -p $M/api/deps
    cd /Volumes/SATECHI/github/barkpark/api/deps && for d in */; do n=${d%/}; \
      case "$n" in plug_crypto|mint|finch|req) continue;; esac; \
      ln -sfn /Volumes/SATECHI/github/barkpark/api/deps/$n $M/api/deps/$n; done
    cd $M/api && mix deps.get          # fetches ONLY the 4 lock-mismatched deps
    cd $M/api && CC=/usr/bin/clang mix format --check-formatted; echo "rc=$?"
    # => rc=0, EMPTY output.

Same command in the PRIMARY checkout gives rc=1 (tasks_controller_test.exs,
studio_live.ex, components_test.exs) — that is local divergence, not main.

## R2 — sobelow residue on origin/main (24, UNCHANGED)

    cd $M/api && CC=/usr/bin/clang MIX_ENV=dev mix sobelow --skip --exit Low > sobelow-main.txt 2>&1
    grep -cE "Confidence" sobelow-main.txt                                   # 24
    grep -E "Confidence" sobelow-main.txt | sed -E 's/\x1b\[[0-9;]*m//g; s/:.*//' | sort | uniq -c | sort -rn
    # 9 Traversal.FileModule / 7 SQL.Query / 3 SQL.Stream / 3 Config.CSRF / 2 CI.System
    # by confidence: 3 High, 21 Low.   rc=1 (expected: --exit Low; the job is continue-on-error)

Count the DECIDING SCAN's own lines, never a log tail. Note the distinct number
`.sobelow-skips` = **57 baseline rows** (32 Traversal.FileModule / 11 DOS.StringToAtom /
6 Config.CSRF / 3 XSS.Raw / 1 each XSS.SendResp, SQL.Query, RCE.CodeModule, Config.HTTPS,
CI.System) — the baseline FILE and the residue COUNT are different numbers.

    git show origin/main:api/.sobelow-skips | grep "," | sed 's/:.*//' | sort | uniq -c | sort -rn

## R3 — census timings (LOAD-SENSITIVE; do not quote a number without its load)

    uptime; cd $M && time elixir scripts/pds-elixir-receipt-census.exs 2>&1 | grep -E "wall clock|CENSUS OK"; uptime
    uptime; cd $M && time elixir scripts/pds-elixir-receipt-census.exs --selftest 2>&1 | tail -3; uptime

Measured 2026-08-02 on a LOADED 10-core host (never a quiet-host number):
  full     load 12.06 -> 11.35 : internal 7899 ms, shell 9.670 s, 95% cpu, rc=0
  full     load 23.33 -> 30.14 : internal 11282 ms, shell 14.677 s, 68% cpu, rc=0
  selftest load 10.68 -> 11.84 : shell 78.49 s, 1.54s user + 0.98s system, **3% cpu**, rc=0

The full run is NOT load-immune: +43% internal wall from load ~12 to load ~25.
The selftest is subprocess/scheduler-bound (3% cpu) — NOT MEASURABLE on this host.
This refutes nothing about the quiet-host 41-43 s figure.

## R4 — the census is wired to no CI workflow (still true today)

    for f in $(git ls-tree -r --name-only origin/main .github/workflows); do \
      git show origin/main:$f | grep -qi "pds-elixir-receipt-census\|pds-status-only" && echo "HIT $f"; done
    # => no output.

Corollary: the census has NEVER run on CI's pinned Elixir 1.18.1 / OTP 27.0
(`.github/workflows/elixir.yml:225-226`); every number in this epic is 1.19.5 / OTP 28.
No arm ASSERTS the engine version (`System.version()` appears once, at census.exs:1226, in a
`p(...)` print only), and a scan for 1.19-only APIs over the script returns nothing — so the
port risk is AST-shape drift, not a syntax error. The corpus glob is CWD-relative
(`census.exs:1216 Path.wildcard("api/lib/**/*.ex")`), which is why the gate task pins
`working-directory: '.'`.
