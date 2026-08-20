# Re-derivation recipes — census-under-ci-engine (W36 verify, 2026-08-01)

Subject: `scripts/pds-elixir-receipt-census.exs` @ origin/main `29cb76e60`.
Every number below was derived from a clean `git archive` extraction, never a
working tree. Two engines: host = Elixir 1.19.5 / OTP 28 (erts 16.3.1),
CI pin = Elixir 1.18.1 / OTP 27 (erts 15.2.7.10), aarch64-apple-darwin24.

## R0 — build the clean corpus (every recipe below assumes `$D`)

```bash
D=$(mktemp -d)
git -C /Volumes/SATECHI/github/barkpark archive origin/main \
    api/lib scripts/pds-elixir-receipt-census.exs | tar -x -C "$D"
```

## R1 — install the exact CI pin (no asdf/mise/nix on this host)

Homebrew already carries `erlang@27` (27.3.4.14 — OTP 27 major, NOT the
literal 27.0 in elixir.yml; Elixir does its own tokenizing/parsing so the OTP
*patch* is not on the AST axis, but the discrepancy is real and stated).
Elixir 1.18.1 comes precompiled per OTP major:

```bash
curl -sSL -o /tmp/ex1181.zip \
  https://github.com/elixir-lang/elixir/releases/download/v1.18.1/elixir-otp-27.zip
unzip -q /tmp/ex1181.zip -d /tmp/ex1181
export PATH=/opt/homebrew/opt/erlang@27/bin:/tmp/ex1181/bin:$PATH
elixir --version   # => Erlang/OTP 27 [erts-15.2.7.10] / Elixir 1.18.1
```

## R2 — engine parity (the decisive one)

```bash
cd "$D"
elixir scripts/pds-elixir-receipt-census.exs > /tmp/host.txt; echo HOST_RC=$?
PATH=/opt/homebrew/opt/erlang@27/bin:/tmp/ex1181/bin:$PATH \
  elixir scripts/pds-elixir-receipt-census.exs > /tmp/ci.txt; echo CI_RC=$?
diff /tmp/host.txt /tmp/ci.txt
```

Both RC 0. 243 lines each. `diff` returns EXACTLY TWO hunks, both
self-describing metadata and neither an assertion:

- line 3   `engine      Elixir <ver> · Erlang/OTP <otp> (erts <erts>) · <arch>`
- line 242 `wall clock  12974 ms` (host) vs `19637 ms` (1.18.1) — 1.18.1 is
  ~51% slower on the same corpus; budget the CI job accordingly.

Every integer is identical under both engines:
`EMITTED 91`, `depth 6 write 54 read 14 unrouted 23 POST-READ 15`,
`CLASSIFICATION-TOTAL classified 18 + unclassified 73 == emitted 91`,
all five integrity arms PASS, `CENSUS OK`.

## R3 — corpus refusal exits NON-ZERO (settling the "RC=0" sighting)

```bash
rm -rf /tmp/tiny; mkdir -p /tmp/tiny/api/lib
cp -R "$D"/api/lib/barkpark_web /tmp/tiny/api/lib/
cd /tmp/tiny
elixir "$D"/scripts/pds-elixir-receipt-census.exs >/dev/null 2>&1; echo RC=$?   # => 2
```

The surveyor's `RC=0` is the **shell pipeline** artifact, not the script:

```bash
elixir "$D"/scripts/pds-elixir-receipt-census.exs 2>&1 | tail -1; echo $?  # => 0 (tail's RC)
elixir "$D"/scripts/pds-elixir-receipt-census.exs 2>&1 | tail -1 >/dev/null
echo "${pipestatus[@]}"                                                    # => 2 0
```

Refusal is 2 under BOTH engines. This is the repo's own known
"never pipe to tail in an && chain" trap, recurring.

## R4 — `--files-from` truncation still greens (vacuous green CONFIRMED)

```bash
cd "$D"
find api/lib -name '*.ex' | sort > /tmp/all.txt          # 804
grep -v tasks_controller.ex /tmp/all.txt > /tmp/minus.txt # 803
elixir scripts/pds-elixir-receipt-census.exs --files-from /tmp/minus.txt > /tmp/ff.txt
echo RC=$?   # => 0
grep -E 'EMITTED success|CORPUS-INTACT|CLASSIFICATION-TOTAL|^CENSUS' /tmp/ff.txt
```

One file of 804 removed → `EMITTED 67` (−24), and every integrity arm still
PASSes because each is self-consistent *relative to the supplied corpus*:
`CORPUS-INTACT 803 files >= 600` (the floor is `@corpus_floor` 600, not 804),
`LENS-LOSES-NOTHING textual 80 == ast 71 + phantom 9`,
`CLASSIFICATION-TOTAL classified 5 + unclassified 62 == emitted 67`, `CENSUS OK`.
Nothing in the instrument detects the truncation. (`pds-bl-census-files-from-truncation`.)

## R5 — `--selftest` DOES NOT EXIST, and unknown ARGV is silently ignored

```bash
git show origin/main:scripts/pds-elixir-receipt-census.exs | grep -c selftest   # => 0
cd "$D"
elixir scripts/pds-elixir-receipt-census.exs --selftest      >/dev/null; echo RC=$?  # => 0
elixir scripts/pds-elixir-receipt-census.exs --nonsense-flag >/dev/null; echo RC=$?  # => 0
```

Both print the FULL ordinary census and `CENSUS OK`. `main/1` reads exactly two
flags (`--sites`, `--files-from`); anything else falls through. The 10 hits for
`selftest` under `scripts/pds-ledger-census.sh` belong to the SHELL ledger
census — a different instrument. A gate asserting "`--selftest` passes" against
the Elixir census would be the purest vacuous green available: it asserts
nothing and passes because the flag is ignored.

## R6 — CWD sensitivity: the census fails CLOSED from `api/`

`corpus/1` globs `api/lib/**/*.ex` relative to CWD. elixir.yml's prevailing
`defaults.run.working-directory` is `api` (lines 267, 334, 513, 583).

```bash
cd "$D"/api && elixir "$D"/scripts/pds-elixir-receipt-census.exs >/dev/null 2>&1
echo RC=$?   # => 2, "corpus is EMPTY — nothing to census"
```

Good news: no silent zero. The gate job MUST set `working-directory: .`
(elixir.yml already does that on lines 371, 379, 543) or it reds on every run.

## R7 — the census needs no mix project, no deps, and no `.git`

R0's extraction contains neither `.git` nor `mix.exs` and the run is green:
banner prints `build-free: no mix project, no compile, no app boot`. Unlike
`required-checks.test.sh --hermetic`, absence of `.git` is not a hole here.

## R8 — the advisory DRIFT block on today's main (5 of 8 declared numbers stale)

Printed by every ordinary run, never enforced (`pds-w35-declared-register-basis-drift`):

```
  textual        recorded  103  derived  104  DRIFT
  ast-literal    recorded   95  derived   95  ==
  phantom        recorded    8  derived    9  DRIFT
  consumer       recorded    4  derived    4  ==
  emitted        recorded   91  derived   91  ==
  write-routed   recorded   64  derived   54  DRIFT
  read-routed    recorded   17  derived   14  DRIFT
  unrouted       recorded   10  derived   23  DRIFT
```
