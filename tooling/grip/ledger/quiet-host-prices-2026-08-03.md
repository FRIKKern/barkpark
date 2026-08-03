# quiet-host-prices — re-derivation recipes (PDS wave 44 VERIFY, 2026-08-03)

Re-taking the two candidate door prices D637 named for wave 44, with the only
legal method: an OS meter around a SHELL, never inside a BEAM parent.

Tree under measurement: `origin/main` @ `3f18ab048514f9152d721040a8b283e733a28d33`,
extracted pristine (`git archive origin/main | tar -x -C $S`), never the worktree.

**THE QUIET HOST WAS NEVER REACHED.** Every figure below was taken at load
105–123 on 10 cores, with the 15-minute average still climbing (45.96 → 86.52
across the session). This is disclosed per figure, not averaged away.

## R0 — Is the meter itself leaf-inclusive? (prove it by SUBSTITUTION, not by reading)

D633 proved a BEAM parent is blind to port children. A SHELL parent is not, and
that is the whole reason the law says "around a shell". Demonstrated, not assumed:

    /usr/bin/time -p bash -c 'bash -c "python3 -c \"x=0
    for i in range(8000000): x+=i\""'          # user 0,53  <- grandchild's CPU
    /usr/bin/time -p bash -c 'bash -c "python3 -c \"x=0\""'   # user 0,02  <- burn removed
    /usr/bin/time -p bash -c 'bash -c "sleep 2"'              # real 2,03 / user 0,00

Two levels of nesting deep, the burn shows up in `user`; remove the burn and it
collapses to 0,02; a pure wait moves `real` alone. The meter sees leaves.

## R1 — The load-contamination bound (the thing that makes the rest quotable)

A FIXED workload (the 8M-iteration loop above) run immediately before each trial,
interleaved, so contamination is measured rather than declared:

    for i in 1 2 3; do uptime; /usr/bin/time -p bash -c 'python3 -c "x=0
    for i in range(8000000): x+=i"'; done

    load 105–123     user 0,51 0,53 0,55 0,55 0,57 0,65   span 27%
    same runs        real 1,03 1,09 2,60 3,15 3,59 5,97   span 5,8x

VERDICT, and it decides the unit question: **CPU (user+sys) is load-robust to
within ~25%; WALL is not quotable at all.** A fixed workload swung 5,8x at
essentially constant load. Any price column quoting a wall second is quoting the
host's other tenants.

## R2 — scripts/pds-ledger-census_test.sh

    S=$(mktemp -d); git archive origin/main | tar -x -C $S
    for i in 1 2 3; do uptime; \
      /usr/bin/time -p bash -c "bash $S/scripts/pds-ledger-census_test.sh >/tmp/lc_$i.txt 2>&1; echo rc=\$?"; \
      grep 'SELFTEST PASS' /tmp/lc_$i.txt; done

    trial 1  load 122,93   rc=0  user 36,11  sys 7,95  real 137,55
    trial 2  load 107,02   rc=0  user 36,71  sys 8,30  real 138,56
    trial 3  load 105,67   rc=0  user 34,91  sys 7,65  real 116,13

    CPU (user+sys) 42,6 – 45,0 s

TWO SURVEY FIGURES REFUTED:

* **"107 checks" is wrong — it is 144.** `SELFTEST PASS: 144 checks.`, identical
  in all four runs including the hermetic one.
* **"18,15–20,57 s user" is wrong — it is 34,91–36,71 s user.** R1 bounds load
  inflation of user CPU at ~25%, so contention cannot explain a 2x gap. The
  surveyed figure does not descend from this instrument on this tree.

Consequently **D637's "~20–23 s, viable" disposition does not survive contact.**
The door costs 43–49 s of CPU.

## R3 — Is the census hermetic? (the claim that lets it be gated at all)

    /usr/bin/time -p env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
      HOME=/tmp/emptyhome bash -c "mkdir -p /tmp/emptyhome; \
      bash $S/scripts/pds-ledger-census_test.sh >/tmp/lc_envi.txt 2>&1; echo rc=\$?"

    load 106,13   rc=0   user 39,86  sys 9,48  real 136,67   SELFTEST PASS: 144 checks.

CONFIRMED — empty environment, empty HOME, minimal PATH, still green. Note the
CPU is the HIGHEST of the four runs (49,3 s), so the hermetic arm is not cheaper.

## R4 — scripts/pds-live-hetzner-placement-group.sh --selftest-offline

    for i in 1 2 3; do uptime; \
      (cd $S && /usr/bin/time -p bash scripts/pds-live-hetzner-placement-group.sh \
         --selftest-offline >/tmp/hz_$i.txt 2>&1); done

    trial 1  load 115,43   rc=0  user 1,75  sys 2,00  real 11,07
    trial 2  load 119,47   rc=0  user 1,77  sys 2,00  real 11,01
    trial 3  load 113,17   rc=0  user 1,83  sys 2,07  real 12,33

    CPU (user+sys) 3,75 – 3,90 s

Closing line, verbatim: `PASS  the credential-free arm holds: 0 hetzner/hcloud
variables, 4 mutation blocks, the deposit fail-open reproduced and closed, the
segment pin able to red, the target count derived, and the committed manifest
reproduced by its own emitter`.

**sys (2,0 s) EXCEEDS user (1,8 s) on this door.** A user-CPU-only column
understates it by 2,1x — and that is a pure CPU fact, owing nothing to the wall
argument or to the load. The census hides this (sys/user = 0,23); hetzner exposes
it (sys/user = 1,1) because it is spawn-dominated: one `curl` process per check
against a loopback stub.

## R5 — Determinism, i.e. can either door carry a byte-identical ratchet?

    md5 -q /tmp/hz_1.txt /tmp/hz_2.txt /tmp/hz_3.txt
    diff /tmp/hz_1.txt /tmp/hz_2.txt        # -> ONLY the real/user/sys lines
    md5 -q /tmp/lc_1.txt /tmp/lc_2.txt /tmp/lc_3.txt
    diff /tmp/lc_1.txt /tmp/lc_3.txt

* hetzner: content byte-identical across runs; the only diff is the meter's own
  timing lines. RATCHETABLE.
* census: trials 1 and 2 identical, trial 3 differs by ONE byte —
  `--json alone is pipeable  exit 0  (jq ok, 1382 bytes on stdout)` vs `1383
  bytes`. The payload size is not run-stable, so a byte-identical ratchet over
  the census's `--json` is NOT available. Field not attributed; the census
  script itself contains no wall-clock emitter (see R6).

## R6 — Which instrument actually prints the D605-forbidden `wall clock N ms`?

The digest attributes it to "the census". There are two censuses and it is the
other one:

    grep -rn 'wall clock' $S/scripts/
    grep -n 'elapsed\|duration\|wall' $S/scripts/pds-ledger-census.sh

`scripts/pds-ledger-census.sh` — ZERO hits. The emitter is
`scripts/pds-elixir-receipt-census.exs:6605`:

    p("wall clock  #{ms} ms  (build-free: no mix project, no compile, no app boot)")

An `.exs` — i.e. it self-times from INSIDE a BEAM parent, which is precisely the
meter D633 proved blind. Do not attach this defect to `pds-ledger-census.sh`.

## R7 — The stub-server wait is capped and is NOT a fail-open

    sed -n '1268,1274p' $S/scripts/pds-live-hetzner-placement-group.sh

    while [ ! -s "$portfile" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
    STUB_PORT="$(cat "$portfile" 2>/dev/null || true)"
    [ -n "$STUB_PORT" ] || failed "the localhost stub server did not come up"

Capped at 5,0 s, then asserted. Checked because it is the only `sleep` in either
door, i.e. the only intrinsic (non-contention) wall component in the pair — worth
at most 5 s, and on a quiet host ~0,1 s.

## R8 — What NOBODY has measured, and the honest CI figure

No door in this inventory has EVER been measured on `ubuntu-latest` (2–4 vCPU)
— every figure in D637, in wave 43, and above is a 10-core Apple-Silicon mac
under wave load. The mac→CI direction is unfavourable on both axes (fewer cores,
slower single-thread, and hetzner is spawn-dominated where CI is slowest).

THE ONLY HONEST CI FIGURE IS THE ONE THE DOOR'S OWN FIRST CI RUN PRINTS. A price
column that ships a projected CI number repeats, one level up, the move wave 43
refused in writing. Ship the local CPU figure LABELLED as local, and let the
first green run overwrite it.
