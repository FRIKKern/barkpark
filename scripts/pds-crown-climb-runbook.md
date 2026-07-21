# PDS Crown Climb — Runbook

The crown climb is ONE unsplit `scripts/pds-pull-proof.sh --all` under a single run id.
This file is the operator's card for it: the rulings that govern the fire, the traps that
have actually bitten, and the exact sequence.

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

---

## The sequence

1. **`scripts/pds-climb-preflight.sh`** from the climb worktree. Read all four verdicts.
2. Fix what blocks:
   - check 1 red → make a fresh `origin/main` worktree (`git worktree add`), never climb
     from the primary.
   - check 2 red → `export PDS_FULL_EXPORT_BUDGET=<the value check 2 printed>`.
   - check 3 WARN → delete the parked `.tar` and `.meta` (permitted). Lock held → wait.
   - check 4 red → wait for the in-flight deploy to land.
3. Re-run the preflight until it is GO (or GO with a warning you have consciously taken
   the named action on).
4. `export PDS_CONTROL_PG=…` — step 4 gates its control call on this being set
   (`:1648`); without it the step prints `instrument control: NOT RUN` and **still
   passes** (PDS-D79). One forgotten env var silently costs rung 4 its closing leg.
5. **Fire, once, unsplit:**
   ```
   scripts/pds-pull-proof.sh --all 2>&1 | tee scripts/pds-pull-proof.crown-transcript-w12.txt
   ```
6. If it reds: re-run the preflight **before** the retry (check 3 will WARN — that is the
   trap doing its job), delete the parked tar, raise the budget to the value check 2
   prints, then fire `--all` again. One run id per transcript; never stitch two.
7. If it cannot be fired honestly: **refuse in writing and name the rung.** A named
   refusal is a win (PDS-D212). Firing early burns the one knob the charter lets us turn.
