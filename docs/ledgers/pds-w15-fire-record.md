<!-- doc-tier: agent | canonical-for: pds-crown-fire-record | budget: 12000tok -->

# The shot — the crown climb was armed, and it fired

**Armed `2026-07-21T09:55:12Z`. `run_tag=1b515ee5`, `pid=60879`.** Wave 14 built the
detached launcher, wave 15 proved its plumbing against a probe harness and never pointed
it at the real one, and `pds-w14-crown-fire` sat filed and open through both. This file is
the trigger being pulled: one arm, at the untouched 2200 MiB floor, against the frozen
harness, from a fresh `origin/main` worktree — and then the turn ended.

**The arm did not measure anything.** Everything below is bookkeeping about a launch. The
climb's own verdict lives in its transcript and is read by a LATER actor with
`./scripts/pds-crown-launch.sh collect 1b515ee5`. Nothing in this record claims a rung
passed.

---

## 1. The PDS-D254 field set

| field | value |
|---|---|
| `run_tag` | `1b515ee5` |
| `run_id` | `20260721T095512Z-60807` |
| `pid` | `60879` |
| `transcript` | `/tmp/pds-crown-launch/1b515ee5/transcript.log` |
| `child` | `/tmp/pds-crown-launch/1b515ee5/child.sh` |
| `armed_at` | `2026-07-21T09:55:12Z` |
| arm wall-clock | `0s` (launcher's own `armed in    0s`; outer measure `arm_wall_clock_s=0`) |
| `attempts_read` | `3` |
| `budget_exported` | `PDS_FULL_EXPORT_BUDGET=5` (`3 + 2`, PDS-D224) |
| floor | **2200 MiB, UNMODIFIED.** `PDS_FULL_EXPORT_MIN_MEM_MB` and `PDS_LAUNCH_MEM_FLOOR_MIB` both left UNSET |
| `max_draws` | `2160` |
| `interval_s` | `10` |
| resulting wall clock | `2160 × 10 s = 21600 s = 6 h` → window `09:55:12Z` → `15:55:12Z` |
| `deployed_sha` | `8eeaf688fff03986da63e54bfc5cb323b53c165d` |
| ancestor proof | `git merge-base --is-ancestor 87c9995f6 8eeaf688f` → `descendant: OK` |
| worktree sha | `8eeaf688fff03986da63e54bfc5cb323b53c165d` (fresh worktree at `origin/main`, `/private/tmp/pdsw16-fire`) |
| harness blob | `e219e97ccf7f33797c86a2b84d998d599b6bda31` — `git rev-parse origin/main:scripts/pds-pull-proof.sh`, never `shasum` (PDS-D154) |
| launcher blob | `931fbd2067ab48f4ddb3f1a8a97ec3f0e5e8a719` |
| `pds_control_pg_exported` | **yes** — `PDS_CONTROL_PG=postgres`, in the same shell as the arm |
| `pds_ammo_file_state` | **UNSET** (explicitly `unset` in the arming shell) |
| `sampler_launched` | **yes** — pid `62913`, `--window 21600`, out `/tmp/pds-idle-sampler-w16.out`, log `/tmp/pds-idle-sampler-w16.log`, launched AFTER the arm returned |
| process fingerprint | `ps -p 60879 -o comm=,lstart=` → `/bin/bash tir. 21 jul. 11.55.12 2026` |

Process identity, the single `ps -p` (never `pgrep` — `pgrep` printed two bare PIDs this
session that `ps -p` proved were not live):

```
$ ps -p 60879 -o pid=,ppid=,pgid=,stat=,comm=,lstart=
60879     1 60879 Ss   /bin/bash tir. 21 jul. 11.55.12 2026
```

`ppid=1` (reparented to init), `pgid == pid` (its own process group), `STAT=Ss` (session
leader). The child agrees from the inside: `child up — pid=60879 pgid=60879 sid_leader=Ss`.

Sampler, same detach form (`python3` `os.fork()` + `os.setsid()` + `os.execvp()` —
PDS-D243; `& disown` is the form that dies to `kill -TERM -<pgid>`):

```
$ ps -p 62913 -o pid=,ppid=,pgid=,stat=,comm=,lstart=
62913     1 62913 Rs   /usr/bin/env tir. 21 jul. 11.55.44 2026
```

It was launched **32 seconds after** the arm returned. It gated nothing and delayed
nothing; it takes no mutex, issues no HTTP, and spends no export attempt (PDS-D237).

---

## 2. The five preconditions, re-read live in the same breath as the arm

No literal was carried from the brief. All of this ran in ONE shell with no tool-call
boundary anywhere inside it, because a child inherits its environment at fork/exec only
(PDS-D249) — split across two calls and the child silently reads the default budget of 1.

```
traps_set=0
== P1 cond_d — deploy.yml in_progress on main ==
cond_d_rc=0 cond_d_in_progress=[] (SAMPLE, not a reservation)
== P2 export lock ==
ABSENT
== P3 attempts ==
attempts_read=3
== P4 deployed sha ancestry ==
deployed_sha=8eeaf688fff03986da63e54bfc5cb323b53c165d
descendant: OK
== P5 floor var must be unset ==
PDS_FULL_EXPORT_MIN_MEM_MB_env_count=0
```

**cond_d is a SAMPLE, not a reservation.** It says no `deploy.yml` run was `in_progress`
on `main` at the instant it was read. It cannot reserve the next six hours, and it is
blind to a run queued one second later.

**cond_d was NO-GO when this slice started, and the arm was HELD.** `deploy.yml` run
`29819328000` was created at `09:42:16Z` and its `instance` job was still `in_progress` at
`09:54:29Z`. Arming into it would have moved guerrilla's sha under the climb and redded
rung 0b mid-run (PDS-D78), so the arm waited. The run landed and cond_d read empty at
`09:54:45Z`; the arm went at `09:55:12Z`. **See §6 — that wait has a consequence a reviewer
must weigh.**

The export lock was read with `[ -d ]` only. It was never created, never removed, never
touched. The attempts counter was read with `tr -dc '0-9'` and never written.

---

## 3. The control leg — rung 4's scanner was shown able to fire

`PDS_CONTROL_PG=postgres` was exported in the arming shell, and the fork is transparent
(`os.execvp` inherits `environ` with no allowlist, PDS-D260), so it reaches rung 4. Without
it `pds-pull-proof.sh` prints `instrument control: NOT RUN` at INFO level with no return
value and the rung still reaches a terminal PASS — a clean scan whose scanner was never
shown able to fire.

Rehearsed to completion BEFORE arming, in the same shell:

```
$ pg_isready
/tmp:5432 - accepting connections
pg_isready_rc=0

$ ./scripts/pds-secret-scan.sh control --pg postgres
control_rc=0
control fires on the bundle: exit 1 with the hit named in tables/webhooks.copy
control fires on the target DB: exit 1 with the hit named per table
deny-shaped bundle is CLEAN: exit 0 against the same ammo
CONTROL PASSED — the instrument fires on real secret bytes and comes back
clean when the denied members are absent.
```

Seeded locally into throwaway database `pds_secret_scan_ctl_60531`, created and dropped by
that run. **No live guerrilla export was spent** (PDS-D31).

`PDS_AMMO_FILE` was `unset`. The dangerous case is not an empty ammo file — that dies
loudly at `pds-secret-scan.sh:265` — but a STALE one whose values have since been rotated:
dev CLEAN, target CLEAN, full FIRES, three greens all measuring a retired secret (the
PDS-D102 shape).

---

## 4. The floor stayed at 2200, and that was a decision, not an oversight

`PDS_LAUNCH_MEM_FLOOR_MIB` was **not set**. An earlier plan wanted 2400 to cover D185's
2235.43 MiB demand figure. It is refuted by measurement: 2400 cleared **0 of 780** gapless
1 Hz samples (max 2276.42), **0 of 31** paired live draws (max 2267.71), **0 of 42** in
D245 (max 2395), **0 of 1200** in D250 (max 1948.13) — zero clearances across more than
2000 samples in four independent regimes. On the D246 line a 2400 floor also needs beam RSS
≤ 486 MiB, which is reachable only in the post-restart transient D93 forbids.

`PDS_FULL_EXPORT_MIN_MEM_MB` was likewise left unset (D232/D244/D250b — the floor never
moves; the derivation refused itself with a NEGATIVE −7.55 MiB delta).

The child confirms both from inside the fork:

```
[2026-07-21T09:55:12Z] budget PDS_FULL_EXPORT_BUDGET=5
[2026-07-21T09:55:12Z] floor  PDS_FULL_EXPORT_MIN_MEM_MB=<unset, as required by PDS-D244 — the harness floor of 2200 stands>
```

and `child.sh:11` reads `MEM_FLOOR_MIB=2200`.

**ACCEPTED RISK — the 35.43 MiB pre-spill shortfall.** D185 measured a 2235.43 MiB demand
against a 2200 MiB floor: a 35.43 MiB shortfall the floor does not cover. It is accepted
rather than hedged, because (a) 2235.43 MiB is the **retired in-memory** engine's demand,
and (b) the deployed **spill** engine's worst single COPY chunk is 19.71 MiB (D230/D217),
comfortably inside the gap. Hedging it with a 2400 floor would trade a bounded, quantified
risk for a gate that has never once opened. If this climb OOMs the source box, this
paragraph is where the reviewer should start.

---

## 5. The arm, and the three outcomes it can have

```
$ ./scripts/pds-crown-launch.sh arm --prewarm-now --max-draws 2160 --interval 10
pre-warming synchronously (--prewarm-now); arming will take as long as this compile.
ARMED — the climb now outlives this turn.
  run_tag     1b515ee5
  pid         60879
  transcript  /tmp/pds-crown-launch/1b515ee5/transcript.log
  child       /tmp/pds-crown-launch/1b515ee5/child.sh
  budget      PDS_FULL_EXPORT_BUDGET=5 (attempts spent + 2)
  floor       PDS_FULL_EXPORT_MIN_MEM_MB left UNSET — harness floor 2200 stands (PDS-D244)
  poll        every 10s, up to 2160 draws, inside the child
  armed in    0s
```

`attempts` read `3` before the arm and `3` immediately after it. **The arm itself spent
nothing.**

The launcher is ONE-SHOT — on FIRE it runs `"$HARNESS" --all; rc=$?; sentinel; exit $rc`
with no re-arm, and no re-arm loop was added (PDS-D262). There are therefore **three**
honest outcomes of this arm, not two:

**(a) FIRE and climb.** A draw clears both legs, the harness runs one unsplit `--all`, and
the transcript carries the ladder's verdict.

**(b) Draws-exhausted STAND-DOWN.** All 2160 draws refuse and the climb never fires. **This
is a first-class deliverable and it is not this slice failing.** A closed gate costs ZERO
export attempts — the failed-precondition `return 1` sits ABOVE the spend increment — the
2160 refusals ARE the dataset the next floor derivation needs, and re-arming is free. A
gapless 1200-sample 1 Hz window on 2026-07-21 yielded 862 build-idle draws and zero
clearing 2200 (min/mean/max 1343.77 / 1865.40 / 1948.13 MiB), and the live read at 09:29Z
was 2007.7 MiB — below the floor. A stand-down was the honestly expected outcome here.

**(c) FIRE, then an immediate `cond_b` refusal.** The harness re-reads `MemAvailable` once
for its own `cond_b` seconds after the launcher's draw admitted it, and consecutive draws
swing by up to ~100 MiB. A fire at ~2201 is roughly a coin flip to be refused on arrival —
at zero attempt cost, but with the whole window spent.

Only "never armed" is dishonest. That one is now off the table.

**What actually happened at arm time: outcome (a) was entered on draw 1 of 2160.**

```
DRAW	1	2026-07-21T09:55:13Z	mem_mib=2578	floor=2200	builds=<empty>	recorded_rss_kb=352840	recorded_slot_uptime=02:03	verdict=FIRE
[2026-07-21T09:55:13Z] FIRE — draw 1 of 2160 qualified.
[2026-07-21T09:55:13Z]   gated on: mem_mib=2578 >= 2200 AND bp-site-build-* listing EMPTY
[2026-07-21T09:55:13Z]   recorded, NOT gated (PDS-D246): beam rss_kb=352840 slot_uptime=02:03
[2026-07-21T09:55:13Z]   firing ONE unsplit --all (W6-C: --only across rungs 2-6 is forbidden)
```

That is the **launcher's** gate opening. Whether the **harness's** own `cond_b` re-read
then admitted the export — outcome (a) proper — or refused it on arrival — outcome (c) —
is decided seconds later inside the harness.

**It was admitted.** The mandated post-arm `attempts` re-read shows the counter has moved:

```
attempts at 09:55:12Z, immediately before the arm   3
attempts at 09:55:12Z, immediately after  the arm   3     <- the arm itself spent NOTHING
attempts at 10:01Z,    the gate's re-read           4     <- the CLIMB spent one
```

The increment from 3 to 4 belongs to the **climb**, not to the arm, and it is the proof
that `cond_b` did not refuse on arrival: the harness only increments past its
failed-precondition `return 1`. So this run is outcome **(a)** — fired and climbing — with
one attempt of the budget of 5 consumed and one spare left. It must not be read as the
arm spending anything; §5's before/after pair is the control for exactly that misreading.

This is the gate's mandated counter read, not a poll of the climb. No verdict is claimed
here; `collect 1b515ee5` remains the verb that reads the ladder's result.

---

## 6. The finding this arm produced: cond_d discipline selects for the warmth D93 forbids

The draw that fired recorded `recorded_slot_uptime=02:03` and `recorded_rss_kb=352840`
(344.6 MiB). That is a slot **two minutes past restart** — the post-restart transient, the
regime D93/D190/D191 rule out as unrepresentative.

This was not bad luck; it is **structural**, and holding the arm correctly is what caused
it:

1. PDS-D78 says do not arm into an in-flight deploy, so this slice waited for
   `deploy.yml 29819328000` to land.
2. A deploy lands by restarting the BEAM. The instant after it lands, beam RSS is at its
   minimum and `MemAvailable` is at its maximum.
3. Idle `MemAvailable` is a near-deterministic function of beam RSS (r = −0.986, D246).
4. So the *first* draw taken after a deploy clears is the *most likely draw in the whole
   six-hour window to clear a floor that nothing else clears* — 2578 MiB here against a
   1200-sample steady-state max of 1948.13 MiB.

Obeying cond_d therefore **aims the climb at exactly the transient the warmth decisions
distrust.** The two-leg predicate does not gate on warmth deliberately (PDS-D246: D193's
four-leg predicate went 0/61), and it recorded both values precisely so a reviewer could
rule on this. This is that ruling being asked for, not being pre-empted.

A reviewer weighing this transcript should read `slot_uptime=02:03` as a first-class
caveat: this climb is a measurement of the source box **two minutes after a restart**, not
of the box in steady state. Filed as `pds-w16-cond-d-warmth-coupling`.

**Second finding, filed as `pds-w16-prewarm-cc-dev-leg`.** PDS-D258's prescribed pre-warm
recipe is incomplete. `MIX_ENV=dev mix compile` without `CC=/usr/bin/clang` dies on
`argon2_elixir` — bare `cc` resolves to the Claude CLI wrapper, which rejects `-g`:

```
cc -g -O3 -pthread ... -o .../argon2_nif.so
error: unknown option '-g'
make: *** [.../argon2_nif.so] Error 1
** (Mix) Could not compile with "make" (exit status: 2).
```

The brief sets `CC` on the prod leg only. Both legs need it. This cost one failed compile
and was recovered by re-running both legs with `CC=/usr/bin/clang`.

---

## 7. Pre-warm — paid in the arming worktree, never deferred into the window

PDS-D258, measured twice on 2026-07-21: a fresh `git worktree add` has no `api/deps` and no
`api/_build` (both gitignored). The DEFAULT pre-warm runs inside the detached child, fails
on `** (Mix) Can't continue due to errors on dependencies`, prints
`prewarm: FAILED rc=1 — NOT firing`, and the child exits with **zero draws** — while `arm`
itself has already returned 0 and printed the full "ARMED" banner. The operator ends the
turn believing they fired.

So it was paid up front in `/private/tmp/pdsw16-fire/api`:

```
mix deps.get
CC=/usr/bin/clang MIX_ENV=dev  mix compile
CC=/usr/bin/clang MIX_ENV=prod mix compile
...
Generated barkpark app
PREWARM_PAID_OK
```

and the arm used `--prewarm-now`, which compiles synchronously in the arming shell and
`die`s rather than arming a cold tree. The child confirms it was not deferred:

```
[2026-07-21T09:55:12Z] prewarm: already paid synchronously in the arming shell (--prewarm-now)
```

---

## 8. PDS-D259 — the harness is the REAL one

Wave 15's two children carried `HARNESS=/tmp/pds-probe-harness.sh`, a leaked interactive
export from a since-deleted rehearsal tree, and returned a vacuous rc=0. It was never a
script bug: `pds-crown-launch.sh:109` is
`HARNESS="${PDS_LAUNCH_HARNESS:-$SCRIPT_DIR/pds-pull-proof.sh}"` with `SCRIPT_DIR` resolved
from `$0` via `cd -P`, so from any fresh worktree the default IS the real harness.

`PDS_LAUNCH_HARNESS` was `unset` here, `traps_set=0` was asserted before arming, and the
result was proved after:

```
$ sed -n '7p;11p' /tmp/pds-crown-launch/1b515ee5/child.sh
HARNESS=/private/tmp/pdsw16-fire/scripts/pds-pull-proof.sh
MEM_FLOOR_MIB=2200
```

Nothing under `/tmp/pds-probe-*`. That one `sed` is what would have caught wave 15 inside
its own turn.

---

## 9. Environment — an allowlist, never a dump

No `env` dump appears in this file. These are the only variables this arm set or cleared:

**Exported by the arming shell:** `PDS_CONTROL_PG=postgres`,
`PDS_FULL_EXPORT_BUDGET=5`.

**Exported by the launcher into the child** (`fire_detached`): `PDS_FULL_EXPORT_BUDGET`,
`PDS_RUN_ID=1b515ee5`, `BARKPARK_HOME=/tmp/pds-w14.1b515ee5`,
`PDS_SCRATCH_POINTER=/tmp/pds-scratch.pds-w14.1b515ee5.last`,
`PDS_PROOF_ARTIFACTS=/tmp/pds-proof-art.pds-w14.1b515ee5`.

**Explicitly unset before arming:** `PDS_LAUNCH_HARNESS`, `PDS_AMMO_FILE`,
`PDS_FULL_EXPORT_MIN_MEM_MB`, `PDS_LAUNCH_MEM_FLOOR_MIB`, `PDS_LAUNCH_STATE_DIR`,
`PDS_FULL_EXPORT_DIR`.

No credential value and no credential variable name is recorded anywhere in this file.

---

## 10. The fence

No `.sh` file was modified. `git diff --stat` in the arming worktree was empty at arm time
and `git status --porcelain` printed nothing. No new script was written — every instrument
used here (`pds-crown-launch.sh`, `pds-pull-proof.sh`, `pds-secret-scan.sh`,
`pds-idle-sampler.sh`) was already merged. The only file this slice adds to the repository
is the one you are reading.

**The arm was executed exactly once and deliberately not repeated.** This slice's gate
names `arm --prewarm-now --max-draws 2160 --interval 10` followed by a set of read-only
checks. The arm leg ran once, at `09:55:12Z`, and its read-only tail is quoted throughout
this file. It was not re-run to "re-prove" the gate: with run `1b515ee5` live, a second arm
is either refused by the stacking guard (the intended outcome) or — if the climb had
finished in the interval — fires a SECOND unsplit full export, and two of those against a
3.8 GB box OOM the live content API, which is the one thing PDS-D31 forbids outright. The
launcher is one-shot by design (PDS-D262) and no re-arm loop was added.

**Housekeeping observed, not disturbed.** `/tmp/pds-crown-launch/` already held rehearsal
run dirs (`4bc04e42`, `c3a70c28`, `b1249352`, `c81aa082`, `a4f29e8d`, `14a49522`,
`c05d3f00`). The stacking guard checked the previous `last` pointer (`c05d3f00`, pid
`28087`), `ps -p` proved it dead, and the arm proceeded without `--force`. `attempts` was
`3` throughout — none of those rehearsals spent anything.

---

## 11. Reading the outcome

```
./scripts/pds-crown-launch.sh collect 1b515ee5
```

`collect` exits `0` on FINISHED or FINISHED-nosent, `2` on STILL-RUNNING, `1` otherwise.
The last line of a completed transcript is always the `EXIT: <rc>` sentinel (PDS-D247); a
transcript without it was either killed or is still running.

The paired idle control lands at `/tmp/pds-idle-sampler-w16.out` (log
`/tmp/pds-idle-sampler-w16.log`) when its 21600 s window closes at ≈`15:55:44Z`. Per
PDS-D114 a 1 Hz sampler reports a LOWER bound — a transient between ticks is invisible —
which for a control is the conservative direction.
