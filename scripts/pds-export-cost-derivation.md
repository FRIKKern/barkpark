<!-- doc-tier: agent | canonical-for: pds-export-cost-derivation | budget: 12000tok -->

# PDS-D105 — export cost, re-derived from committed footprint

**What this is.** A read-only re-derivation of PDS-D105's export-cost arithmetic. D105's
*mechanism* — the workspace export materialises the whole bundle as one BEAM binary and
sends it unchunked — is confirmed here at a named sha. Its *headline arithmetic* is not:
D105 quoted "a BEAM idling at 750–867 MB", which is a swap-phase RSS sample and not a
quantity anyone is entitled to reason from. This file replaces that number with a measured
distribution of the stable invariant (RSS + VmSwap), and separates what was measured from
what is inferred.

**What this is NOT.** No engine code is changed. D105 is FILED, not fixed (core rule). No
export was executed for this document — a concurrent slice was firing a single unrepeatable
attempt on the same box while these samples were taken, so the peak figure below is
inference from reading `pack/2`, and is labelled as such everywhere it appears.

---

## 1. Citations, re-verified at a named sha

**Verified at `origin/main` = `d1345255418fd336f8720d65728843c4a7de694e`** (fetched
2026-07-20 ~02:52 UTC). Line numbers move; this sha is the anchor. Reproduce with:

```
SHA=d1345255418fd336f8720d65728843c4a7de694e
git show "${SHA}":"api/lib/barkpark/tenancy/workspace_bundle.ex"          | sed -n '242,300p' | nl -ba -v242
git show "${SHA}":"api/lib/barkpark/tenancy/workspace_bundle/archive.ex"  | sed -n '38,75p'   | nl -ba -v38
git show "${SHA}":"api/lib/barkpark_web/controllers/workspace_controller.ex" | grep -n "def export\|def import\|send_resp\|SYNC"
```

All four anchors are **exact at this sha**:

| Anchor | Claim | Verified output |
|---|---|---|
| `workspace_bundle.ex:259-276` | the `Enum.reduce` building the live `dumps` map | `:259` is `{members, dumps} =`, `:260` the reduce, `:276` `{[member \| members], Map.put(dumps, table, dump)}`. `do_export/2` opens at `:242`; `Archive.pack(manifest, dumps)` at `:297`. Public `export/2` at `:160-175`; `run_copy_out/1` at `:637`. |
| `archive.ex:56-57` | `:erl_tar.create` + `File.read!` **inside `pack/2`** (the export path) | `:56` `:ok = :erl_tar.create(String.to_charlist(path), members, [])`, `:57` `File.read!(path)`. `pack/2` opens at `:40`. `unpack/1` is a **separate function at `:66`** — the cited lines are not in it. |
| `workspace_controller.ex:157` | `send_resp(200, bundle)` **inside `export/2`** | `:157` is `\|> send_resp(200, bundle)`. `export/2` opens at `:148`. `import/2` is a **separate function at `:258`** — the cited line is not in it. |
| `workspace_controller.ex:126` | the moduledoc SYNC line | `:126` `SYNC: \`WorkspaceBundle.export/2\` materializes the whole tar binary in memory,` (continues `:127` `sent in one \`send_resp/3\`.`). |

### Corrections to the record

> **The wave-7 survey/digest claim that "all four of D105's file:line citations point at
> wrong functions" is FALSE.** It was produced by grepping a stale local checkout (~77
> commits behind, missing files that exist at origin/main). Every anchor above was
> re-verified against `d1345255` and is correct as originally written. The citations were
> **not** corrected, because there was nothing to correct. Recorded here so the next wave
> does not re-litigate it.

---

## 2. Where the 941 MB comes from

**941,046,272 bytes / 63 members** is **PDS-D41's live measurement** of `full.tar` from a
secret-scan control run. It is **not derivable from the three source files above** — no code
read produces a byte count. Any restatement of the export cost must cite D41 for this figure,
never the code.

- `941,046,272 B` = **897.4 MiB** = **941.0 MB** (decimal).

---

## 3. Committed footprint — a distribution, not a number

**Why RSS alone is not usable.** Per PDS-D114, RSS on this box is a swap-residency meter,
not a consumption meter: the same PID swung 1,024,468 kB → 216,852 kB in 55 s while VmSwap
rose 51,624 → 874,760 kB. Six methods agreed to 0.5% at the same instant and were all
equally uninformative. The stable invariant is **committed footprint = VmRSS + VmSwap**.

**Sampling method.** Single-shot `/proc/<pid>/status` reads over SSH, one process per sample,
each exiting in well under a second. The PID was resolved with `pgrep -x` (exact process
name) — **not** `pgrep -f` — see §5. No sampler loop, no backgrounded watcher, nothing
left alive on the box.

- **Window:** 2026-07-20 02:52:49Z → 02:54:08Z (79 s)
- **Cadence:** irregular, agent-paced (gaps 20 s / 7 s / 12 s / 36 s / 4 s) — *not* a fixed interval
- **Sample count:** n = 6
- **Target:** PID 663029, `beam.smp`, started Mon Jul 20 00:45:37 2026 (≈2 h 07 m uptime at first sample)
- **Caveat, load-bearing:** the window **overlaps a concurrent workload** (another slice's
  crown-proof attempt). These are *not* idle-baseline numbers and must not be quoted as such.

### Raw samples

```
02:52:49Z pid=663029 VmHWM: 1514912 kB VmRSS: 634324 kB VmSwap: 723632 kB memavail=1842612 swapfree=484000
02:53:09Z pid=663029 VmHWM: 1514912 kB VmRSS: 639176 kB VmSwap: 723508 kB memavail=1838136
02:53:16Z pid=663029 VmHWM: 1514912 kB VmRSS: 805192 kB VmSwap: 723504 kB memavail=1690304
02:53:28Z pid=663029 VmHWM: 1514912 kB VmRSS: 637180 kB VmSwap: 723444 kB memavail=1788676
02:54:04Z pid=663029 VmHWM: 1514912 kB VmRSS: 652620 kB VmSwap: 723232 kB memavail=1808992 swapfree=548000
02:54:08Z pid=663029 VmHWM: 1514912 kB VmRSS: 704240 kB VmSwap: 723112 kB memavail=1773672 swapfree=548512
```

### Derived distribution (committed = VmRSS + VmSwap)

| Sample | committed (kB) | GiB |
|---|---|---|
| 02:52:49Z | 1,357,956 | 1.295 |
| 02:53:09Z | 1,362,684 | 1.300 |
| 02:53:16Z | 1,528,696 | 1.458 |
| 02:53:28Z | 1,360,624 | 1.298 |
| 02:54:04Z | 1,375,852 | 1.312 |
| 02:54:08Z | 1,427,352 | 1.361 |

- **min 1,357,956 kB (1.295 GiB) · median ≈ 1,369,268 kB (1.306 GiB) · max 1,528,696 kB (1.458 GiB)**
- Spread: **170,740 kB (163 MiB), 12.6% of min** — over 79 s, on a box nobody deployed to.
- `VmSwap` was **flat to within 520 kB across the whole window** (723,632 → 723,112). Every
  bit of the variance is real RSS movement, not swap traffic. The 02:53:16Z outlier is a
  +166 MB allocation burst reclaimed within 12 s.

**This is the number that replaces "idling at 750–867 MB".** That figure was a single RSS
sample taken mid-swap-phase; the committed footprint is ~1.30–1.46 GiB and it is a range,
not a point. Note it also sits at/above the ~1.07–1.35 GB the wave anticipated — consistent
in mechanism, but the top of the window exceeds it, which is exactly why a distribution is
required and a single sample is not.

### Box capacity, same reads

- `MemTotal` **3,911,580 kB = 3.73 GiB** (the "3.8 GB box")
- `MemAvailable` **1,690,304 – 1,842,612 kB = 1.61 – 1.76 GiB** across the window
- `SwapTotal` 2,097,148 kB; `SwapFree` **484,000 – 548,512 kB** — swap is **74–77% consumed**

---

## 4. The cost, with measured and inferred kept apart

### Measured

| Quantity | Value | Source |
|---|---|---|
| Full bundle size | 941,046,272 B (897.4 MiB) | **PDS-D41** live measurement |
| Committed BEAM footprint | 1.295 – 1.458 GiB (n=6, §3) | **this document**, single-shot `/proc` reads |
| Box total / available / swap-free | 3.73 GiB / 1.61–1.76 GiB / 0.46–0.52 GiB | **this document**, `/proc/meminfo` |

### Inferred (from reading `pack/2` — not measured here)

`pack/2` builds a `members` list of references to the per-table dump binaries, hands them to
`:erl_tar.create` which writes the archive **to a temp file on disk**, then `File.read!(path)`
reads the entire archive **back into a fresh binary**. At the instant `File.read!` returns:

- the `dumps` map from `workspace_bundle.ex:259-276` is still referenced by `do_export/2`
  (it is the live argument to `Archive.pack/2`), and
- the freshly-read tar binary (~897 MiB) is also live.

So the export is inferred to hold **roughly two concurrent copies of the payload** at that
boundary — **the ~2× multiplier is inference, not measurement.** It also needs ~897 MiB of
**disk** in `System.tmp_dir!()` transiently. Then `send_resp(200, bundle)` holds one ~897 MiB
copy until the response is written.

| Phase | Incremental demand | Basis |
|---|---|---|
| Single live copy (`send_resp`) | **+0.876 GiB** | measured bundle size (D41) |
| Inferred `pack/2` peak (dumps + tar) | **≈ +1.75 GiB** | **inference** from `archive.ex:40-61` |

### Verdict against the observed box

- **Single copy:** 0.876 GiB against 1.61–1.76 GiB `MemAvailable` — **fits, with margin.**
- **Inferred peak:** ≈1.75 GiB against 1.61–1.76 GiB available, plus 0.46–0.52 GiB swap-free
  as the only remaining absorber. Total absorbing capacity ≈ **2.07–2.28 GiB** vs ≈1.75 GiB
  demand. **Thin, and only if nothing else on the box moves** — while §3 shows the BEAM
  alone moving 163 MiB unprompted inside 79 s.
- **Against the harness's own gate (b) = 2200 MB:** `MemAvailable` was **1,650–1,799 MiB on
  every one of the six samples** — below the gate every time. The full-export leg would
  **abort on headroom right now**, on all six reads, with no coin-flip involved.

### Where this document *narrows* D105

D105's headline says full-fidelity export is "architecturally unaffordable on this box
**permanently**". These numbers do not carry that word. What they carry is:

1. the **mechanism** is confirmed exactly as cited (§1) — one unchunked binary, materialised twice;
2. the export has **no engineering margin** — the inferred peak and the absorbing capacity
   are the same size, which is not a design, it is a coincidence;
3. it is **refused by the harness's own headroom gate on every observation taken**.

"No margin and gate-refused" is what the evidence supports. "Permanently unaffordable" would
need a measured peak, and **no peak was measured** — measuring it is precisely what rungs 3/4
of the crown proof exist to do. If those rungs execute, their measured peak supersedes the
inference in this section and this document should be re-derived against it.

---

## 5. Live confirmation of PDS-D113 (incidental, filed not fixed)

The frozen harness selects its RSS target with `pgrep -f beam.smp | head -1`. At 02:52:49Z
that command returned, in order:

```
619341
663029
```

`head -1` therefore selects **619341**, which is:

```
sh -c for i in $(seq 1 2000); do printf "%s " $(date +%s); awk "/MemAvailable/{print $2}" /proc/meminfo; ps -C beam.smp -o pid=,rss=,etimes= | ...
Name: sh    VmHWM: 1920 kB    VmRSS: 1852 kB    VmSwap: 72 kB
```

— a **foreign sampler shell** (another session's, per PDS-D106; started 00:27:34, before the
BEAM at 00:45:37, hence the lower PID). It matches `pgrep -f` only because its own command
line contains the literal `beam.smp` inside a `ps -C` argument. Its RSS is **1,852 kB**.

The actual BEAM is **663029** at **VmRSS 634,324 kB**. So the harness, if it sampled during
this window, would report a BEAM RSS **~342× too small** and read it as trivially within any
headroom bound.

**Filed, not fixed** — the harness is frozen and this document does not touch it. It is
recorded here because it is the difference between a headroom reading of 1.8 MB and 634 MB.
This slice worked around it by resolving the PID with `pgrep -x` (exact process *name*),
which matches only the real `beam.smp`.

---

## 6. What is NOT known

- **No measured export peak.** Nothing here executed an export. The ~2× multiplier is a
  code-reading inference and could be wrong in either direction: ERTS refc-binary sharing
  could make it lower, allocator fragmentation and the ~897 MiB temp file's page cache
  could make the effective pressure higher.
- **No idle baseline.** The window overlapped concurrent work. §3 is a loaded-box
  distribution and is labelled as one.
- **n = 6 over 79 s** with irregular agent-paced spacing. It is enough to kill a single-point
  quote; it is not a characterisation of the box over hours or across deploys.
- **Single BEAM generation.** All samples come from one process (663029, booted 00:45:37).
  A fresh post-deploy BEAM would sit lower; nothing here measures how much lower, or how
  fast it climbs back.
- **Disk headroom in `System.tmp_dir!()` was not checked**, and `pack/2` needs ~897 MiB there.

---

## 6b. SUPERSEDED IN PART — the peak was measured, hours later (added 2026-07-20, review)

**Dated correction, appended at wave-7 review; nothing above is rewritten.** §4 and §6 state
that no export peak was measured and ask to be re-derived if crown-proof rungs 3/4 execute.
**They executed.** The concurrent slice `pds-w1-crown-proof` fired its one budgeted attempt at
03:25:47Z — roughly 30 minutes after this document's last sample — and its measurements are in
`scripts/pds-pull-proof.crown-transcript.txt` §5. That transcript, not this file, is the
canonical source for the export's measured cost.

| Quantity | This doc (inferred, 02:52Z) | Crown transcript (measured, 03:25Z) |
|---|---|---|
| Bundle size | 941,046,272 B (D41, 897.4 MiB) | **1,037,336,576 B** (989.3 MiB) — the source grew |
| Peak incremental demand | ≈ +1.75 GiB (inference from `pack/2`) | **≈ +2,235.43 MiB (2.18 GiB)** — 194,228 kB baseline → 2,483,304 kB peak |
| Implied multiplier on payload | ~2× (code reading) | **~2.25×** (2.18 GiB / 0.966 GiB) |

**The inference held, and was conservative.** The ~2× read of `pack/2` was directionally
correct and slightly *under*-estimated the real demand. §4's mechanism paragraph therefore
stands as written; only its "no peak was measured" caveat is retired.

Two things the measurement changes materially:

1. **§4's "narrowing" of D105 is itself narrowed.** This document declined the word
   "permanently" for want of a measured peak. With a measured peak of ~2.18 GiB incremental
   on a 3.8 GB box, the crown transcript states the unaffordability verdict as first-class.
   That verdict rests on one measurement, not a distribution — but it is a measurement, which
   is what §4 said was missing.
2. **The gate-(b) finding is sharpened, not contradicted.** §4 observed `MemAvailable` below
   the 2200 MB floor on all six samples and concluded the leg "would abort on headroom right
   now" — true at 02:52Z; the gate read open (2846 MB) at 03:25Z, so the window did open. The
   stronger finding is the transcript's: the 2200 MB floor is **~35.43 MiB below the demand it
   gates**. Passing gate (b) is therefore not evidence the export is affordable. Neither
   document lowers the floor.

### 6b.1 The arithmetic, and which baseline is t=0 (added 2026-07-20, wave 9)

**Unit correction.** Earlier revisions of this row and of the crown transcript's §5 stated the
growth as 2231 and the shortfall as 31, in mislabelled MB. That was a unit-mixing slip: a
`/1000`-scaled read of the baseline (194) subtracted from a `/1024`-scaled peak (2425). Worked
in the SAME convention the harness itself uses for the floor — `mem_mb=$((mem_kb / 1024))`,
`scripts/pds-pull-proof.sh:1302` — the subtraction is
`2,483,304 − 194,228 = 2,289,076 kB = 2,235.43 MiB`, so the 2200 MB floor sits **35.43 MiB
below** the demand it gates, not 31. The direction of the finding is unchanged; only its
magnitude was understated.

**Which baseline is t=0 — PDS-D185 rules 194,228 kB.** The transcript carries three candidate
pre-fire readings, and the choice moves the number:

| Candidate t=0 | Source | Derived incremental demand |
|---|---|---|
| 189,684 kB | `VmRSS` pre-fire sweep (crown transcript :67) | 2,239.86 MiB |
| **194,228 kB** | **`ps -o rss=` single shot (:648, :790) — RULED t=0** | **2,235.43 MiB** |
| 230,072 kB | sampler's first logged tick (:912) | 2,200.42 MiB |

The sampler's first tick is **not** t=0: it is taken at t≈+1 s, *after* the request fired, so it
already contains part of the export's own allocation. Using it subtracts part of the very thing
being measured — and it errs in the direction that flatters the floor. The `ps` single shot is
the last reading taken strictly before the fire, so it is the honest zero.

**The ambiguity moves magnitude, never sign.** All three candidates exceed 2200 MiB
(2,239.86 / 2,235.43 / 2,200.42), so under every available reading of the baseline the floor is
below the demand it gates. And per **PDS-D114** the 1 Hz RSS sampler reports a **lower bound** on
the true peak — a transient above the sample grid is invisible — so 2,235.43 MiB understates the
real demand rather than overstating it.

Still not closed by either file: the disk-headroom gap in `System.tmp_dir!()` named in §6.

---

## 6c. The paired-control instrument (added 2026-07-20, wave 11)

**What it is.** `scripts/pds-export-peak-measure.sh` — a standalone measurement tool that
reproduces the frozen harness's RSS procedure *exactly* and adds the half PDS-D104 asked for
and the harness never had: a **paired idle control**.

**Why it had to be built.** §6b.1's 2235.43 MiB was taken by the sampler at
`scripts/pds-pull-proof.sh:1373-1467`. That sampler states its rate (satisfying one half of
PDS-D104) but has no control window at all — `grep -E 'idle|paired' scripts/pds-pull-proof.sh`
returns **zero hits**. The root task
(`pds-bl-streaming-workspace-export`) requires the post-fix number carry *both* halves. Since
the harness is frozen at blob `e219e97ccf7f33797c86a2b84d998d599b6bda31`, the control had to
live beside it, not inside it.

### 6c.1 Relationship to the frozen sampler

The instrument is deliberately **not** an improvement on the frozen procedure — a
"better" measurement would not be comparable to 2235.43 MiB, and comparability is the whole
point. Five properties are reproduced verbatim:

| Property | Frozen harness | This instrument |
|---|---|---|
| Units | `kB / 1024` | `kB / 1024`, and `LC_ALL=C` so no comma locale renders `115.46` as `115,46` |
| t=0 baseline (PDS-D185) | one-shot `ps -o rss=` strictly pre-fire | identical, and **re-taken per window** so the control's own drift never lands in the export delta |
| Selector (PDS-D135) | `pgrep -o -x beam.smp`, peak = MAX across all slots | identical; slots re-enumerated on *every* tick |
| Rate | 1 Hz, stated | 1 Hz, stated, with the PDS-D114 lower-bound caveat printed |
| Compression | none requested | none requested; a `--path` carrying `--compressed`/`accept-encoding` is **refused** |

Two things are *added*, both disclosed rather than silently applied:

1. **The idle control.** An idle window of the same cadence runs immediately before the
   measured window with zero requests issued. Both peak-minus-baseline figures are printed
   with the subtraction shown. The control is **never subtracted** from the headline — it is
   printed beside it, so a reader judges for themselves how much of the delta is drift.
2. **The baseline asymmetry, named.** The frozen procedure takes its baseline from the
   *primary slot alone* but its peak from the *MAX across all slots*. On a one-slot box these
   agree; on a two-slot box the baseline can under-read the set and inflate the delta. The
   instrument keeps the frozen arithmetic (comparability) and *also* prints the
   max-across-set baseline as `*_baseline_set_kb` so the size of the asymmetry is visible.

### 6c.2 First live run — and what it found

Run `20260720T202617Z-17701`, deployed sha `bd2e72a8971da6e88091b3869b8c6e9e71cefeac`,
acquisition `GET /api/workspaces/default/export?profile=dev&dataset=production` (HTTP 200,
65,234,432 bytes), one comm-anchored slot, pid 1302615:

| Window | baseline (kB) | peak (kB) | delta | wall | n |
|---|---|---|---|---|---|
| Measured (dev export) | 1,021,600 | 1,125,748 | **104,148 kB = 101.71 MiB** | 11 s | 11 |
| **Paired idle control** | 862,876 | 1,164,916 | **302,040 kB = 294.96 MiB** | 31 s | 30 |

**The control is 2.9× the measured delta.** Thirty-one seconds of an idle BEAM, with nothing
asked of it, moved ~295 MiB — more than the export it was controlling for. This is the
confound PDS-D104 was written about, now measured on this box at this sha. Two consequences
worth recording:

- For *this* acquisition the measurement is **drift-dominated**: 101.71 MiB is not resolvable
  as the export's own cost. A small acquisition cannot be measured this way at all.
- **The canonical 2235.43 MiB has itself never been drift-controlled.** Nothing here refutes
  it — 295 MiB of drift against a 2235 MiB delta is ~13%, so the *sign* of §6b.1's finding
  (the 2200 MiB floor sits below the demand it gates) is not in danger. But the figure's
  error bar is now known to be non-trivial and was previously unstated.

### 6c.3 How a future re-derivation is run

```
# the full-fidelity figure, directly comparable to 2235.43 MiB
scripts/pds-export-peak-measure.sh --label post-spill --out /tmp/peak.line

# a narrowed acquisition (skips the full-export headroom gate)
scripts/pds-export-peak-measure.sh --window 30 \
  --path '/api/workspaces/default/export?profile=dev&dataset=production'
```

Defaults: acquisition = the FULL workspace export; `--window` = 130 s, the canonical export's
wall time, so the control pairs with a full run. The script **refuses** (exit 2) rather than
guess when it cannot measure honestly:

- SSH unavailable — the BEAM's RSS lives on the source box and nothing is quoted unsampled;
- no process with `comm == beam.smp` — never falls back to a looser argv match;
- the frozen harness's lock `/tmp/pds-full-export/lock` is held — **PDS-D31**, two concurrent
  full exports OOM the box, so the two tools are mutually exclusive by construction;
- a full acquisition with `MemAvailable` under `PDS_FULL_EXPORT_MIN_MEM_MB`;
- **the acquisition window logged ZERO samples** — **PDS-D220a**. `peak_kb_of` returns 0 for an
  empty log and the delta subtracts the baseline from it unguarded, so an acquisition returning
  before the sampler's first ~1 s tick (a 404, a 500, a reset under memory pressure — exactly the
  regime a crown run fires in) emitted `export_samples=0 export_delta_mib=-847.18` and **exited
  0**. A negative demand is not a measurement; it is now a refusal that names the cause.
- **either leg of the IDLE CONTROL window logged ZERO samples** — **PDS-D220a, applied to the
  control**. The guard above was chartered for the acquisition leg; review found the identical
  hole on the control leg, where it matters more. A dropped sampler `ssh` session left the RSS
  log empty, and the run **printed `idle drift … = -1190.45 MiB [BEAM RSS]` as a reported
  figure, carried on past the control, and fired a real 67 MB acquisition** before stopping.
  This instrument exists to put a control *beside* the demand (**PDS-D104**, **PDS-D216**); a
  control indistinguishable from a failed sampler is the exact failure it was built to prevent.
  The `MemAvailable` leg refuses on the same rule for a sharper reason: an unsampled leg yields
  min 0 / max 0 / **range 0.00 MiB**, which reads to a threshold check as *the quietest possible
  box* and would **pass PDS-D221's 1048.16 MiB contamination abort vacuously**. The sample count
  is therefore *enforced* here, not merely emitted for a downstream reader to remember to check.
  Both refusals fire **before** the acquisition, so — unlike the export-leg guard — they also
  spend no export. Proven by mutation against deployed `bc64d869a`: emptying the RSS log alone
  gives exit 2 naming the −1196.71 MiB it declined to report; emptying the `MemAvailable` log
  alone gives exit 2 naming the vacuous range; an unmutated run of the same script exits 0 with
  both legs sampled, so neither guard false-positives.

That `MemAvailable` gate is why wave 11 has no full-regime figure yet: `MemAvailable` read
1312 MiB and 1490 MiB during this slice, against a 2200 MiB floor. The window was shut, and
forcing it would have risked OOM-killing the live content API.

**The floor: read here, and — under PDS-D219 — writable by the measure, as a declared bypass.**
This instrument still only READS `PDS_FULL_EXPORT_MIN_MEM_MB`; it contains no code that moves it.
The earlier sentence here said the floor is *"read, never written — moving it is
`pds-w11-floor-rederivation`, not this instrument"*. **PDS-D219 amends that** at the campaign
level, not in this script: the wave-12 measure fires with `PDS_FULL_EXPORT_MIN_MEM_MB` explicitly
exported to a threshold **pre-declared before the run**, and that override is recorded **as a
bypass** — named, with its value and its reason, in the run's own evidence — rather than being
folded in as if it were the derived floor. The distinction that matters: a pre-declared,
recorded bypass is auditable; a floor quietly lowered until the gate opens is the vacuous green
PDS-D20 forbids. The gate's own code is unchanged by D219, and re-deriving the floor's *value*
remains the floor-rederivation slice's work, not this instrument's.

**What the idle control emits, and its unit class — PDS-D220b.** The control window samples two
quantities. BEAM RSS (`idle_delta_mib`) is the frozen procedure's quantity and stays the
headline. `/proc/meminfo` MemAvailable is sampled alongside it and emitted as
`idle_memavail_min_kb`, `idle_memavail_max_kb`, `idle_memavail_range_kb`,
`idle_memavail_range_mib` and `idle_memavail_samples`, because **PDS-D221 states its
contamination-abort threshold (1048.16 MiB) on the RANGE of MemAvailable** — a whole-box figure.
Attaching that threshold to a per-process RSS delta compares two different quantities: the same
unit-class error **PDS-D185** exists to correct, one level up. The instrument makes the number
exist and does **not** abort on it; applying the threshold is the measure slice's call.

**Three bugs the first live run found that reading could not.** Recorded because they are the
argument for always firing the instrument before trusting it: (a) `PID="$(start_sampler …)"`
captured a *subshell's* `$!`, so `wait` returned instantly (the idle window collapsed to 0 s
and logged nothing) and `kill` missed — **leaving the remote sampler loop alive on the source
box**, confirmed by `ps` and killed by hand; (b) `grep -c . file || echo 0` printed `0\n0` on
an empty file, because `grep -c` prints `0` *and* exits 1; (c) a comma locale rendered every
MiB figure with a decimal comma, silently corrupting the machine-readable line.

---

## 7. Provenance

- Citations verified at `origin/main` `d1345255418fd336f8720d65728843c4a7de694e`, 2026-07-20.
- Footprint samples: guerrilla `157.180.90.121`, 2026-07-20 02:52:49Z–02:54:08Z, n=6, single-shot `/proc` reads.
- 941,046,272 B / 63 members: **PDS-D41** (live measurement, not re-measured here).
- RSS-is-a-swap-meter: **PDS-D114**. `pgrep -f` target selection: **PDS-D113**. Foreign sampler 619341: **PDS-D106**.
- Read-only throughout: `git show` and `/proc` reads only. No writes, no restarts, no exports,
  `/tmp/pds-full-export` untouched, no foreign process signalled.
