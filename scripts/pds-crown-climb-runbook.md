<!-- doc-tier: human | canonical-for: pds-crown-climb-preflight-sequence | budget: 7000tok -->

# PDS Crown Climb — Runbook

The crown climb is ONE unsplit `scripts/pds-pull-proof.sh --all` under a single run id.
This file is the operator's card for it: the rulings that govern the fire, the traps that
have actually bitten, and the exact sequence.

Sibling card: `scripts/pds-crown-runbook.md` owns the *operating procedure* (preconditions,
reading the output, the freeze, the closing rule). This card owns the *preflight and
sequence*. §0 below is common to both.

---

## §0 — Arm and collect: the climb is DETACHED

The climb is not fired in the foreground of the turn that starts it. It is **armed** by one
command that returns immediately, and **collected** later — by a different actor, possibly
hours later.

```
scripts/pds-crown-launch.sh arm --prewarm-now   # fires the child DETACHED and returns; does not poll
scripts/pds-crown-launch.sh collect             # classifies the transcript; read-only, run it as often as you like
```

`--prewarm-now` is **not optional** — see *PDS-D258* below. The default pre-warm compiles
inside the detached child, where its failure is invisible until `collect`.

`arm` hands the poll loop to a child process that outlives the arming turn. `collect`
classifies that child's transcript into exactly **six** states (PDS-D247):

```
NO-TRANSCRIPT · CRASHED · FINISHED · FINISHED-nosent · STILL-RUNNING · KILLED
```

There is no seventh state — if you are about to write one down, you are guessing. On
`KILLED`, `collect` also reports the stranded export lock; that is the lock a later actor
must **not** `rmdir` blindly (PDS-D31, and see check 3's lock rule below).

### PDS-D262 — the launcher is ONE-SHOT, so there is a THIRD outcome

An armed climb is usually described as ending one of two ways: **FIRE** (a draw qualified,
the harness ran) or **STAND-DOWN** (every draw refused, zero attempts spent, re-arming is
free). There is a third, and it is the expensive one:

**FIRED-AND-REFUSED.** A draw clears the launcher's gate, the launcher hands off — and then
`pds-pull-proof.sh` itself refuses on its own precondition (b), because the box moved in the
seconds between the two reads. The launcher does not loop back:

```sh
"$HARNESS" --all        # pds-crown-launch.sh:362-366
rc=$?
stamp "harness returned rc=$rc after $draw draw(s)"
sentinel "$rc"
exit "$rc"              # ← the poll loop is over, whatever rc says
```

That `exit` is unconditional. A marginal fire costs **zero export attempts** — the harness
refused above the spend increment — but it **burns the entire window**: `--max-draws 2160`
becomes one draw, and the remaining six hours of polling never happen. The transcript shows
a `FIRE` stamp with no export, which reads like a crash and is not one.

**Do not add a re-arm loop.** Re-firing on a refusal is how a marginal window becomes a
pounce, and the launcher's one-shot shape is the thing preventing that. The sanctioned
response is the same as for a stand-down: `arm` again, deliberately, from a shell where you
have just re-read the preflight.

### The two env lines that must be in the SAME shell as `arm` (PDS-D251)

```
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

```
pg_isready                                       # necessary, not sufficient
scripts/pds-secret-scan.sh control --pg postgres  # THE proof — must exit 0
```

### What clearance actually looks like (PDS-D250)

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
- **The floor NEVER moves.** `PDS_FULL_EXPORT_MIN_MEM_MB` is listed below among the
  forbidden knobs for exactly this reason, and a measured-closed gate does not promote it.
- **The draw budget goes UP instead.** The sanctioned response to a stand-down is more draws
  over more wall-clock (`--max-draws` / `--interval` on `arm`), never a lower floor.

### Reading the OTHER half of the gate — site builds

The draw gate is `mem_mib >= floor` **AND** the `bp-site-build-*` listing being empty. If you
are checking that second leg by hand, use the launcher's own selector
(`pds-crown-launch.sh:293`) and nothing else:

```sh
systemctl list-units 'bp-site-build-*' --state=running --no-legend --plain | wc -l
```

**Never** reach for `pgrep -c -f 'bp-site-build-'` here. Run as an ssh *remote command* it
**self-matches** — the pattern travels inside the remote `bash -c` argv, so `pgrep -f` counts
the very shell asking the question and returns a **phantom 1**. Measured: `pgrep -a -f` showed
the sole match *was* the ssh `bash -c`, while the `systemctl` selector read **0** at the same
instant. An operator trusting the phantom stands down on a box that was in fact idle, and
spends a window waiting for a build that does not exist.

---

**Everything here that can be measured is measured by `scripts/pds-climb-preflight.sh`.**
Run that first, every time, including before a retry. It is read-only: it fires no export,
takes no PDS-D31 lock, writes nothing under `/tmp/pds-full-export`, and therefore costs
zero export budget. Run it a hundred times if you like.

```
scripts/pds-climb-preflight.sh            # report, exit 0 always
scripts/pds-climb-preflight.sh --strict   # 0 = GO · 2 = GO WITH WARNINGS · 1 = NO-GO/UNKNOWN
```

The default exits 0 even on NO-GO on purpose: this script is committed and runs from
ordinary builder worktrees, where check 1 is *expected* to be red. A gate that reds where
it cannot be green teaches people to skip it. Use `--strict` when an exit code is what you
are acting on.

---

## The invocation — and the flag that does not exist

```
scripts/pds-pull-proof.sh --plan          # the safe default (also: no arguments at all)
scripts/pds-pull-proof.sh --all           # THE CLIMB
scripts/pds-pull-proof.sh --only 0a,0b,7  # one comma-separated list, nothing after it
scripts/pds-pull-proof.sh --help
```

**`--step` IS NOT A FLAG.** The parser (`pds-pull-proof.sh:2574-2603`) accepts exactly
`--plan`, `--all`, `--only <ids>` and `--help`; everything else falls to `*)`, which prints

```
usage: pds-pull-proof.sh {--plan|--all|--only <ids>|--help}
```

to stderr and **exits 3 having run nothing at all**. That one line is short, calm, and
easy to skim as a clean run — several waves' worth of "I ran step N" was this. If you did
not see step banners and a summary table, no step executed.

`--only` and `--all` also refuse trailing arguments rather than dropping them silently
(PDS-D89): `--only 0a --plan` used to take a real live export while saying nothing about
the flag it ignored.

## Where the export spills — NOT /tmp

The streaming spill directory on the box is:

```
/opt/barkpark/api/tmp/bundle-spill
```

**Not `/tmp`.** A `ls -d /tmp/bp-ws-*` on guerrilla returns `No such file or directory`
*even in the middle of a live export* — measured. Anyone watching that glob to decide
whether an export is running will mis-sort a healthy in-flight export as "no export ran"
and conclude the harness never fired.

---

## PDS-D225 — climb from a fresh `origin/main` worktree

**The rule:** the climb runs from a worktree whose `HEAD == origin/main`, whose tree is
clean, and whose `scripts/pds-pull-proof.sh` blob is `e219e97ccf7f33797c86a2b84d998d599b6bda31`.
Check 1 asserts all three.

**The stated reason in PDS-D212 is REFUTED. Do not repeat it.** D212 says step 0b *fails*
from the primary checkout. Measured today, that is false:

| | |
|---|---|
| primary checkout `HEAD` | `de42c2af0e0c7f3eb0e44fe12922a2e852e0eb4e` |
| deployed sha | `bc64d869a3a82beb1b39824196f60236b2082dbc` |
| `git merge-base --is-ancestor <deployed> HEAD` | **true — 0b would PASS** |
| primary harness blob | `e219e97…31` — intact |

A reviewer who checks the old justification will find it false and may conclude the rule
itself is bunk. It is not. **The rule survives on VOLATILITY, not on a red.**

The primary checkout is a live, shared working copy that other sessions move under you.
Inside this epic it has been observed at `1ccf6206a`, then `b3dac3e8e` *within one
session*, and it reads `de42c2af0` as this runbook is written — three shas, and the last
one is **ahead of `origin/main`**, i.e. it carries commits the deployed box has never
seen. Rung 0b is *tolerant* of the worktree being ahead, so that specific drift passes —
but the differential the climb produces is dated by step 0a's pin, and a checkout that can
change identity mid-run cannot date anything. A climb that takes 40+ minutes must run on
ground that does not move.

Corollary (PDS-D154): **the freeze value is a GIT BLOB hash — verify with `git rev-parse`,
never `shasum`.** `shasum -a 1` over the same bytes answers `b9eb6e3a…`; a verifier
reaching for it at fire time concludes the freeze broke and burns the window chasing a
phantom. Check 1 uses `git rev-parse HEAD:scripts/pds-pull-proof.sh` only.

Corollary (PDS-D159): a rehearsal red is a **filed task**, never a harness edit. The
harness is frozen. If a rung is wrong, the climb does not happen this wave.

## PDS-D258 — that fresh worktree is COLD, and a cold worktree cannot arm

D225 above sends you to a worktree cut fresh at `origin/main`. **`api/deps` and `api/_build`
are gitignored, so that worktree has neither.** The launcher's pre-warm runs
`CC=/usr/bin/clang MIX_ENV=prod mix compile` and **never** runs `mix deps.get`, in either
form — so it dies on dependencies it was never going to fetch.

Under the **default** pre-warm that death is silent. Measured twice against `origin/main`:

```
ARMED — the climb now outlives this turn.
  pid         15098
  armed in    0s
```

`arm` returns **0** in under a second, having printed the complete success banner — and the
detached child dies seconds later, inside its own log:

```
[..] prewarm: cd /private/tmp/pdsw16-envwt/api && CC=/usr/bin/clang MIX_ENV=prod mix compile
** (Mix) Can't continue due to errors on dependencies
[..] prewarm: FAILED rc=1 — NOT firing.
EXIT: 1
```

**Zero draws.** Nothing in the arming turn says so; you find it at `collect`, which may be
hours later, having spent the whole window on a process that was already dead.

**Pay the warm-up in the arming worktree, before the arm:**

```sh
cd api && mix deps.get && MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile
```

Both compiles, not one. The pre-warm only ever builds `MIX_ENV=prod`; the dev build is what
`pds-scratch-target.sh up --verify` pays, as a >10-minute cold compile, once the climb is
already running.

**Then arm with `--prewarm-now`, always.** It does *not* fix a cold tree by itself — it still
only runs `mix compile` — but it moves the compile into the **arming shell**, where a failure
`die`s loudly at `pds-crown-launch.sh:441-444` instead of vanishing into a detached child.
The default form is **forbidden for a fresh worktree** for exactly that reason. Check 5 of
the preflight asserts all of this before you get there.

## PDS-D224 — the budget is `spent + 2`, derived at run time

`acquire_full_bundle`'s condition (c) tests `spent < FULL_BUDGET`
(`pds-pull-proof.sh:1313`). `FULL_BUDGET` defaults to **1**. So on a host whose
`/tmp/pds-full-export/attempts` already reads 1, **the climb cannot fire at all** — cond_c
is false before a byte moves.

The required budget is therefore **read at run time and computed**, never a literal:

```
required PDS_FULL_EXPORT_BUDGET = <attempts read now> + 2
```

Two, because the climb is allowed one fresh export plus one retry after a red. Never a
hardcoded 3: **the attempt store is HOST-LOCAL (PDS-D156)** — `FULL_DIR` is the literal
`/tmp/pds-full-export` while `BARKPARK_HOME` is RUN_TAG-scoped, so `attempts=1` is a fact
about one Mac. A climb host reading 0 needs 2, and telling it 3 quietly buys an extra
un-budgeted export. Check 2 prints the attempts value beside the arithmetic so the
derivation is visible, not asserted.

**Forbidden knobs, in order of temptation:**

- `PDS_FULL_EXPORT_MIN_MEM_MB` — **never.** It encodes a real OOM risk to the LIVE content
  API and is the most tempting and most dishonest act available (PDS-D156).
- Resetting or hand-editing `/tmp/pds-full-export/attempts` — forbidden (PDS-D212). A dead
  export still paid its memory peak; that is precisely why the counter moves *first*.
- Repointing `PDS_FULL_EXPORT_DIR` — forbidden for a real climb (PDS-D223). It hides a
  spend instead of paying it. The preflight honours the override so its warn path can be
  rehearsed, and says `REHEARSAL STORE` out loud whenever it is set.

Raising `PDS_FULL_EXPORT_BUDGET` deliberately is the *one* sanctioned knob (PDS-D137/D156).

## PDS-D223 — the parked bundle and the RETRY-REUSE TRAP

Reuse of the parked bundle is provenance-gated (`pds-pull-proof.sh:1268-1283`): if the
`.meta` sidecar's `served_sha` equals the sha step 0a pinned, the bundle is **REUSED for 0
attempts**; if it differs, the harness prints `STALE … Not reused` and buys a fresh one.

Today the parked bundle is stale — `served_sha 15e057f83…` against deployed `bc64d869a…` —
so the first `--all` takes a fresh export. **That is exactly what arms the trap.**

The moment that fresh export lands, the harness writes a `.meta` stamped with the
**currently deployed sha** (`:1452`). A **second** `--all` after a red then matches the
reuse gate and silently consumes the first invocation's bytes for 0 attempts. Rungs 3 and
4 of the retry would scan a bundle taken by *another invocation* while the transcript
dates the differential with *this* run's pin — a criterion-11 mosaic walking straight
through the sanctioned path with no warning anywhere in the output.

**Therefore: re-run the preflight before ANY retry.** Check 3 prints `served_sha` beside
the deployed sha in every state and WARNs when they match, naming the trap.

**The sanctioned fix is to DELETE the parked `.tar` (and its `.meta`) before the retry.**
D223 permits this specifically because it *spends* budget rather than hiding the spend —
the retry then takes its own fresh export against its own pin and the counter records it.
Deleting the tar is allowed; resetting attempts and repointing the store are not.

Check 3 also stats `$FULL_DIR/lock` (never `mkdir`s it). A held lock means another full
export is in flight, and two concurrent full exports OOM the box (PDS-D31) — that is a
NO-GO, and you must **not** `rmdir` a lock your process did not create. This is not
theoretical: a concurrent run held the lock during this script's own first live run, and
released it seconds later.

## Check 4 — the fire window

`deploy.yml` fires on pushes to `cloud/**`, `api/**`, `internal/**`, `deploy/**`,
`templates/**`, `connectors/**` and `.github/workflows/deploy.yml`. But only the *instance*
job moves guerrilla's sha, and it is gated more narrowly on `^(api|internal|deploy|connectors)/`
(`deploy.yml:72`). **`cloud/**` and `templates/**` are absent from that filter**, so a
cloud-only merge can never move the box — and `scripts/**` is not in `on.push.paths` at
all, which is why this slice's own merge is deploy-inert.

Measured cadence (PDS-D155, **job-level**):

- **33** guerrilla deploys / 24h
- median gap **22.6 min**
- **MINIMUM GAP 9 SECONDS**
- only **68.8%** of gaps exceed 10 minutes

**The ~58/day, ~28-minute-median figure is PDS-D78's SUPERSEDED run-level count.** Do not
plan against it: run-level counts overstate, because a skipped instance job still reports
the run as a success.

There is **no quiet-window mechanism anywhere in the repo**. Check 4's reading is a
snapshot, never a reservation. Re-read it immediately before you fire, and treat an open
PR on `^(api|internal|deploy|connectors)/` as a live hazard rather than a background fact —
at a 9-second minimum gap, "I checked a minute ago" is not a check.

If a deploy lands mid-climb, rung 0b reds (`:645-657`) and that is an **epoch event, not
an assertion to loosen** (PDS-D78): re-fetch, rebase the climb worktree, restart the run,
and say so.

### Every read in check 4 fails CLOSED

Both the `gh run list` reads and the `gh pr list` read capture their exit status **apart
from** their stdout, and any non-zero status makes check 4 **UNKNOWN**, which aggregates as
NO-GO. This is not defensive decoration. The PR read originally used `|| prs=""`, which made
a GitHub 503 and a genuinely empty PR list **read identically** — and an empty list flows
straight to the most reassuring verdict in the whole script:

```
GO  CHECK 4 — FIRE WINDOW
    pipeline quiet and no open PR touches a deploy path.
```

Reproduced during review with a `gh` shim that 503s only on `pr list`: the pre-fix script
printed exactly that GO **while #5097 and #2907 were open and both hit the instance
filter**. The check's single most consequential output was being generated by not being able
to see. It now prints UNKNOWN naming the exit status. **A gate that cannot see is UNKNOWN,
never OK (PDS-D98)** — and the GitHub API 503s often enough that this path is ordinary, not
exotic. Re-run; a retry usually clears it.

Two limits remain, and neither is closed by code:

- The PR read is capped at `--limit 100`. Above 100 open PRs the check silently sees a
  subset. The repo is nowhere near that today.
- Check 1 **never fetches**, by design — a preflight must not mutate refs. `origin/main` is
  therefore only as fresh as your last fetch. **Run `git fetch origin main` yourself before
  step 1**; the script cannot do it for you without becoming a writer.

---

## The sequence

1. **`scripts/pds-climb-preflight.sh`** from the climb worktree. Read all five verdicts.
2. Fix what blocks:
   - check 1 red → make a fresh `origin/main` worktree (`git worktree add`), never climb
     from the primary.
   - check 2 red → `export PDS_FULL_EXPORT_BUDGET=<the value check 2 printed>`.
   - check 3 WARN → delete the parked `.tar` and `.meta` (permitted). Lock held → wait.
   - check 4 red → wait for the in-flight deploy to land.
   - check 5 red or WARN → warm the tree you are about to arm from (PDS-D258):
     ```sh
     cd api && mix deps.get && MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile
     ```
     Fixing check 1 *creates* this red: a fresh `origin/main` worktree is cold by
     construction, and the two checks are satisfied together or not at all.
3. Re-run the preflight until it is GO (or GO with a warning you have consciously taken
   the named action on).
4. Set the two §0 env lines **in the shell you are about to arm from**:
   ```
   export PDS_CONTROL_PG=postgres   # gate at :1730; unset ⇒ `instrument control: NOT RUN` at :1743 and a still-PASSING rung (PDS-D79)
   unset PDS_AMMO_FILE              # ambient value short-circuits resolve_ammo() at :1659
   pg_isready                       # exporting PDS_CONTROL_PG makes rung 4 hard-fail on a dead server — prove it first
   ```
5. **Arm, once, unsplit** — then **end the turn** and let a later actor `collect` (§0):
   ```
   scripts/pds-crown-launch.sh arm --prewarm-now --max-draws 2160 --interval 10
   ```
   `--prewarm-now` is mandatory (PDS-D258): the compile happens in *this* shell, so a
   failure `die`s here instead of killing a detached child you will not read for hours.
   Arming will take as long as that compile, which is the point.

   `arm` prints the run tag, the child pid and the transcript path, and returns. The
   child runs the single `pds-pull-proof.sh --all` itself. Do not also fire `--all` by
   hand; that is a second, unbudgeted climb.

   **Where the bytes land.** The child writes
   `/tmp/pds-crown-launch/<run-tag>/transcript.log`, with its pid beside it in
   `child.pid` and the tag recorded in `/tmp/pds-crown-launch/last`. Bare
   `scripts/pds-crown-launch.sh collect` reads that `last` pointer, so a later actor
   needs no arguments; `collect --transcript P --pid-file F` addresses an older run
   explicitly. Copy the printed run tag into the fire record either way — `last` is
   overwritten by the next `arm`.
6. **Read the outcome with `collect`, never by eye.** It returns one of the six §0 states.
   A `CRASHED` transcript is sub-diagnosed by the stamps in its own bytes: a `FIRE` stamp
   means the harness ran and an export attempt **was** spent; a terminal `STAND-DOWN` or a
   `prewarm: FAILED` stamp means it was never invoked and re-arming is free. A `FIRE` stamp
   with **no** export in the harness output is PDS-D262's third outcome — the harness refused
   above the spend increment, so the attempt is free but the window is gone; read
   `/tmp/pds-full-export/attempts` before assuming either way. If it reds
   for real: re-run the preflight **before** the retry (check 3 will WARN — that is the
   trap doing its job), delete the parked tar, raise the budget to the value check 2
   prints, then **`arm` again** — never a hand-run `--all`, which is the dialect this
   sequence just retired. One run id per transcript; never stitch two.
7. If it cannot be fired honestly: **refuse in writing and name the rung.** A named
   refusal is a win (PDS-D212). Firing early burns the one knob the charter lets us turn.
