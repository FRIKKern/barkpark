# v-quiet-host-prices — re-derivation recipes (PDS wave 45 VERIFY, 2026-08-03)

Re-taking every contested door price by the method recorded in
`tooling/grip/ledger/quiet-host-prices-2026-08-03.md`: an OS meter around a
SHELL (never inside a BEAM parent), CPU = user + sys, a FIXED calibration
workload interleaved between trials so contamination is MEASURED not declared,
and load1 stamped before AND after every trial.

Tree under measurement: `origin/main` @ `a723ec0dd64683a81043dcfcc1f77ea6b919e288`,
extracted pristine (`git archive origin/main | tar -x -C $S`), never a worktree.
Every `scripts/pds-*` file and `scripts/elixir-path-escape-check.sh` is
BYTE-IDENTICAL between `ab8c86b05` (the wave's declared base) and this commit:

    git diff --stat ab8c86b05 origin/main -- scripts/pds-\* scripts/elixir-path-escape-check.sh
    # -> empty

**THE QUIET HOST WAS NOT REACHED, BUT IT WAS APPROACHED.** load1 ran 9.07 – 32.22
on 10 cores across the session (against 105–123 in wave 44). Disclosed per row.

## R0 — The calibration burn the MUST-RUN specified is NOT the recorded one, and using it would have been self-defeating

The dispatch spells the fixed workload as a bash arithmetic loop. The recorded
method — and PDS-D648, which derived the 27% bound from it — uses a python3 loop.
They are not interchangeable. Measured back to back at load1 44.90:

    /usr/bin/time -p bash -c 'i=0; while [ $i -lt 8000000 ]; do i=$((i+1)); done'
    real 50,38   user 27,88   sys 2,98
    /usr/bin/time -p bash -c 'python3 -c "x=0
    for i in range(8000000): x+=i"'
    real  0,81   user  0,63   sys 0,03

**44x.** Interleaved before each of 21 trials the bash form would have added
~10 minutes of pure CPU to the very host whose contention it exists to measure —
a calibration that becomes a load generator measures itself. The python3 form was
used, and D648's own quoted figures (0.51–0.65) confirm it is the canonical one.

## R1 — The contamination bound, and why the session-wide span is the wrong number

21 interleaved calibration runs:

    CALIBRATION user CPU: n=21 min=0.40 max=0.56 mean=0.479 span=40.0%
    CALIBRATION wall    : n=21 min=0.47 max=0.83 mean=0.617 span=76.6% (=1.77x)

The 40% span is **not measurement noise — it is a LOAD-REGIME effect**, and
collapsing it into one bound is what makes a bad price defensible. Calibration
tracks load monotonically: load1 9–10 -> 0.37–0.38; load1 21–25 -> 0.40–0.43;
load1 29–32 -> 0.53–0.56. WITHIN a regime, repeatability is tight:

| door | regime | trials | span |
|---|---|---|---|
| `pds-scratch-target_test.sh` | load1 31.6–32.2 | 8.73 / 8.86 / 8.78 | **1.5%** |
| `pds-door-census.sh --check` | load1 29.2–30.9 | 2.97 / 3.06 / 3.15 | **6.1%** |
| `pds-ledger-census_test.sh`  | load1 21.5–25.4 | 29.47 / 29.81 / 27.00 | **10.4%** |
| `pds-ledger-census_test.sh`  | load1 9.1–10.2  | 24.54 / 25.64 | **4.5%** |

**A price is reproducible WITHIN a session and not ACROSS one.** That is the
whole argument for re-measurement over a date stamp: a stamp records when, and
the thing that actually moved was the regime.

## R2 — `pds-ledger-census_test.sh`: the shipped 40.33 s does not descend from a run at the load it stamps

    S=$(mktemp -d); (cd /Volumes/SATECHI/github/barkpark && git archive origin/main) | tar -x -C $S
    cd $S && for i in 1 2 3; do uptime; \
      /usr/bin/time -p bash -c "bash scripts/pds-ledger-census_test.sh >/tmp/lc_$i.out 2>&1; echo rc=\$?"; \
      grep 'SELFTEST PASS' /tmp/lc_$i.out; done

    load1 23,20   rc=0  user 24,26  sys 5,21  real 35,93   -> CPU 29,47
    load1 25,44   rc=0  user 24,46  sys 5,35  real 36,51   -> CPU 29,81
    load1 21,49   rc=0  user 22,28  sys 4,72  real 32,04   -> CPU 27,00
    load1 10,15   rc=0  user 20,59  sys 3,95  real 28,88   -> CPU 24,54
    load1  9,32   rc=0  user 21,30  sys 4,34  real 30,28   -> CPU 25,64

    SELFTEST PASS: 144 checks.     (all five runs, identical)

FIVE FIGURES NOW EXIST FOR A BYTE-IDENTICAL INSTRUMENT ON A BYTE-IDENTICAL TREE:

| source | load1 | CPU |
|---|---|---|
| charter PDS-D647 | 105–123 | 42.6 – 45.0 s |
| **shipped row, `pds-door-census.sh:126`** | **24.26** | **40.33 s** |
| wave-45 surveyor | 33 | 32.22 s |
| this run | 21.5 – 25.4 | 27.00 – 29.81 s |
| this run, quietest reached | 9.1 – 10.2 | 24.54 – 25.64 s |

Every point except the shipped row lies on a monotone load curve. **Across a 2.6x
load change (9 -> 24) the price moved +21%. The shipped row claims a figure 35–49%
above what this run measures AT ITS OWN STAMPED LOAD**, where within-regime
repeatability is 10.4%. Load cannot explain the gap, so the `load1=24.26` stamp is
decorative: it is the row's only provenance and it does not reconcile.

Note the direction of the error is the one D633 warns about **inverted** — this
row makes an affordable door look expensive, and D647's "second tiering case,
~40 s needs its own justification" rests on it. The honest quiet figure is ~25 s.

## R3 — `pds-elixir-receipt-census.exs`: UNMEASURED-LOCAL is now measured. Three arms, 51.34 s CPU

The three gated arms are the ones `api/test/barkpark/pds_elixir_census_test.exs`
runs (`:93` plain rc=0, `:103` one-token mutant rc=1, `:143` unknown flag rc=2).
The mutant is built exactly as the rider builds it — anchor asserted to occur once:

    MUTATION-ANCHOR-OCCURRENCES=1
    "classified = Enum.map(routed, &classify(&1, index))"
      -> "classified = tl(Enum.map(routed, &classify(&1, index)))"

    refusal  load1 29,52  rc=2  user 5,46 sys 0,74 -> 6,20 | 5,36+0,75 -> 6,11 | 5,36+0,81 -> 6,17
    plain    load1 23,83  rc=0  user 22,26 sys 4,06 -> 26,32* | 17,81+2,26 -> 20,07 | 18,49+2,24 -> 20,73
    mutant   load1 18,29  rc=1  user 21,41 sys 2,52 -> 23,93 | 21,81+2,63 -> 24,44 | 22,12+2,55 -> 24,67
    (*trial 1 is a cold-FS-cache outlier; medians used)

**THIS PRICE IS LEGAL AND THE `@blind_spot` SAYS SO.** Its own last line:
"The `user cpu` figure below is BEAM-INTERNAL and covers THIS process only — for
the plain census, which spawns nobody, that is the whole price." Only `--selftest`
fans out to child BEAMs; plain/mutant/refusal spawn nobody, so an OS meter around
a shell is sound for exactly these three. **PROVED BY ARITHMETIC, not by reading:**

    plain, OS meter          user 17,81 s
    plain, BEAM self-report  user cpu 12615 ms
    refusal (compile only)   user  5,36 s
    12,62 + 5,36 = 17,98  vs  17,81 measured   <- the meter closes to 1%

The refusal arm — which "exits 2 without measuring anything" — costs **6.2 s CPU**,
because `elixir` must compile 380 KB of script before it can reject a flag. An
ARGV refusal is not free.

## R4 — Two numbers INSIDE `@blind_spot` are hand-typed literals that do not descend from the meter

`scripts/pds-elixir-receipt-census.exs:62` and `:64` are string literals in the
`@blind_spot` list: "is the **~15 s** printed as `user cpu` below" and "so
**~140 s** of user CPU is a FLOOR". The instrument's own meter, three runs:

    user cpu  12615 ms
    user cpu  13199 ms
    user cpu  17640 ms

12.6 s, not ~15 s — and the ~140 s floor is `9 x ~15 s`, i.e. prose arithmetic
over a stale literal; on the measured median it is ~113 s. **PDS-D633 is satisfied
in FORM here (one list referenced by both `@moduledoc` and the printed banner) and
violated in SUBSTANCE: the numbers the list compares against are copy-paste
constants.** This is the epic's own defect reproduced inside the text that
declares it.

Separately DISCHARGED, and the charter should record it: D648's consequence
("`:6605` prints `wall clock #{ms} ms` — the exact unit D605 forbids") is FIXED on
main. The line now prints `user cpu ... ms`, `:6899` notes "which this run no
longer prints", and `grep -rn 'wall clock' scripts/` returns no emitter in the
census. D648's "`defmodule PDS.Census` has no `@moduledoc`" is also stale — it has
one, at `:75`.

## R5 — The rows the wave should land

Emitted in the shipped `PDS_DOOR_PRICES` shape
(`<basename><TAB>CPU=<u>+<s>=<t>s LOCAL meter=<meter> …`), medians of 3 unless noted.
**Every row states the load it was taken at AND that no quiet host was reached** —
per the assignment, that is IN the row, not hidden.

    pds-door-census.sh	CPU=0.84+2.22=3.06s LOCAL meter=/usr/bin/time -p around bash -c load1=29.82 2026-08-03 (--check, rc=0, median of 3, regime span 2.97-3.15s @ load1 29.2-30.9; NOT A QUIET HOST). Its gated arm is --selftest at CPU=0.03+0.07=0.10s @ load1=10.99 — 30x cheaper than the --check that actually disposes the inventory.
    pds-scratch-target_test.sh	CPU=4.61+4.17=8.78s LOCAL meter=/usr/bin/time -p around bash -c load1=31.93 2026-08-03 (rc=0, stub barkpark, median of 3, regime span 8.73-8.86s; NOT A QUIET HOST). Hermeticity on a runner WITHOUT local Postgres is unproven here.
    pds-ledger-census_test.sh	CPU=21.30+4.34=25.64s LOCAL meter=/usr/bin/time -p around bash -c load1=9.32 2026-08-03 (rc=0, 144 checks, quietest regime reached; at load1 21.5-25.4 the same instrument costs 27.00-29.81s; NOT A QUIET HOST). SUPERSEDES the 40.33s row, which is 35-49% high at its own stamped load1=24.26 — see tooling/grip/ledger/v-quiet-host-prices-2026-08-03.md R2.
    pds-elixir-receipt-census.exs	CPU=45.66+5.68=51.34s LOCAL meter=/usr/bin/time -p around bash -c load1=18.3-29.5 2026-08-03 (the three ExUnit-gated arms, medians: plain rc=0 20.73s + one-token mutant rc=1 24.44s + unknown-flag refusal rc=2 6.17s; NOT A QUIET HOST). Legal under the instrument's own @blind_spot: these three spawn no child BEAM. `--selftest` remains unpriceable by this meter.

And the hetzner door, which has NO price row today because it is disposed
ENVIRONMENT on evidence citing the wrong arm (`--selftest rc=3`, while `:13`/`:964`
declare `--selftest-offline` "the CREDENTIAL-FREE arm and the CI-able gate"):

    pds-live-hetzner-placement-group.sh	CPU=1.44+1.52=2.96s LOCAL meter=/usr/bin/time -p around bash -c load1=30.91 2026-08-03 (--selftest-offline, rc=0, median of 3, regime span 2.64-3.01s; NOT A QUIET HOST). sys ~= user (D648's spawn-dominated shape). Output is BYTE-IDENTICAL across all 3 trials — ratchetable.

## R6 — What the price column cannot currently do, verified rather than asserted

    grep -n "usr/bin/time\|SECONDS\|date +%s\|shasum\|md5\|sha256\|uptime" scripts/pds-door-census.sh
    # -> lines 126,127,146,147,148 ONLY — every hit is INSIDE a quoted price string.
    # Zero timing, hashing or date primitives in executable position.
    grep -n 'usage: ' scripts/pds-door-census.sh
    # -> usage: $0 [--check|--selftest|--list-refs|--help]      (no --measure)

So the column has no meter, no content key, and no re-measurement verb — a price
can only ever be edited by hand, which is how all five of R2's figures came to
coexist.

**AND THE SHAPE VALIDATOR CANNOT SEE THE ROWS THAT GATE.** `scripts/pds-door-census.sh:550-558`
(`elif [ "$class" = 'PRICE' ]`) puts the `CPU=…LOCAL…meter=` check inside the
terminal `else` branch, reached only by ledger-dispositioned rows. THROUGH rows
take the `:521-525` branch, which assigns `price` and checks nothing. The rider does not close it either:
`api/test/barkpark/pds_door_census_test.exs:303` filters `~r/…\s+PRICE\s/`, i.e. the
CLASS column — so the four THROUGH rows are unchecked in BOTH places. The hole is
live, not theoretical: `pds-elixir-receipt-census.exs` is a THROUGH row whose
evidence is the bare word `UNMEASURED-LOCAL`, matching no price shape at all.

## R7 — A false self-gating claim on merged code, found while locating the arms

`scripts/pds-elixir-receipt-census.exs:9-11` states: "THIS FILE — not the
`scripts/pds-*` CLASS — is in neither Elixir path set
(`scripts/elixir-path-escape-check.sh`), so it costs no Elixir gate minute."

    git show origin/main:scripts/elixir-path-escape-check.sh | sed -n '88,104p'
    ELIXIR_TEST_ONLY_PATHS='…
    scripts/pds-door-census.sh
    scripts/pds-elixir-receipt-census.exs      <- IT IS IN THE SET
    scripts/pds-record-parity.test.sh
    scripts/pds-status-only-residue.exs
    …'
    git log --oneline -3 origin/main -- scripts/elixir-path-escape-check.sh
    # 626f71f86 test(pds): wire the census and record-parity harnesses to the required Elixir gate (#9333)

#9333 declared it and nobody updated the sentence. The very next sentence in that
header says "A receipt that misstates its own gating is the defect this census
exists to name." It now names itself. Cost of the misstatement: 51.34 s CPU
(R3) charged to the Elixir gate that the header says it does not touch.
