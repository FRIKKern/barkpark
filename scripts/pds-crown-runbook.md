<!-- doc-tier: human | canonical-for: pds-crown-proof-operating-procedure | budget: 6000tok -->

# PDS crown proof — operating runbook

How to run `scripts/pds-pull-proof.sh` end to end against the live guerrilla source
plane, and what to do with every colour it prints.

This runbook is written for the operator who fires the climb. It is deliberately
short on rationale and long on preconditions, because the expensive failures in
this proof are all environmental and all silent.

Companion artifacts:

- `scripts/pds-crown-launch.sh` — the detached launcher: `arm` fires, `collect` reads (§0).
- `scripts/pds-pull-proof.sh` — the instrument. **FROZEN** (see §6).
- `scripts/pds-scratch-target.sh` — boots/tears down the disposable local target.
- `scripts/pds-secret-scan.sh` — the value-based scanner, consumed by rung 4.
- `scripts/pds-pull-proof.crown-transcript.txt` — the append-only run record.
- `scripts/pds-crown-climb-runbook.md` — the preflight-and-sequence card; same §0 applies.

---

## 0. Arm and collect — the climb is DETACHED

The climb is not fired in the foreground of the turn that starts it. It is **armed** by one
command that returns immediately, and **collected** later — by a different actor, possibly
hours later.

```sh
scripts/pds-crown-launch.sh arm --prewarm-now   # fires the child DETACHED and returns; does not poll
scripts/pds-crown-launch.sh collect             # classifies the transcript; read-only, run it as often as you like
```

`--prewarm-now` is **not optional** — see §2(g), PDS-D258. The default pre-warm compiles
inside the detached child, where its failure is invisible until `collect`.

`arm` hands the poll loop to a child process that outlives the arming turn. `collect`
classifies that child's transcript into exactly **six** states (PDS-D247):

```
NO-TRANSCRIPT · CRASHED · FINISHED · FINISHED-nosent · STILL-RUNNING · KILLED
```

There is no seventh state — if you are about to write one down, you are guessing. On
`KILLED`, `collect` also reports the stranded export lock; that lock is the one a later
actor must **not** `rmdir` blindly (PDS-D31 — two concurrent full exports OOM the box).

`CRASHED` is the state that decides whether re-arming is free, so it is sub-diagnosed
from anchored stamps in the transcript's own bytes rather than a substring (PDS-D252):

| stamp present | what it means | cost |
|---|---|---|
| `FIRE — draw N` | the harness RAN | an export attempt **was spent** — re-arming is **not** free |
| terminal `STAND-DOWN — ` | draws exhausted, never invoked | zero attempts — re-arming is free |
| `prewarm: FAILED rc=` | died at the D241 pre-warm, before draw 1 | zero attempts — free, but fix the compile first |
| none of the three | not written by this launcher, or truncated | **UNDIAGNOSED** — read `/tmp/pds-full-export/attempts`, assume nothing |

A per-draw line carries `verdict=STAND-DOWN:mem<floor` on *every* refusal; that is a draw,
not the verdict, and it is why the unanchored substring could call a spent attempt free.

The `FIRE — draw N` row has one exception, and it is PDS-D262's third outcome below: if the
harness refused on its *own* precondition (b) after the launcher handed off, it returned
above the spend increment and the attempt was **not** spent. `/tmp/pds-full-export/attempts`
settles it; the stamp alone does not.

### The THIRD outcome — the launcher is ONE-SHOT (PDS-D262)

An armed climb is usually described as ending as **FIRE** or **STAND-DOWN**. There is a
third. A draw clears the launcher's gate, the launcher hands off, and `pds-pull-proof.sh`
then refuses on its own precondition (b) because the box moved in the seconds between the
two reads. The launcher does not loop back:

```sh
"$HARNESS" --all        # pds-crown-launch.sh:362-366
rc=$?
stamp "harness returned rc=$rc after $draw draw(s)"
sentinel "$rc"
exit "$rc"              # ← unconditional; the poll loop is over
```

**FIRED-AND-REFUSED costs zero export attempts and the entire window.** `--max-draws 2160`
collapses to one draw and the remaining hours of polling never happen.

**Do not add a re-arm loop.** Re-firing on a refusal is how a marginal window becomes the
pounce §2(f) forbids, and the one-shot shape is what prevents it. The sanctioned response is
the same as for a stand-down: `arm` again, deliberately, after re-reading the preflight.

### (i) The two env lines that must be in the SAME shell as `arm` (PDS-D251)

```sh
export PDS_CONTROL_PG=postgres     # or a fuller LOCAL maintenance conninfo
unset PDS_AMMO_FILE
```

Neither is optional, and neither fails loudly when forgotten:

- **Without `PDS_CONTROL_PG`**, rung 4's gate at `pds-pull-proof.sh:1730` is false, the
  instrument control never runs, and `:1743` prints `instrument control: NOT RUN` at
  **INFO** level — after which the rung reaches a terminal **PASS** anyway. That is a
  permanently asterisked rung: a clean scan whose scanner was never shown able to fire.
  A shell assignment that is not *exported* produces exactly this vacuous green.
- **Without `unset PDS_AMMO_FILE`**, any ambient value short-circuits `resolve_ammo()` at
  `pds-pull-proof.sh:1659` *before* it reaches the source DB, silently substituting whatever
  that file names for the real SSH-derived webhook secrets.

`PDS_CONTROL_PG` is a maintenance conninfo for a **LOCAL** Postgres, in which the scan
creates and then drops its own throwaway fixture. It points at **no Barkpark database at
all**, and aiming it at guerrilla is a category error rather than a shortcut — the control
spends zero guerrilla export by construction.

**The named price:** exporting it converts a silent INFO line into a **hard-fail leg**. A
control that does not behave as a control takes rung 4 down with it. So prove it *before*
arming, not after — and prove the right thing. `pg_isready` says only that something
answers; the control does `CREATE DATABASE "pds_secret_scan_ctl_<pid>"`
(`pds-secret-scan.sh:327`) and needs the privilege to do it. A live-but-unprivileged
Postgres passes `pg_isready` and hard-fails rung 4 hours later. Run the control itself,
which is the exact leg rung 4 will run and spends zero guerrilla export by construction:

```sh
pg_isready                                       # necessary, not sufficient
scripts/pds-secret-scan.sh control --pg postgres  # THE proof — must exit 0
```

### (ii) What clearance actually looks like (PDS-D250)

Precondition (b) of the full export is `MemAvailable >= 2200 MB`. **A stand-down is the
EXPECTED outcome of an armed climb, and it is a first-class win** — not a failure to route
around. An armed child that draws honestly and never fires has told you the truth about the
box.

Measured: a gapless 1200-sample, 1 Hz, 1249-second window yielded **862 build-idle draws,
of which ZERO cleared 2200**. Idle ceiling **1948.13 MiB** — 251.87 MiB below the floor at
*every single sample* — longest contiguous clearing run **0 s**. Four further live
build-idle reads the same morning: 1857.92, 1707.36, 1897, 1903 MiB.

The ruling that follows:

- **Polling is free.** The failed-precondition return sits *above* the spend increment, so
  a refused window costs zero export budget. Draw as often as you like.
- **The floor NEVER moves.** `PDS_FULL_EXPORT_MIN_MEM_MB` encodes a real OOM risk to the
  LIVE content API and is the most tempting, most dishonest lever available (§6, PDS-D156).
  It is not a knob.
- **The draw budget goes UP instead.** The sanctioned response to a stand-down is more draws
  over more wall-clock (`--max-draws` / `--interval` on `arm`), never a lower floor.

---

## 1. The one-paragraph shape

The harness climbs eleven rungs (`0a 0b 0c 1 2 3 4 5 6 7 8`) against two planes:
the **source** is live guerrilla (`157.180.90.121`), read-only; the **target** is a
disposable Barkpark booted on the operator's own host by `pds-scratch-target.sh`.
Nine rungs need only the cheap dev export (~7 s, ~53 MB). **Only rungs 3 and 4
consume the one budgeted full-fidelity export**, which is the firing control for
both of them. That export is the whole cost of the run and it is capped at a
single ATTEMPT — not a single success.

## 2. Preconditions, in the order they bite

### (a) One shared root, exported — not assigned

The harness pins `BARKPARK_HOME` and `PDS_SCRATCH_POINTER` per-invocation from a
`date+$$` run tag, while `pds-scratch-target.sh` mktemps its own root when they
are unset. Two unpinned invocations therefore allocate two *different* roots and
every target-reading rung aborts `env:scratch-target-not-booted` — which looks
exactly like an honest environmental blocker and is not one.

Pin them yourself, to one short root, in the shell that runs *both* commands:

```sh
export BARKPARK_HOME=/private/tmp/pds-w7
export PDS_SCRATCH_POINTER=/private/tmp/pds-w7.last
```

Use `/private/tmp/...`, not `/tmp/...`, on macOS. The pointer's write path
canonicalises with `cd -P` while its read path returns `BARKPARK_HOME` verbatim,
so a `/tmp` root can never string-match its own realpathed pointer and teardown
leaves it dangling. Naming the canonical path sidesteps the mismatch without
touching a frozen script.

### (b) `PDS_CONTROL_PG` must be EXPORTED

```sh
export PDS_CONTROL_PG=postgres     # or a fuller maintenance conninfo
```

Rung 4 gates its own instrument control on `[ -n "${PDS_CONTROL_PG:-}" ]`. Unset,
the rung prints `instrument control: NOT RUN` **and still reaches a terminal
PASS** — a clean scan whose scanner was never shown able to fire. A shell
assignment that is not exported does not survive into the harness and produces
exactly that vacuous green. The value needs a local Postgres the caller may
`CREATE DATABASE` on; the control builds and drops its own throwaway fixture and
spends zero guerrilla export.

### (c) `PDS_AMMO_FILE` must be UNSET

```sh
unset PDS_AMMO_FILE
```

`resolve_ammo()` short-circuits on it *before* reaching for the source DB, so any
ambient value silently replaces the live webhook secrets with whatever it names.
A stale or partial real ammo file is the dangerous shape: it passes all three of
rung 4's legs while measuring almost nothing.

### (d) Leave the two demo switches alone

`PDS_STEP5_FAILDEMO` and `PDS_STEP6_GUARD_DEMO` both default to `1`. They are what
make rungs 5 and 6 mutation-proven rather than passively green. A run that
disables either says so in its own PASS line and does not satisfy the criteria.

### (e) Sweep the box before firing — the sampler aims by PID

The RSS sampler selects its target with `pgrep -f beam.smp | head -1`. `-f`
matches the **full command line**, so any process whose arguments merely contain
that string matches, and `head -1` takes the **lowest PID** — which is not the
BEAM whenever a longer-lived matcher exists. The observed failure mode is a
transcript that reports `beam.smp RSS peaked at 1 MB` as the run's own measured
peak, on the single unrepeatable attempt.

This is a harness bug (`pds-bl-harness-pgrep-wrong-process`). Its remedy is
**environmental**, and therefore legal under the freeze: the defect only fires
when a lower-PID matcher exists.

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'echo "head-1: $(pgrep -f beam.smp | head -1)"; echo "pgrep-o: $(pgrep -o beam.smp)"'
```

Fire only when the two are **equal**. Assert the equality immediately *before* and
immediately *after* the attempt and record both readings in the transcript.

Corollaries the operator owns:

- Your own diagnostic shells match too. Use single-shot reads; never leave a
  process alive on the box whose command line contains the literal.
- A matcher belonging to another session is **waited out, not killed**. Attribute
  it in the transcript.
- If equality cannot be established, do not fire. A figure you cannot vouch for
  is worse than no figure.

### (f) Gate (b) is check-and-go, never a pounce

`MemAvailable >= 2200 MB` is precondition (b) of the full export. It is closed far
more often than it is open — see §0(ii): 862 build-idle draws, **zero** cleared,
idle ceiling 1948.13 MiB. **Polling is free**: a closed gate returns *before* the
attempt counter increments, so a refused window costs zero budget. If it is closed,
keep drawing; a stand-down is the expected outcome, not a blocker to work around.

Do **not** wait for or request a deploy. The restart curve is a memory *trough*
first (both t+15 s and t+20 s readings sit far below the floor; sustained
clearance resumes only around t+200 s), a deploy breaks precondition (a) by moving
the served sha out from under the pin taken at rung 0a, and a manufactured restart
costs live content-API downtime and retracts the banner's "nothing is written to
the source" claim.

The gate has a **second leg**: the `bp-site-build-*` listing must be empty. Read it with the
launcher's own selector (`pds-crown-launch.sh:293`) and nothing else:

```sh
systemctl list-units 'bp-site-build-*' --state=running --no-legend --plain | wc -l
```

**Never** `pgrep -c -f 'bp-site-build-'`. Run as an ssh *remote command* it **self-matches**:
the pattern rides inside the remote `bash -c` argv, so `pgrep -f` counts the shell asking the
question and returns a **phantom 1**. Measured — `pgrep -a -f` showed the sole match *was*
that ssh `bash -c`, while the `systemctl` selector read **0** at the same instant. Trusting
the phantom stands you down on an idle box.

Read the gate immediately before launching, and record the reading either way.

### (g) The arming worktree must already be WARM (PDS-D258)

Listed last, it bites **first** — before every precondition above, because it kills the
`arm` itself.

`api/deps` and `api/_build` are **gitignored**, so the fresh `origin/main` worktree the climb
is required to run from (PDS-D225) has neither. The launcher's pre-warm runs
`CC=/usr/bin/clang MIX_ENV=prod mix compile` and **never** `mix deps.get`, in either form.

Under the **default** pre-warm the death is silent. Measured twice against `origin/main`:
`arm` prints its complete `ARMED — the climb now outlives this turn.` banner with a pid and
`armed in 0s`, and **returns 0** — while the detached child dies seconds later in its own
log with `** (Mix) Can't continue due to errors on dependencies` →
`prewarm: FAILED rc=1 — NOT firing.` → `EXIT: 1`. **Zero draws**, and nothing in the arming
turn says so. You discover it at `collect`, possibly hours of window later.

Pay it in the arming worktree, before the arm — **both** compiles:

```sh
cd api && mix deps.get && MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile
```

The pre-warm only ever builds `MIX_ENV=prod`; the dev build is what
`pds-scratch-target.sh up --verify` pays (§3) as a >10-minute cold compile once the climb is
already running.

Then arm with **`--prewarm-now`, always**. It does not fix a cold tree on its own — it still
only runs `mix compile` — but it moves that compile into the **arming shell**, where a
failure `die`s loudly at `pds-crown-launch.sh:441-444` instead of vanishing into a detached
child. The default form is **forbidden for a fresh worktree** for exactly that reason.

`scripts/pds-climb-preflight.sh` check 5 asserts all of this, read-only, before you arm.

## 3. The invocation

One `--all`, never split:

```sh
export BARKPARK_HOME=/private/tmp/pds-w7 PDS_SCRATCH_POINTER=/private/tmp/pds-w7.last
export PDS_CONTROL_PG=postgres
unset PDS_AMMO_FILE

./scripts/pds-scratch-target.sh up --verify     # cold: >10 min, two Elixir compiles
./scripts/pds-pull-proof.sh --all
./scripts/pds-scratch-target.sh teardown
```

`--only 3,4` is forbidden and a split climb is worse than a partial one.
Rung 6's guard-off control deliberately **clobbers** the target, and its
terminality is enforced only by `canonical_order()` plus rung 4's
"was a bundle imported *this run*" guard — both of which are per-invocation. Run
the cheap rungs now and 3/4 later against the same target and rung 4 scans
step-6 wreckage and prints CLEAN off contaminated state.

Severability still holds *within* one run: `run_steps` is an unconditional loop
with no short-circuit, so an aborted 3/4 still lets 5/6/7/8 execute.

Do not kill a running export. The attempt counter is written *before* the request
fires, so a killed run burns the attempt anyway and gets nothing for it.

## 4. Reading the output

Two strings must appear literally in a run whose rung 4 means anything:

```
instrument control: PASSED
8 webhook secret(s) pulled read-only from the source DB this run
```

The wording `N value(s) from PDS_AMMO_FILE` anywhere is a failed run — precondition
(c) leaked. `instrument control: NOT RUN` anywhere is a failed run — precondition
(b) leaked.

Quote the harness's RSS line **verbatim** and then annotate its scope. The sampler
measures RSS only, at 1 Hz, so its peak is a **lower bound** whose value depends on
sampling phase: six measurement methods agree to within 0.5% at the same instant,
but the same PID was observed going 1,024,468 kB → 216,852 kB in 55 s while its
`VmSwap` rose 51,624 → 874,760 kB. The stable invariant is `RSS + VmSwap`, not RSS.
Sample `VmSwap` out-of-band alongside and say so. Never extrapolate one leg's
multiplier onto another — a paired measurement of the cheap leg gives a confidence
interval that spans zero.

## 5. Sorting a red — the bucket rule

Every red sorts into exactly one bucket **before** anything is touched:

| Bucket | What it is | What you do |
|---|---|---|
| **HARNESS BUG** | The instrument measured the wrong thing | File it. If a correction is ever authored, the corrected assertion must be *shown still failing* on the pre-fix condition. Under the freeze (§6) it is filed, not fixed. |
| **ENGINE FAIL** | The data plane genuinely misbehaved | File it. Do **not** fix it in this wave. |

A FAIL in the transcript is the *interesting* outcome. It is never downgraded,
never re-run until green, never explained away. The most dangerous act available
to the operator is editing the harness until a red disappears, because that
converts an engine failure into a confident-wrong transcript at exactly the moment
it is most tempting.

## 6. The freeze

From attempt 1 onward, `pds-pull-proof.sh`, `pds-secret-scan.sh` and
`pds-scratch-target.sh` are **frozen**. Prove it at gate time:

```sh
git diff --stat origin/main -- scripts/pds-pull-proof.sh \
  scripts/pds-secret-scan.sh scripts/pds-scratch-target.sh   # MUST be empty
```

Also forbidden: lowering `PDS_FULL_EXPORT_MIN_MEM_MB` (an env var rather than a
harness edit, which makes it the most tempting and most dishonest lever available,
and it endangers the live content API); a manufactured restart; and deleting any
earlier attempt's reds from the append-only transcript.

## 7. The closing rule

The crown-proof task closes **only** if rungs 3 and 4 pass with their controls
FIRING off the one full bundle, and rungs 1/2/5/6 pass against a real booted
target. A severable headroom abort of 3/4 is an honest designed outcome and does
**not** close it. The gate is now known to be closed on essentially every idle draw
(§0(ii)), so both temptations are live: "lower the floor" and "call a lucky partial
the crown proof". Refuse both.
