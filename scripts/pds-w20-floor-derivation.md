<!-- doc-tier: agent | canonical-for: pds-w20-floor-derivation | budget: 6000tok -->

# PDS-D276/D277 — the crown floor, derived against the DEPLOYED engine

**What this is.** The arithmetic behind moving the crown-climb launcher's memory floor
from the fossil **2200 MiB** to the derived **897 MiB**. The 2200 was calibrated against the
retired in-RAM export engine (whose canonical demand delta was 2235.43 MiB); the engine
actually deployed on guerrilla is the streaming spill engine, and its measured demand is an
order of magnitude smaller. This record fixes the floor to the deployed engine so the crown
climb can fire in the box's real memory regime — MemAvailable on guerrilla ranged
1796–2012 MiB across 618 build-idle draws over ~1h45m and cleared 2200 **zero** times, so
under the fossil floor the child stands down forever.

**What this is NOT.** No engine code changes. The frozen harness blob
(`scripts/pds-pull-proof.sh`, `e219e97c`) is untouched. Only the non-frozen wave-14 launcher
`scripts/pds-crown-launch.sh` is armed at the new floor. No export was executed to write this
document — the demand figure is read from the wave-16 full export the frozen harness already
recorded (run `1b515ee5`), not re-measured here.

---

## 1. The number (PDS-D276, verbatim)

> The demand figure is 98.16 MiB — the BEAM RSS peak-minus-baseline DELTA,
> (488564 kB − 388044 kB)/1024, measured by the frozen harness's rung-3 1 Hz ps sampler
> during the wave-16 full export (run 1b515ee5), the same peak-minus-baseline delta class as
> the retired in-memory engine's canonical 2235.43 MiB, (2483304−194228)/1024. It is NOT the
> 477.11 MiB absolute RSS peak (488564/1024), which includes the 388044 kB resident baseline
> that MemAvailable already excludes and would double-count per PDS-D222(i); NOT the 19.71 MiB
> wire-byte COPY-chunk figure PDS-D232 rejects as unit-mixed; and NOT the ~647 MiB
> MemAvailable drawdown, which is a margin-class quantity already absorbed by the 798.81 MiB
> margin. FLOOR = 98.16 + 798.81 = 896.97, rounded up to 897 MiB.

### Why each rejected quantity is wrong, in one line each

| Quantity | Value | Why it is NOT the demand |
|---|---|---|
| Peak-minus-baseline **delta** ✅ | **98.16 MiB** | The demand a `cond_b`-style floor must cover; same unit class as the retired engine's 2235.43 delta. |
| Absolute RSS peak | 477.11 MiB | Includes the 388044 kB baseline **already resident** — MemAvailable excludes it, so adding it back double-counts (PDS-D222(i)). |
| Wire-byte COPY-chunk | 19.71 MiB | A wire-transfer figure from a different census, unit-mixed with an RSS floor (PDS-D232). |
| MemAvailable drawdown | ~647 MiB | A margin-class quantity — the walk the margin already covers, not the demand. |

The margin is **798.81 MiB** — the maximum observed drawdown `max_t ( v_t − min_{u≥t} v_u )`
across D222's three windows (570.44 / 756.35 / **798.81**), MAX not mean (PDS-D222(ii)).

**FLOOR = demand delta + margin = 98.16 + 798.81 = 896.97 → 897 MiB.**

---

## 2. The honesty caveat (do not launder it away)

The 388044 kB baseline is the frozen harness's **own** strictly-pre-window rung-3 baseline —
a *within-process* peak-minus-baseline, sampled by the same 1 Hz `ps` run that later records
the peak. It is **NOT** the formal PDS-D104 **paired idle control** that PDS-D211 names as the
gold standard for a floor amendment ("a measurement against the deployed engine with a
PDS-D104 paired idle control, in kB/1024"). The delta is honest as a within-run demand
figure and it is the same *class* of quantity as the retired engine's canonical delta, which
is why D276/D277 accept it as the basis for firing this wave — but it satisfies only the
within-process half of D104, not the paired-control half. A later wave that wants to ratify
897 as a permanent floor law (rather than the firing floor of this wave) still owes the paired
idle control D211 demands.

---

## 3. What the launcher does with 897

`scripts/pds-crown-launch.sh` arms 897 through **three** knobs that must move together — a
verifier proved that editing only two is inert (the poll predicate silently defaults to 2200
and the detached child stands down forever):

1. **Poll predicate** (`MEM_FLOOR_MIB` default, `:348`) — the gate the detached child actually
   evaluates each draw. Baked to `:-897` in source so the fire does not depend on an operator
   remembering to export an env var.
2. **Arm-refusal guard-law** (`MEM_FLOOR_LAW`, `:412-414`) — the tighten-only floor. Moved to
   897 so a 897 predicate is not refused; the predicate may still be tightened *above* 897,
   never below.
3. **Harness floor** (`PDS_FULL_EXPORT_MIN_MEM_MB`, exported inside `fire_detached`'s D249
   contiguous block) — set to 897 so the frozen harness's own `cond_b` (b) gate matches. This
   reverses PDS-D244's deliberate UNSET; D244's refusal was taken against the retired engine's
   NEGATIVE −7.55 MiB delta and no longer applies.

Both effective knobs are now recorded distinctly — as `mem_floor_mib=897` and
`full_export_min_mem_mb=897` — in `run_dir/meta` and the arm banner, so a revert of *either*
is individually diagnosable (closes `pds-bl-w16-arm-never-records-its-own-floor` and
`pds-bl-floor-env-silent-revert`). The selftest asserts both, mutation-provably: revert any
knob and a check turns red.

---

## 4. Citations

- **PDS-D276** — the demand figure and the floor (§1, verbatim above).
- **PDS-D277** — arm all three knobs at 897; editing fewer is inert.
- **PDS-D278** — the arm records its own floor in meta and banner; the selftest is
  mutation-provable.
- **PDS-D222** — floor = demand *delta* + margin; margin = 798.81 MiB (MAX drawdown).
- **PDS-D232** — the wire-byte figure is unit-mixed and rejected.
- **PDS-D244** — the earlier UNSET, taken against the retired engine, now reversed.
- **PDS-D104 / PDS-D211** — the paired-idle-control standard the §2 caveat does not fully meet.
