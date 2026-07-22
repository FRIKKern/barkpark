<!-- doc-tier: human | canonical-for: pds-wave-19-fire-record | budget: 4000tok -->
# PDS Wave 19 — Crown Climb Fire Record (2026-07-21)

Arm record for the wave-19 detached crown climb (task `pds-w19-crown-fire`,
epic `pds-w1-crown-proof`, wave paper `pds-wave-19-2026-07-21`, charter
decisions PDS-D268–D275). The arm slice ARMS and RETURNS — collection is the
LEAD-only round-2 seal (`pds-w19-crown-collect-and-seal`), never this agent.

## The armed run

| field | value |
|---|---|
| run_id | `pdsw18-crown` (reused by design — D269 archives the state dir, not the id) |
| run_tag | `c7528814` (= `cksum(pdsw18-crown)`, re-derived and confirmed at arm) |
| child pid | `3513` (STAT `Ss`, ppid `1` — confirmed ONCE via `ps -p`, never `pgrep`) |
| armed_at | `2026-07-21T16:56:33Z` |
| transcript | `/tmp/pds-crown-launch/c7528814/transcript.log` (fresh — `grep -c '^RESULT:'` = 0 at arm) |
| child script | `/tmp/pds-crown-launch/c7528814/child.sh` |
| scratch home | `/tmp/pds-w14.c7528814` (`BARKPARK_HOME`, derived from run_tag inside `fire_detached`) |
| budget | `PDS_FULL_EXPORT_BUDGET=6` = attempts spent (4) + 2 — computed by `fire_detached` (D224/D274), never a literal |
| floor | `PDS_FULL_EXPORT_MIN_MEM_MB` UNSET — harness floor **2200 MiB** stands (D244); `PDS_LAUNCH_MEM_FLOOR_MIB` UNSET |
| poll | every 10 s, up to 2160 draws (≤ 6 h), inside the detached child |
| collect | `/Volumes/SATECHI/github/barkpark-w19-fire/scripts/pds-crown-launch.sh collect c7528814` — LEAD only |

## Preconditions proven at arm time

- **Scratch alive (no reboot):** `curl -s -o /dev/null -w '%{http_code}'
  http://127.0.0.1:37576/api/schemas` → `200`, re-confirmed inside the arming
  shell; `/tmp/pds-w14.c7528814/scratch.env` present. No `up` run (D268: reuse
  the live c7528814 target).
- **D269 archive:** the stale wave-18 run dir (554-line transcript, terminal
  `RESULT: FAIL`, child 83700 dead) was moved aside BEFORE arming:
  `/tmp/pds-crown-launch/c7528814` → `/tmp/pds-crown-launch/c7528814.wave18-20260721T165336Z`.
  Archive-in-place, no `PDS_LAUNCH_STATE_DIR` override — the anti-stack guard
  stayed functional. `BARKPARK_HOME` unaffected (derives from run_tag).
- **Fresh persistent fire worktree (D270):** `/Volumes/SATECHI/github/barkpark-w19-fire`,
  detached at origin/main `ab451a71e3e02c64f56a79c50310e8882d214e90` — outside
  any builder tree, outlives the arming turn. `deps.get` + `MIX_ENV=dev mix compile`
  + `CC=/usr/bin/clang MIX_ENV=prod mix compile` paid off the clock before the
  arm (runbook recipe); `--prewarm-now` then compiled warm in ~0 s.
- **D275 same-breath 0b:** in the SAME bash invocation as the arm:
  `attempts` re-cat → `4`; guerrilla HEAD re-ssh'd →
  `34b9b25d338b629efc6806cc2e9dbf633c5ba3e4`;
  `git -C /Volumes/SATECHI/github/barkpark-w19-fire merge-base --is-ancestor
  34b9b25d… ab451a71e…` → exit 0 (`ANCESTOR-OK`). Armed only because it held.
- **Env hygiene (D270/D272/D274):** `PDS_LAUNCH_HARNESS`, `PDS_AMMO_FILE`,
  `PDS_FULL_EXPORT_MIN_MEM_MB`, `PDS_LAUNCH_MEM_FLOOR_MIB`, `PDS_FULL_EXPORT_DIR`
  all unset in the arming shell; `PDS_CONTROL_PG=postgres` and
  `PDS_RUN_ID=pdsw18-crown` exported; launcher invoked BY PATH from the fresh
  worktree so `$0` → `REPO_ROOT` → the fresh HEAD (rung 0b's `worktree_sha`).
- **D259/D272 harness proof:** `sed -n '7p' /tmp/pds-crown-launch/c7528814/child.sh`
  = `HARNESS=/Volumes/SATECHI/github/barkpark-w19-fire/scripts/pds-pull-proof.sh`
  — the by-path DEFAULT resolved to the fresh worktree's own frozen harness
  (blob `e219e97ccf7f33797c86a2b84d998d599b6bda31`). `PDS_LAUNCH_HARNESS` was
  never set.

## What happens next

The detached child polls up to 6 h for a high-regime memory draw and either
FIRES (fresh full export = attempt **5 of 6**; the parked bundle is stale —
served_sha `8eeaf688` ≠ guerrilla `34b9b25d` — so the provenance gate refuses
reuse) or STANDS DOWN honestly (exit 5, zero attempts). A named refusal is a
WIN. The merge freeze must HOLD until the climb completes — rung 0b re-checks
live guerrilla at fire time (D275), so a mid-window merge fails the climb
honestly. Nobody polls from the arm side; the LEAD collects via the six named
states and seals per the round-2 task.
