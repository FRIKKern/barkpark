<!-- doc-tier: human | canonical-for: pds-crown-verdict | budget: 4000tok -->

# PDS Crown Verdict — 2026-07-20

This is the committed verdict on `pds-w1-crown-proof`, the PDS epic's crown task. For three
waves the crown's state lived in claim now-lines and unpushed branches; this file ends that.
The verdict was decided in wave 9 (PDS-D178 through PDS-D189) and is RECORDED here, not
re-decided. This file stamps and closes nothing — PDS-D171 reserves crown stamping for the
LEAD, off the committed transcript, and PDS-D189 makes the order load-bearing (criteria 6
and 10 must never both read `met` before the LEAD intends an irreversible close; criterion
10's fence is prose, not a guard, and it fails open).

**The verdict, in one line: criterion 6 is PAID; criterion 10 is REFUSED on cond_b.**
The crown stands at 10 of 11, precisely located. The task stays OPEN per PDS-D122.

## Criterion 6 — PAID

Evidence: commit `9e838499f` (`scripts/pds-pull-proof.crown-transcript-w8.txt`, 836 lines).
One serial `--all` fired 2026-07-20T11:40:22Z under `PDS_RUN_ID=pdsw9-reclimb-20260720`,
off the harness FROZEN at blob `e219e97ccf7f33797c86a2b84d998d599b6bda31`, verified
identical before and after the run. The result line (transcript :17):

    RESULT     9 PASS · 2 ABORT (named, severable, environmental) · 0 FAIL

Rung 6 — the rung three waves could not pay — passed with its control firing in BOTH
directions for the first time in the epic's life, with zero export attempts spent.

**Leg A** (drifted rows survive a stamped reboot): 34 rows sentinelled in the eight guarded
columns; digest `0ea8e23e6e234a2e81e13dc2d4ee9e5a rows=36` unchanged across the reboot;
34 of 34 sentinels intact; the boot logged exactly 34 Bootstrap guard SKIPs from an
independently derived walk, matching the sentinel's own `RETURNING` count.

**Leg B, quoted PER-COLUMN** (the same rows revert once the stamp is cleared by asserted
SQL): the next boot reverted ALL EIGHT of `title`, `icon`, `visibility`, `owner_scoped`,
`fields`, `cors_origins`, `desk_groups`, `list_preview`, and the sentinel was wiped —
**0 of 34 rows** retained any trace of the drift (digest moved to
`c3b6f2d3950a9a9ec8f5f13e9c4243a7 rows=36`). The pre-named dormant mode
`pds-bl-legb-visibility-false-red` did not fire.

**The banner phrase is an overclaim — do not repeat it.** The raw PASS line (transcript
:789) says the rows "were sentinelled in all eight guarded columns". Per PDS-D153 (as
corrected by the wave-9 ledger amendment, `scripts/pds-crown-ledger-2026-07-20.md`) that
phrase is one column short of literally true: `visibility = 'private'` is a literal, not a
flip, and **31 of the 34 in-scope rows are natively private**, so the sentinel's visibility
write is a no-op on 31 rows and leg B's visibility control rests on **n=3** (the three
natively-public rows). Non-vacuous, but thin — quote the per-column reversion result above,
never the banner (PDS-D181).

## Criterion 10 — REFUSED, on cond_b

Rungs 3 and 4 ABORTED, verbatim (transcript :322, :324):

    3     ABORT    env:full-export-unavailable — cond_b FAILED (1249 MB vs floor 2200)
    4     ABORT    env:full-export-unavailable — cond_b FAILED (1224 MB vs floor 2200)

Per PDS-D122 a severable headroom ABORT is an honest designed outcome that does NOT close
the task. The refusal is recorded as an attempt with its reason, never as a close
(PDS-D182). Successor filed: `pds-bl-cond-b-window-unreachable`.

**The claim is narrow, deliberately.** This record does NOT say "no window exists" — that
is refutable by our own data: 00:10–00:50Z on 2026-07-20 held roughly 40 minutes at min
2378 MiB. The true claim (PDS-D183): no window exists in the hours this epic operates in;
the only clearing band observed is 00:00–03:00Z. And the trap that makes the narrow claim
stronger: **three of that day's four longest windows PASS cond_b's 2200 floor while FAILING
the corrected 2235.43 MiB demand** — a run can clear the gate and be unable to afford the
export.

**The structural reason, not just samples.** The box is 3819 MB total; `beam.smp` — the
LIVE content API the floor exists to protect — holds about 1352 MB; the measured
incremental demand is **2235.43 MiB** (PDS-D185: `(2483304 − 194228) kB / 1024`, robust
under all three candidate baselines — 2239.86 / 2235.43 / 2200.42 — the ambiguity moves the
shortfall's magnitude, never its sign). The 2200 floor therefore sits **~35 MB BELOW the
demand it gates**: lowering it would widen a gate already too narrow. Sample evidence: the
climb's own 90-minute wait sampled 90 times — **0 of 90** clearing the floor (min 981.62 /
median 1524.71 / max 1733.53 MB, best sample 466 MB short) with SwapFree DRAINING
1294 → 750 MB, pressure rising across the wait; two independent verifiers added 0 of 36 (at
5-second granularity) and 0 of 7 — 133 consecutive failures across three methods. No
sampling can wait out a box that is structurally too small.

**The named lever is REFUTED.** `pds-bl-guerrilla-ssr-leftovers` claimed eight leftover
`barkpark-site` SSR services hold the cond_b gate. Measured: all eight live, combined
`MemoryCurrent` **22,245,376 bytes = 21 MB against an 894 MB shortfall** — 2.4% of the gap
(PDS-D184). Reclamation is not a fix, and taken alone it manufactures exactly the
pass-the-gate-cannot-afford-the-export trap above. That task's premise is false; it must
never again be filed as the crown's unblocker.

## The three non-actions

1. **The floor was never lowered.** `PDS_FULL_EXPORT_MIN_MEM_MB` was never exported —
   `grep -c` over the invocation environment: 0; the floor printed by the run is 2200, the
   default, verifiable in the five-condition blocks at transcript :593 and :732.
2. **The attempts store was never reset or repointed.** It read 1 before the run and reads
   1 after it — 0 of 2 spent this run, because the counter increments only after all five
   preconditions pass.
3. **No engine repair was made to help the crown pass.** The real product defect the
   refusal points at — the unchunked in-RAM full export
   (`pds-backlog-streamed-bundle-channel`) — was deliberately not started under the proof.

## Provenance

Transcript commit `9e838499f` (branch `loop-epic/the-crown-gets-paid-or-gets-named-one-se-0`
at recording time); frozen harness blob `e219e97ccf7f33797c86a2b84d998d599b6bda31` (verify
with `git rev-parse HEAD:scripts/pds-pull-proof.sh`, never `shasum` — PDS-D154); wave-9
paper `pds-wave-9-verdict-2026-07-20`; criterion-wording history in
`scripts/pds-crown-ledger-2026-07-20.md`. The wave-7 climb and its rung-6 FAIL remain
exactly where they are, in `scripts/pds-pull-proof.crown-transcript.txt`.
