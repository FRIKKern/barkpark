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
| Peak incremental demand | ≈ +1.75 GiB (inference from `pack/2`) | **≈ +2,231 MB (2.18 GiB)** — 194,228 kB baseline → 2,483,304 kB peak |
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
   stronger finding is the transcript's: the 2200 MB floor is **~31 MB below the demand it
   gates**. Passing gate (b) is therefore not evidence the export is affordable. Neither
   document lowers the floor.

Still not closed by either file: the disk-headroom gap in `System.tmp_dir!()` named in §6.

---

## 7. Provenance

- Citations verified at `origin/main` `d1345255418fd336f8720d65728843c4a7de694e`, 2026-07-20.
- Footprint samples: guerrilla `157.180.90.121`, 2026-07-20 02:52:49Z–02:54:08Z, n=6, single-shot `/proc` reads.
- 941,046,272 B / 63 members: **PDS-D41** (live measurement, not re-measured here).
- RSS-is-a-swap-meter: **PDS-D114**. `pgrep -f` target selection: **PDS-D113**. Foreign sampler 619341: **PDS-D106**.
- Read-only throughout: `git show` and `/proc` reads only. No writes, no restarts, no exports,
  `/tmp/pds-full-export` untouched, no foreign process signalled.
