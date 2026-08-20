<!-- doc-tier: human | canonical-for: pds-wave-21-fire-record | budget: 4000tok -->
# PDS Wave 21 — Crown Climb Fire Record (2026-07-21)

Diagnose-then-fire record for the wave-21 LAST crown attempt (task
`pds-w21-diagnose-and-fire`, epic `pds-w1-crown-proof`, wave paper
`pds-wave-21-2026-07-21`, charter decisions PDS-D279–D285). Wave 20 fired at the
derived **897** floor and got 6 PASS, but rung 1 (the import) FAILED with a
Postgres **25P02** aborted-transaction. One attempt remained (5/6). This slice
does the app-path belt-and-suspenders isolation (PART A, zero crown attempts),
sorts (a)/(b), and — on a confirmed (a) — arms the last attempt (PART B). The
arm slice ARMS and RETURNS — collection is the LEAD-only round-2 seal, never
this agent.

## PART A — MOVE-2 app-path isolation (zero crown attempts, D280)

**The sort: (a) DIRTY-SCRATCH — CONFIRMED end-to-end. import exit 0.**

The wave-21 verify already proved verdict (a) four ways (charter PDS-D279): the
rung-1 `25P02` masks an `ERROR 23505` on `content_edges_from_to_kind_uniq` — a
pre-existing wave-18 row (id `7bd32bce`) colliding with the bundle's same
`(from,to,kind)` tuple under a DIFFERENT id (`0003051d`); `merge_upsert`'s
`ON CONFLICT` arbiter is the PK only, so the secondary unique is never
reconciled. `merge_import` is NOT broken. PART A is the app-path
belt-and-suspenders: run the EXACT rung-1 import against a GUARANTEED-FRESH
scratch and confirm it exits 0.

### The isolated run

| field | value |
|---|---|
| scratch run id | `pdsw21-iso` (NEW — never the dirty `pdsw18-crown`/`c7528814`) |
| scratch home | `/private/tmp/pds-w21iso.a512` (`BARKPARK_HOME`, 28 bytes < 85) |
| scratch base | `http://localhost:20142` (PG port 25961) |
| boot | `scripts/pds-scratch-target.sh up --verify`, `CC=/usr/bin/clang`, `mix deps.get` first, COLD prod compile ~3min, output redirected to a file (never piped) |
| boot verify | `verify: PASS` — all isolation controls incl. the negative control (un-isolated upload_dir IS the running tree's api/uploads → the blast target is real), `GET /api/schemas → 200`, blob push landed in scratch media only |
| import cmd | `bp cloud workspace import default --file pull-default-production.tar --yes --merge --with-blobs --blobs <dir> -s http://localhost:20142 --token <scratch-admin>` (frozen wave-14 bp, reused per D280; 76MB artifact `/tmp/pds-proof-art.pds-w14.c7528814/`) |
| **import exit** | **`0`** |
| import receipt | `mode=merge`, `total_rows=15915`; `content_edges=5109` (the exact table that 23505-collided on the dirty wave-18 scratch), `documents=3602`, `search_intel_merge_patterns=3207`, `search_intel_crystals=2715`, `authoring_exemptions=1148`, `schema_definitions=36`, `media_files=34`, `task_edges=61`; provenance stamped (profile=dev, source_dataset=production) |
| blobs | `34 uploaded, 0 failed` |

### Decisive evidence

Importing the SAME frozen bundle that 25P02-aborted on the dirty wave-18 target,
into a fresh empty scratch, with the SAME `--merge --with-blobs` path and the
UNCHANGED import handler (f76367999..d633786 diff touches ZERO content
import/merge code — only `api/lib/barkpark/tasks/**`), exits **0** and lands all
5109 `content_edges` rows cleanly. There is no colliding pre-existing
`(from,to,kind)` tuple in a fresh scratch, so `merge_upsert`'s PK-only arbiter
never trips the secondary unique. This is verdict **(a)** proven at the
app-path: the wave-20 abort was DIRTY-SCRATCH, not a handler bug. No api
successor is filed; no NAMED REFUSAL; attempt 6 is spent on the fire.

## PART B — Fire the last attempt (armed on the confirmed (a))

The arm slice ARMS and RETURNS. Collection is the LEAD-only round-2 seal
(`pds-w21-crown-collect-and-seal`) — never this agent. Nobody polls from here.

### Fire-pin correction (charter D275/0b — LEAD-verified at L1)

The brief pinned the fire worktree at origin/main **f76367999**, but origin/main
had already ADVANCED to **d633786be** and guerrilla live HEAD is ALSO
**d633786be** (ssh-confirmed). The same-breath 0b is
`git merge-base --is-ancestor <guerrilla-HEAD> <fire-worktree-HEAD>`:
`--is-ancestor d633786 f76367999` = FALSE (the stale pin is BEHIND guerrilla →
forced HONEST ABORT), while `--is-ancestor d633786 d633786` = TRUE. The
f76367999..d633786 diff touches ONLY `api/config` + `api/lib/barkpark/tasks/**`
+ tasks_controller + internal/cli + tests — ZERO `scripts/pds-*`, ZERO content
import/merge handler — so the 897 launcher and `merge_import` are byte-identical
at both commits. Cutting at current origin/main **d633786be** satisfies D275/0b
without touching any crown code. The lead RE-VERIFIED all of this at L1 and
confirmed the cut-at-d633786 ruling and a TOTAL merge freeze before the arm.

### The armed run

| field | value |
|---|---|
| run_id | `pdsw21-crown` (DISTINCT new id per D282 — NOT the dirty `pdsw18-crown`/`c7528814`) |
| run_tag | `5abf6afd` (= `cksum(pdsw21-crown)`, re-derived and confirmed at arm) |
| child pid | `12535` (STAT `Ss`, ppid `1` — confirmed ONCE via `ps -p`, never `pgrep`) |
| armed_at | `2026-07-21T21:29:57Z` |
| transcript | `/tmp/pds-crown-launch/5abf6afd/transcript.log` (fresh — `grep -c '^RESULT:'` = 0 at arm) |
| child script | `/tmp/pds-crown-launch/5abf6afd/child.sh` |
| scratch home | `/tmp/pds-w14.5abf6afd` (`BARKPARK_HOME` the launcher derives from run_tag; macOS canonicalizes to `/private/tmp/pds-w14.5abf6afd`) |
| budget | `PDS_FULL_EXPORT_BUDGET=7` = attempts spent (`cat /tmp/pds-full-export/attempts` = 5) + 2, exported INLINE in the arm shell (D224/D285), never a literal |
| floor | `mem_floor_mib=897` AND `full_export_min_mem_mb=897` (PDS-D276/D277 DERIVED floor; the fossil 2200 no longer applies). `PDS_FULL_EXPORT_MIN_MEM_MB` / `PDS_LAUNCH_MEM_FLOOR_MIB` UNSET in the arm shell — the launcher's own 897 stands |
| poll | every 10 s, up to 2160 draws (≤ 6 h), inside the detached child |
| collect | `/Volumes/SATECHI/github/barkpark-w21-fire/scripts/pds-crown-launch.sh collect 5abf6afd` — LEAD only |

### Preconditions proven at arm time

- **Verdict (a) confirmed (PART A):** the exact rung-1 import into a fresh empty
  scratch exited 0. merge_import is sound; the fire is not chasing a handler bug.
- **Fresh persistent fire worktree (D270):** `/Volumes/SATECHI/github/barkpark-w21-fire`,
  detached at origin/main `d633786be6c3d98bbd881f8533a1318acb671b02` (HEAD verified),
  outside any builder tree, outlives the arming turn. `deps.get` paid off the
  clock; the crown-scratch boot warmed `_build/prod`+`_build/dev` so `--prewarm-now`
  compiled warm in ~1 s. Harness blob `e219e97ccf7f33797c86a2b84d998d599b6bda31`
  (frozen, CHECK 1 match).
- **GATE:** `scripts/pds-crown-launch.sh selftest` → **46 ok · 0 FAIL**, exit 0.
  `scripts/pds-climb-preflight.sh` with `PDS_FULL_EXPORT_BUDGET=7` →
  **GO WITH WARNINGS — 0 block, 4 clear, 1 warn**. The lone WARN is CHECK 4 (open
  api/ PRs #5533 #5532 #5531 #5530 #5529 #5525 #2907 that *would* move the box IF
  merged) — covered by the lead's TOTAL merge freeze (merger killed; nothing lands
  until the climb fires) and by the same-breath 0b machine backstop (the launcher
  cannot see a verbal freeze; 0b re-checks live guerrilla at arm). Without the
  budget the read-only preflight NO-GOs CHECK 2 by design (D224: budget is read at
  run time, never set in the preflight) — it flips to GO the instant the arm shell
  exports 7.
- **D282 empty crown target:** the SECOND fresh scratch (`pdsw21-crown`, home
  `/tmp/pds-w14.5abf6afd`, base `http://localhost:37781`, PG 30396) booted
  `up --verify` → `verify: PASS` and started EMPTY — `documents=0`,
  `content_edges=0` (psql + API count both 0) before the crown's rung 1 imports.
  Separate from the PART-A isolation scratch (torn down clean before this).
- **D269 archive:** the stale wave-20 run dir `/tmp/pds-crown-launch/c7528814`
  (child 25888 dead, terminal `EXIT: 1`) was moved aside to
  `…/c7528814.wave20-20260721T212704Z` before arming. My run tag `5abf6afd` is
  DISTINCT and its dir did not pre-exist, so there was no O_APPEND-onto-stale risk.
- **D275 same-breath 0b:** in the SAME bash invocation as the arm: `attempts`
  re-cat → `5`; guerrilla HEAD re-ssh'd → `d633786be…`; `git -C <fire>
  merge-base --is-ancestor d633786be… d633786be…` → exit 0 (`ANCESTOR-OK`). A
  `spent != 5` guard would have aborted the last-attempt premise; it held (5).
  Armed ONLY because both held.
- **Env hygiene (D270/D272/D274):** `PDS_LAUNCH_HARNESS`, `PDS_AMMO_FILE`,
  `PDS_FULL_EXPORT_MIN_MEM_MB`, `PDS_LAUNCH_MEM_FLOOR_MIB`, `PDS_FULL_EXPORT_DIR`
  all unset in the arm shell; `PDS_CONTROL_PG=postgres`, `PDS_RUN_ID=pdsw21-crown`,
  `CC=/usr/bin/clang` exported; launcher invoked BY PATH from the fire worktree.
- **D259/D272 harness proof:** `sed -n '7p' /tmp/pds-crown-launch/5abf6afd/child.sh`
  = `HARNESS=/Volumes/SATECHI/github/barkpark-w21-fire/scripts/pds-pull-proof.sh`
  — the by-path DEFAULT resolved to the fire worktree's own frozen harness.
  `PDS_LAUNCH_HARNESS` was never set.

## What happens next

The detached child polls up to 6 h for a high-regime memory draw and either
FIRES the fresh full export (attempt **6 of 6** — the parked bundle is stale,
served_sha `34b9b25d` ≠ guerrilla `d633786be`, so the provenance gate refuses
reuse) importing into the empty `pdsw21-crown` scratch, or STANDS DOWN honestly
(exit 5, zero attempts). Rung 1 is now proven clean end-to-end against a fresh
scratch (PART A), so a fire has no dirty-scratch collision waiting. A named
refusal is a WIN. The merge freeze must HOLD until the climb completes — rung 0b
re-checks live guerrilla at fire time (D275), so a mid-window merge fails the
climb honestly. Nobody polls from the arm side; the LEAD collects via
`scripts/pds-crown-launch.sh collect 5abf6afd` and seals per the round-2 task.

