<!-- doc-tier: agent | canonical-for: pds-crown-fire-record-w18 | budget: 9000tok -->

# Wave 18 — the scratch target was booted, and the crown was re-fired

**Armed `2026-07-21T15:17:59Z`. `run_tag=c7528814`, `pid=83700`.** Wave 16 pulled the
trigger for real (run `1b515ee5`): it fired, took a genuine 1.4 GB full export, and came
back **5 PASS · 6 ABORT · 0 FAIL** — an honest partial, not a green. Its *sole* blocker was
`env:scratch-target-not-booted`: `cmd_arm` exports `BARKPARK_HOME=/tmp/pds-w14.$run_tag` but
neither boots the scratch target nor asserts `scratch.env` exists, so rungs 0c/1/2/5/6
aborted and burned attempt 3→4. This wave removes that one blocker — it **boots the scratch
target at the exact run_tag-derived home the launcher will use, asserts `scratch.env` before
arming (PDS-D266), and arms with the same `PDS_RUN_ID`** — then ends the turn.

**The arm did not measure anything.** Everything below is bookkeeping about a launch. The
climb's verdict lives in its transcript and is read by a LATER actor (the LEAD, via
`pds-w18-crown-collect-and-seal`) with `./scripts/pds-crown-launch.sh collect c7528814`.
Nothing in this record claims a rung passed.

---

## 1. The field set

| field | value |
|---|---|
| `run_id` | `pdsw18-crown` |
| `run_tag` | `c7528814` (`printf '%s' pdsw18-crown \| cksum \| awk '{printf "%x",$1}'`) |
| `pid` | `83700` |
| `transcript` | `/tmp/pds-crown-launch/c7528814/transcript.log` |
| `child` | `/tmp/pds-crown-launch/c7528814/child.sh` |
| `armed_at` | `2026-07-21T15:17:59Z` |
| arm wall-clock | `0s` (launcher's own `armed in    0s`) |
| scratch home | `/tmp/pds-w14.c7528814` — `scratch.env` PRESENT (766 B), `up --verify` → `---- verify: PASS` |
| scratch pointer | `/tmp/pds-scratch.pds-w14.c7528814.last` |
| `attempts_read` | `4` (host-authoritative, PDS-D156) |
| `budget_exported` | `PDS_FULL_EXPORT_BUDGET=6` (`4 + 2`, PDS-D224/D249; asserted `6 > 4`) |
| floor | **2200 MiB, UNMODIFIED.** `PDS_FULL_EXPORT_MIN_MEM_MB` and `PDS_LAUNCH_MEM_FLOOR_MIB` both left UNSET (PDS-D257/D267) |
| `max_draws` | `2160` |
| `interval_s` | `10` |
| resulting window | `2160 × 10 s = 6 h` → `15:17:59Z` → `21:17:59Z` |
| live guerrilla HEAD | `e16869ac06e2861f91b4359599d7f8311e035f6f` (fresh ssh this turn; deployed 2026-07-21T16:12:13Z) |
| parked `served_sha` | `8eeaf688fff03986da63e54bfc5cb323b53c165d` — **MISMATCH** → reuse dead, fresh export required (PDS-D265) |
| worktree sha | `8b32a1e67ca77365afbe577452ffeec5d9df0d4e` (== `origin/main`, `/Volumes/SATECHI/github/barkpark-w18-fire`, persistent — outlives the turn) |
| harness blob | `e219e97ccf7f33797c86a2b84d998d599b6bda31` — the frozen harness, UNEDITED (PDS-D261) |
| `pds_control_pg_exported` | **yes** — `PDS_CONTROL_PG=postgres`, in the same shell as the arm (PDS-D260) |
| `pds_ammo_file_state` | **UNSET** (explicitly `unset` in the arming shell) |
| `pds_launch_harness_state` | **UNSET** (explicitly `unset`; child.sh:7 default resolved to the real harness, PDS-D259) |
| `sampler_launched` | **no** — the wave-18 sequence did not require the passenger; per PDS-D263 it is never load-bearing for the crown |

Process identity — the single liveness check is `ps -p`, never `pgrep`:

```
$ ps -p 83700 -o pid=,ppid=,pgid=,stat=,comm=,lstart=
83700     1 83700 Ss   /bin/bash tir. 21 jul. 17.17.59 2026
```

`ppid=1` (reparented to init — the detached child outlives this turn), `pgid == pid` (its
own process group), `STAT=Ss` (session leader). `lstart` `17.17.59` local = `15:17:59Z`,
matching `armed_at` and `child.sh` line 4 (`armed_at=2026-07-21T15:17:59Z`).

---

## 2. The scratch target was booted FIRST, at the run_tag-derived home (PDS-D266)

This is what wave 16 did not do. Before arming, the scratch target was booted at exactly the
home `cmd_arm` will export, and `scratch.env` was asserted present:

```
$ BARKPARK_HOME=/tmp/pds-w14.c7528814 \
  PDS_SCRATCH_POINTER=/tmp/pds-scratch.pds-w14.c7528814.last \
  CC=/usr/bin/clang scripts/pds-scratch-target.sh up --verify   # → rc=0
...
---- 1. negative control — Barkpark.Media.upload_dir(), isolated vs NOT
  WITH  BARKPARK_MEDIA_DIR -> /private/tmp/pds-w14.c7528814/media
  env -u BARKPARK_MEDIA_DIR -> /Volumes/SATECHI/github/barkpark-w18-fire/api/uploads
  PASS  isolated upload_dir is the scratch path
  PASS  un-isolated upload_dir is the RUNNING TREE's api/uploads — the blast target is real
---- 2. the scratch server answers, and it is not on 4000
  PASS  GET http://localhost:37576/api/schemas -> 200
  PASS  scratch PORT=37576, PG=42428 — nothing of OURS listens on 4000
---- 3. admin token + blob push land in the scratch media dir
  PASS  blob push accepted with the minted admin token
  PASS  bytes landed at $BARKPARK_MEDIA_DIR/... ; no copy under api/uploads — checkout stayed clean
---- verify: PASS

$ test -f /tmp/pds-w14.c7528814/scratch.env && echo PRESENT
PRESENT   (/tmp/pds-w14.c7528814/scratch.env, 766 B)
```

The negative control fired — `env -u BARKPARK_MEDIA_DIR` resolves to the running tree's
`api/uploads`, so the isolation green above is not free. **The hand-assert `test -f
.../scratch.env` is the check that stops a repeat of wave 16:** `cmd_arm` asserts neither the
boot nor `scratch.env`, so without this the harness would abort on a missing scratch target
seconds into the climb, exactly as it did in wave 16. Had `scratch.env` been absent, the rule
(PDS-D266) is an HONEST ABORT — do not arm — and this record would carry that abort instead.
It was present; the arm proceeded.

The durable class-fix (teach `cmd_arm` to assert `scratch.env` at its derived home) is
BACKLOG (`pds-bl-launcher-assert-scratch-env`), NOT built this wave — a launcher edit makes
the fire round 2 and violates ZERO-NEW-SCRIPTS.

---

## 3. Reuse is dead — this wave pays one fresh full export (PDS-D265)

Wave 16 fired against `served_sha 8eeaf688…`, which WAS live at 09:55Z. Guerrilla has since
auto-deployed. Re-read in the same breath as the arm:

```
live guerrilla HEAD (fresh ssh) : e16869ac06e2861f91b4359599d7f8311e035f6f
parked full-default.tar.meta    : served_sha 8eeaf688fff03986da63e54bfc5cb323b53c165d
                                  → MISMATCH
/tmp/pds-full-export/attempts   : 4
```

The mismatch means `acquire_full_bundle`'s PDS-D20/D223 provenance gate REFUSES the parked
1.4 GB bundle, so rungs 3/4 take a **fresh export, spending one attempt**. `FULL_BUDGET`
defaults to 1 and `attempts` is already 4, so gate (c) `spent < budget` would fail unless the
budget is set: the launcher computes `PDS_FULL_EXPORT_BUDGET = spent + 2 = 6` at fire time
(confirmed in the arm banner). `6 > 4` was asserted. **The economics revert from wave 16:**
the expensive export is NOT pre-paid, so **HEADROOM is the gating risk this wave**, not the
attempt count. No cached sha was quoted; the HEAD above is a live read from this turn.

---

## 4. The floor stayed at 2200 — a decision, not an oversight (PDS-D257/D267)

`PDS_LAUNCH_MEM_FLOOR_MIB` and `PDS_FULL_EXPORT_MIN_MEM_MB` were **both left unset**. The
launcher's own 2200 default governs; the transcript carries **no asterisk**. The arm banner
confirms: `floor  PDS_FULL_EXPORT_MIN_MEM_MB left UNSET — harness floor 2200 stands
(PDS-D244)`, and `child.sh:11` reads `MEM_FLOOR_MIB=2200`.

Raising the floor above 2200 is refuted by measurement (D257: 0 clearances of 2400 across
>2000 samples in four regimes) and buys no real safety — the deployed **spill** engine's real
peak from wave 16's own fire was **~477 MiB** (parked `.meta`: `rss_peak_kb 488564 /
rss_baseline_kb 388044`, +98 MiB incremental). A 30-sample / 6-minute live sampling this turn
read min 2037.8 / mean 2145.0 / max 2238.7 MiB (3/30 clearing 2200), yet MemAvailable
recovered to ~2950 MiB within ~2 minutes — the box swings 900+ MiB in minutes, so a single
point sample in either direction is the D92/D112 trough trap.

**ACCEPTED RISK — the 35.43 MiB pre-spill shortfall.** D185 measured a 2235.43 MiB demand
against a 2200 MiB floor: a 35.43 MiB shortfall the floor does not cover. It is accepted
rather than hedged, because (a) 2235.43 MiB is the **retired in-memory** engine's demand, and
(b) the deployed **spill** engine's worst single COPY chunk is 19.71 MiB (D230/D217),
comfortably inside the gap. If this climb OOMs the source box, this paragraph is where the
reviewer should start.

---

## 5. The arm, and the three outcomes it can have (PDS-D262)

```
$ PDS_RUN_ID=pdsw18-crown scripts/pds-crown-launch.sh arm --prewarm-now --max-draws 2160 --interval 10
pre-warming synchronously (--prewarm-now); arming will take as long as this compile.
ARMED — the climb now outlives this turn.
  run_tag     c7528814
  pid         83700
  transcript  /tmp/pds-crown-launch/c7528814/transcript.log
  child       /tmp/pds-crown-launch/c7528814/child.sh
  budget      PDS_FULL_EXPORT_BUDGET=6 (attempts spent + 2)
  floor       PDS_FULL_EXPORT_MIN_MEM_MB left UNSET — harness floor 2200 stands (PDS-D244)
  poll        every 10s, up to 2160 draws, inside the child
  armed in    0s
```

The launcher is ONE-SHOT — on FIRE it runs `"$HARNESS" --all; rc=$?; sentinel; exit $rc`
with no re-arm, and no re-arm loop was added (PDS-D262). There are therefore **three** honest
outcomes of this arm, not two:

**(a) FIRE and climb.** A draw clears both legs (`mem_mib ≥ 2200` AND `bp-site-build-*`
listing empty), the harness runs one unsplit `--all`, and the transcript carries the ladder's
verdict.

**(b) Draws-exhausted STAND-DOWN.** All 2160 draws refuse and the climb never fires. This is
a first-class deliverable — a closed gate costs ZERO export attempts and re-arming is free.
Given the marginal headroom this turn (3/30 draws cleared 2200), a stand-down is a realistic
honest outcome.

**(c) FIRE, then an immediate `cond_b` refusal.** The harness re-reads `MemAvailable` once for
its own `cond_b` seconds after the launcher's draw admitted it, and consecutive draws swing by
up to ~100 MiB. A fire at ~2201 is roughly a coin flip to be refused on arrival — at zero
attempt cost, but with the window spent.

Only "never armed" is dishonest, and that one is off the table. **A named abort that never
opens a safe window is a WIN, not a failure** (PDS-D267): the crown then stays honestly at
9/12 with the scratch target proven bootable for the next attempt.

---

## 6. PDS-D259 — the harness is the REAL one

`PDS_LAUNCH_HARNESS` was `unset` in the arming shell. `pds-crown-launch.sh:109` resolves
`HARNESS="${PDS_LAUNCH_HARNESS:-$SCRIPT_DIR/pds-pull-proof.sh}"` from `$0` via `cd -P`, so the
default IS this worktree's real harness. Proven after the arm:

```
$ sed -n '7p' /tmp/pds-crown-launch/c7528814/child.sh
HARNESS=/Volumes/SATECHI/github/barkpark-w18-fire/scripts/pds-pull-proof.sh
```

`grep -F "$PWD/scripts/pds-pull-proof.sh"` matched. That one `sed` is what would have caught
wave 15's vacuous rc=0 inside its own turn. `child.sh:11` reads `MEM_FLOOR_MIB=2200`.

---

## 7. Pre-warm — paid in the arming worktree, off the clock (PDS-D258)

A fresh `git worktree add` has no `api/deps` and no `api/_build` (both gitignored); the
default pre-warm runs inside the detached child, fails on dependency errors, and burns the
window with zero draws. So it was paid up front in `/Volumes/SATECHI/github/barkpark-w18-fire/api`:

```
mix deps.get                                   # rc=0
CC=/usr/bin/clang MIX_ENV=dev  mix compile     # rc=0  (Generated barkpark app, 787 files)
CC=/usr/bin/clang MIX_ENV=prod mix compile     # rc=0  (Generated barkpark app)
```

The arm used `--prewarm-now`, which compiles synchronously in the arming shell and `die`s
rather than arming a cold tree. **Both compile legs required `CC=/usr/bin/clang`** — bare `cc`
resolves to the Claude CLI wrapper which rejects `-g` and kills `argon2_elixir`'s `make`
(the D258 recipe sets `CC` on the prod leg only; the dev leg needs it too — filed wave 16 as
`pds-w16-prewarm-cc-dev-leg`). No OOM.

---

## 8. The fence

No `.sh` file was modified. Every instrument used here (`pds-crown-launch.sh`,
`pds-pull-proof.sh`, `pds-scratch-target.sh`) was already merged, and the frozen harness blob
`e219e97ccf7f33797c86a2b84d998d599b6bda31` is UNTOUCHED (PDS-D261 — the climb runs against the
instrument the criteria cite; no mid-proof edit). The only file this slice adds is the one you
are reading. `tooling/grip/`, `cloud/`, and `api/**` source were not touched.

**The arm was executed exactly once and deliberately not repeated.** With run `c7528814`
live, a second arm is either refused by the stacking guard or — if the climb had finished —
fires a SECOND unsplit full export, and two of those against a memory-pressured box OOM the
live content API (PDS-D31 forbids it). The launcher is one-shot by design.

---

## 9. Reading the outcome — LEAD only, never this builder

```
./scripts/pds-crown-launch.sh collect c7528814
```

`collect` exits `0` on FINISHED / FINISHED-nosent, `2` on STILL-RUNNING, `1` otherwise. The
last line of a completed transcript is the `EXIT: <rc>` sentinel (PDS-D247). This builder does
NOT poll, wait, or collect — `pds-w18-crown-collect-and-seal` (LEAD-only) reads the transcript,
runs the PDS-D261 bundle cross-check before any stamp, and closes the merge-gated criterion.
This turn ends at the arm.
