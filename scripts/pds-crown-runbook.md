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

The pre-warm compiles **`MIX_ENV=dev` first, then `MIX_ENV=prod`** (PDS-D755), with
`CC=/usr/bin/clang` on both legs. `dev` is the env the harness actually runs
(`MIX_ENV=dev mix run --no-start` in `pds-pull-proof.sh`) and mix envs do not share a
`_build` tree; the pre-warm used to warm `prod` alone and stamp OK while the climb still paid
its dev compile inside the window. Every pre-warm stamp now names its env.

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
| `attempts: … verdict=SPENT` | the harness ran and its counter MOVED (or could not be read) | an export attempt **was spent** — re-arming is **not** free |
| terminal `WINDOW-EXHAUSTED — ` | invoked ≥ 1×, every invocation a proven zero-spend refusal, draws then exhausted | zero attempts — re-arming is free |
| `FIRE — draw N` with neither of those | pre-re-arm transcript, or killed before it stamped its readings | read as **spent** — `/tmp/pds-full-export/attempts` settles it |
| terminal `STAND-DOWN — ` | draws exhausted, harness never invoked | zero attempts — re-arming is free |
| `prewarm: FAILED rc=` | died at the D241 pre-warm, before draw 1 (the stamp names the failing `MIX_ENV`) | zero attempts — free, but fix that env's compile first |
| none of these | not written by this launcher, or truncated | **UNDIAGNOSED** — read `/tmp/pds-full-export/attempts`, assume nothing |

That order is `collect`'s own: a spend stamp beats an exhaustion stamp beats a bare `FIRE`.
A per-draw line carries `verdict=STAND-DOWN:mem<floor` on *every* refusal; that is a draw,
not the verdict, and it is why the unanchored substring could call a spent attempt free.

### The THIRD outcome, NARROWED — `WINDOW-EXHAUSTED` after zero-spend refusals (PDS-D262)

A climb is usually described as ending as **FIRE** or **STAND-DOWN**. There is still a third,
but it is no longer FIRED-AND-REFUSED: one refusal used to end the poll, and since the re-arm
landed it does not. `refire_verdict()` in the generated child reads the harness's attempts
counter before and after each invocation and returns exactly one of `ZERO-SPEND-REFUSAL` ·
`SPENT` · `SPENT-UNVERIFIED`. Only `ZERO-SPEND-REFUSAL` — `rc != 0` AND both readings numeric
AND equal — re-enters the SAME poll loop. `rc = 0`, a moved counter and an unreadable counter
all exit as before: a spent attempt is the one outcome that must never be retried, so an
unverifiable counter is read as a spend.

What is left is the narrowed third outcome: **the harness was invoked at least once, EVERY
invocation was a proven zero-spend refusal, and the draw budget then ran out.** That is
neither a stand-down (the harness ran) nor a spend (the counter never moved), so it carries
its own terminal stamp `WINDOW-EXHAUSTED — ` and its own sentinel **6** — zero attempts spent,
re-arming free. **Eliminate that case and sentinel 6 and the stamp become unreachable and
this passage is false**; it describes nothing else.

The re-entry buys no budget. It consumes the draw it sat in, `MAX_DRAWS` and the loop
condition are untouched, and every invocation stamps its before/after readings — so
`--max-draws 2160` no longer collapses to one draw on a marginal fire.

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
`CC=/usr/bin/clang MIX_ENV=dev mix compile` and then `CC=/usr/bin/clang MIX_ENV=prod mix
compile` (PDS-D755), and **never** `mix deps.get`, in either form.

Under the **default** pre-warm the death is silent. Measured twice against `origin/main`:
`arm` prints its complete `ARMED — the climb now outlives this turn.` banner with a pid and
`armed in 0s`, and **returns 0** — while the detached child dies seconds later in its own
log with `** (Mix) Can't continue due to errors on dependencies` →
`prewarm: FAILED rc=1 MIX_ENV=dev — NOT firing.` → `EXIT: 1`. **Zero draws**, and nothing in the arming
turn says so. You discover it at `collect`, possibly hours of window later.

`mix deps.get` is the half the pre-warm has never run, and it is why this bites. Pay it in
the arming worktree, before the arm:

```sh
cd api && mix deps.get && CC=/usr/bin/clang MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile
```

The two compiles are now paid by the pre-warm as well (PDS-D755), so running them here only
makes the arm fast. A cold `_build/dev` was **measured at 428 s** on the campaign host
(warm: 3 s for the harness's own `mix run --no-start`) — that is what a prod-only pre-warm
used to leave inside the window, since `pds-scratch-target.sh up --verify` (§3) and the
harness both read the dev tree.

Then arm with **`--prewarm-now`, always**. It does not fetch deps — it still only runs
`mix compile`, once per env — but it moves both compiles into the **arming shell**, where a
failure `die`s loudly, naming the failing `MIX_ENV`, instead of vanishing into a detached
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

## 8. Artifact retention — and the two directories the sweep cannot see

Every run that reaches rung 0a writes a dev-profile export of PRODUCTION content
into `$PDS_ARTIFACT_ROOT/pds-proof-art.<tag>`. **Re-measured, because the filed
"~51 MB" is a mean and not a per-run constant:** 952 MB across the 18 abandoned
directories the ownership trap was built against is a 52.9 MB mean; run
`3fa886ec` (2026-07-20), which took both legs of rung 1, left 55,947,776 B of tar
plus 7,987,874 B of blobs — **63.9 MB in one directory**; the wave-21 fire record
cites 76 MB. A run that ABORTS before the export costs ~4 KB. So the denominator
is *per run that completes rung 0a*, it tracks the dataset's size, and it is
53–76 MB over the measured window.

`pds-pull-proof.sh` removes the directory it created on a CLEAN exit and retains
it after any FAIL, ABORT or non-zero exit — which is correct, and is why a
backlog accumulates: **the directories that survive are exactly the ones from
failed runs.** Two verbs clear it, and they do not overlap:

```sh
scripts/pds-pull-proof.sh --sweep-artifacts            # dry run, then --apply
scripts/pds-artifact-retention.sh --keep 3             # dry run, then --apply
```

**Use the second one after a climb.** The harness sweep's name predicate accepts
`pds-proof-art.<hex>` only, and `pds-crown-launch.sh` exports
`PDS_PROOF_ARTIFACTS=/tmp/pds-proof-art.pds-w14.<hex>` — so **every
launcher-fired run's directory is refused by name**, permanently, and the sweep
reports `0 directory(ies) proved owned` over a disk that is not empty. Measured
on the author's box, 2026-09-16, over the same two real directories: the sweep
refuses both as "not a name this harness makes"; the retention verb accepts both
and falls through to the honest next question (unmarked and younger than 24h).
Correcting the predicate in `pds-pull-proof.sh` needs a chartered thaw (§6);
the retention verb reads both shapes from outside the freeze.

The second difference is recency. The sweep's only recency notion is a 24h floor
for UNMARKED directories, so a marked directory whose run died five minutes ago
is removable — the freshest bundle, which is the one a reader wants after a
red. `pds-artifact-retention.sh` is **keep-N**: the N newest survive whatever
their age, on top of every refusal the sweep makes plus a quiesce window for a
run that may still be writing. It is a dry run unless `--apply` is passed, it
refuses rather than guesses on any knob it cannot evaluate, and it asserts the
parked full-export store byte-unchanged across its own walk — exit 3 if it is
not. `bash scripts/pds-artifact-retention.test.sh` is its 35-arm hermetic
matrix, including the pair that deletes the keep-window clause from a copy and
shows the newest directory being destroyed.

**Never point either verb at `$PDS_FULL_EXPORT_DIR`.** The parked bundle is
deliberately outside the run scope so the next run reuses a sha-matched bundle
for zero attempts; re-taking it costs a ~1.03 GB export against the budget.
