<!-- doc-tier: agent | canonical-for: pds-window-availability | budget: 14000tok -->

# The window availability record — a week of guerrilla, measured

**What this is.** The durable dataset behind PDS-D190. For nine waves this epic treated the
cond_b memory gate as a knife-edge lottery to be timed. It is not, and this file is the
measurement that says so once so that it never has to be re-litigated — **whether or not the
wave-10 climb ever fires**. If the climb fires and passes, this record explains why it was
always likely to. If it misses, this record is the refusal artefact, and a refusal carrying
1001 samples is a verdict rather than the anecdote a six-point curve produced.

**What this is NOT.** Not a decision, not a permission to fire, and not a claim that cond_b
will clear at any particular moment. §5 states the residual the data cannot close. Nothing
here touches the frozen harness (blob `e219e97ccf7f33797c86a2b84d998d599b6bda31`, PDS-D100 /
PDS-D154) and no export budget was spent producing it.

**The demand this scores against is 2235.43 MiB** — PDS-D185's corrected export-cost
arithmetic (2,483,304 − 194,228 = 2,289,076 kB), never the 2200 floor, which sits 35.43 MiB
*below* the demand it gates. All comparisons below are `kbavail >= 2289076` in `sar`'s native
kB (1024-byte) units, so the comparison is unit-consistent end to end and does not repeat the
`/1000`-vs-`/1024` slip D185 exists to correct.

---

## 0. Provenance — and what was re-derived rather than copied

The wave-10 survey produced the headline figures. **This record did not copy them; it
re-derived them from the box** (guerrilla, `157.180.90.121`, box clock `Etc/UTC`), and the
week-scale headline reproduced to the digit:

| Headline | Survey | Re-derived here | Agrees |
|---|---|---|---|
| sar samples, sa12..sa18 | 1001 | 1001 | yes |
| clearing 2235.43 MiB | 79.0% | 79.0% (791/1001) | yes |
| longest clearing streak | 1050 min | 1050 min (105 samples, from 07/12 11:30) | yes |
| longest FAIL streak | 130 min | 130 min (13 samples, from 07/14 18:40) | yes |

Reproduction (both legs; the second is the one the survey got wrong — see §1b):

```sh
for d in 12 13 14 15 16 17 18; do
  LC_ALL=C sar -r -f /var/log/sysstat/sa$d |
    awk -v D=$d 'NR>2 && $1 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/ && $2 ~ /^[0-9]+$/ {print D, $1, $3}'
done                                        # field 3 = kbavail; clear iff >= 2289076

journalctl --since "2026-07-12 00:00:00" --until "2026-07-19 00:00:00" \
  -o short-iso _SYSTEMD_UNIT=init.scope | grep -E "Started barkpark-slot@"
```

Three things in this file are **quoted from the wave-10 survey and were NOT re-run**, because
their source is transient in-memory state that no longer exists (the BEAM has restarted many
times since): the 24-sample oscillation run in §2, the two 90-second contention steps in §4,
and the survey's own isolated-deploy statistic in §3. Each is labelled at its use. Everything
else in this file is re-derived and reproducible from the two commands above.

---

## 1. THE WEEK

1001 ten-minute `sar -r` samples, 2026-07-12 00:10 UTC through 2026-07-18 23:50 UTC.

**791 of 1001 samples (79.0%) cleared the 2235.43 MiB demand.** The window is the box's
majority state by a wide margin. It is not a knife edge.

Distribution of `kbavail` across the week, in MiB:

| min | p10 | p25 | median | p75 | max |
|---|---|---|---|---|---|
| 991 | 2012 | 2294 | 2527 | 2675 | 2984 |

The median sample clears the demand by **292 MiB**. The p25 sample still clears it. The
demand sits between the p10 and p25 of the week's own distribution.

Continuity, which matters more than the rate because the export needs a *held* window and not
an instant:

- **Longest continuous clearing streak: 1050 minutes (17.5 hours)** — 105 consecutive
  samples from 2026-07-12 11:30 to 2026-07-13 05:00.
- **Longest continuous FAIL streak: 130 minutes** — 13 consecutive samples from
  2026-07-14 18:40. The worst the week ever did was shut the window for a little over two
  hours. Against a check-and-go poller on a ~10-minute cadence (PDS-D92) that costs 13 free
  probes and zero export attempts.

### 1a. Per day

| Day | samples | clear rate | median MiB | min MiB | slot restarts | longest deploy-free gap |
|---|---|---|---|---|---|---|
| 07/12 | 143 | 99.3% | 2706 | 1818 | 31 | 595 min (00:00→09:55) |
| 07/13 | 143 | 88.1% | 2648 | 1550 | 59 | 289 min (00:25→05:14) |
| 07/14 | 143 | 82.5% | 2589 | 1274 | 25 | 266 min (16:16→20:41) |
| 07/15 | 143 | 88.8% | 2512 | 1870 | 23 | 265 min (06:21→10:46) |
| 07/16 | 143 | 67.8% | 2399 | 1393 | 65 | 120 min (06:56→08:57) |
| 07/17 | 143 | 60.8% | 2355 | 1131 | 41 | 168 min (00:56→03:45) |
| 07/18 | 143 | 65.7% | 2349 | 991 | 40 | 256 min (19:44→23:59) |

"Slot restart" = a `Started barkpark-slot@{blue,green}.service` line; guerrilla is blue/green,
so this is the deploy event the epic has been calling a deploy. 284 across the week. The
gap column brackets each day at its own midnight boundaries, so a gap can be truncated by the
day edge (07/12's 595 min and 07/18's 256 min both are) — they are lower bounds on the real
inter-deploy gap, never upper.

**Every day of the week cleared the majority of its samples.** The worst day, 07/17, still
cleared 60.8%.

### 1b. The 07/12 figure the survey reported is a journalctl truncation artefact — named, and excluded

The survey enumerated deploys with `journalctl --since '8 days ago'`. That flag is relative to
the *invocation clock*, so on 07/20 it cut 07/12 at **22:41** and returned only the tail of
the day. Measured directly: **07/12 has 31 slot restarts; the truncated query saw 3**, the
first real deploy of the day being at 09:55:28 — nearly thirteen hours inside the window the
truncated query could not see.

The artefact is not cosmetic, and it does not merely add noise — it points in one direction.
It turned the week's **highest-clearing day (99.3%) into an apparently near-deploy-free day**,
which is exactly the shape that manufactures a "fewer deploys ⇒ more clearing" correlation.
§3 quantifies how much of the survey's reported correlation is this artefact and nothing else.

The journal itself is *not* truncated — retention on this box reaches back to 2026-06-29, so
the corrected 07/12 figures above were recovered by re-querying with an absolute `--since`,
not estimated. Rule for this record: **the survey's 07/12 deploy count is excluded from every
density claim.** Where a density claim is made, it is made on the corrected count and says so.

---

## 2. THE OSCILLATION — why the old six-point decay curve was wrong

Waves 7 through 9 carried a six-point "decay curve" reading that MemAvailable fell with BEAM
uptime and that the window shut somewhere around BEAM ELAPSED 12:57. That model is refuted.

**Quoted from the wave-10 survey; not re-run** (the sampled BEAM epoch is long gone):

> 24 consecutive 5-second samples at BEAM ELAPSED **20:15 → 22:11** read 2434–2586 MB and
> **all 24 cleared** the 2235.43 MiB demand — at roughly twice the uptime at which the curve
> claimed the window shuts. Decisive rows, verbatim:
>
> ```
> 16:29:38Z etime=20:15 rss_kb=403388 memavail_kb=2622640
> 16:31:09Z etime=21:46 rss_kb=550224 memavail_kb=2492384
> ```

The mechanism: MemAvailable **oscillates by roughly 550 MB on a ~20-second timescale**,
anti-correlated with BEAM RSS, which itself swings between 382 MB and 750 MB under ordinary
traffic with no deploy involved. Within one BEAM epoch, MemAvailable is not a slowly decaying
line — it is a fast oscillation with a shallow trend, if any.

The six curve points were **one instantaneous sample per BEAM epoch, each drawn at a random
phase of that oscillation**. Six random-phase draws from six different epochs, fitted as a
decay curve. The apparent trend was phase, not decay. The week-scale data is consistent with
this and not with the curve: the 1050-minute clearing streak in §1 spans multiple BEAM epochs
in both directions, which a uptime-driven decay could not produce.

**Operational consequence:** a single instantaneous MemAvailable read is a draw from a ~550 MB
distribution, not a measurement of the box's state. This is the first of the two reasons
§5's residual cannot be closed by picking a higher floor.

---

## 3. THE DEPLOY EFFECT — both directions, because both are true

This section refuses a claim that the data superficially supports.

### 3a. Single-event level: a deploy really is a freshening

**Survey figure, quoted:** across **107 isolated deploys**, mean **+298 MiB**, with **90 of
107 positive (84%)**. That is a substantially stronger base than PDS-D93's original one-day
n=30 (mean +174 MB, 9 of 30 negative).

**Independent replication here.** The survey's isolation criterion is not recorded, so the
exact n could not be reproduced. Re-derived with an explicit criterion — a slot restart with
no other slot restart within ±N minutes, delta = the `kbavail` sample after minus the sample
before — the result is stable in sign and magnitude class across every window tried:

| isolation | n | mean delta | positive |
|---|---|---|---|
| ±15 min | 87 | +248 MiB | 71 (82%) |
| ±20 min | 52 | +287 MiB | 83% |
| ±30 min | 33 | +370 MiB | 88% |
| ±45 min | 13 | +395 MiB | 92% |
| ±60 min | 9 | +426 MiB | 89% |

The survey's +298 MiB / 84% sits inside this sweep. The single-event effect is real and it is
robust to how "isolated" is defined. PDS-D93's empirical half is superseded in the positive
direction; **its operational conclusion — check-and-go, never pounce — is not**, for the
mechanical reasons D93 gives and which this data does not touch (`DEPLOYED_SHA` is pinned once
at `:562`, step 0b hard-fails at `:661`, and cond_d kills the pounce independently).

### 3b. Aggregate level: deploy density ANTI-correlates with clearing

| granularity | survey | re-derived, corrected 07/12 |
|---|---|---|
| daily (n=7) | r = −0.59 | **r = −0.38** |
| hourly (n=168) | r = −0.21 | **r = −0.14** |

**A correction this record is obliged to make: the survey's own correlation figures are
partly the §1b truncation artefact.** Recomputing with 07/12's truncated deploy count (3
instead of 31) reproduces the survey's numbers **exactly** — daily −0.59, hourly −0.21 — which
identifies the artefact as their source and not as a coincidence. On the corrected data the
correlations are −0.38 and −0.14. Still negative; materially weaker than the wave Paper
states. Quote the corrected pair.

### 3c. The two directions are not a contradiction — they are a Simpson's-paradox confound

Both facts stand. A deploy raises MemAvailable at the moment it lands (§3a). Days and hours
with *more* deploys clear *less* (§3b). The reconciliation is that **deploy count is also a
proxy for general busyness**: the box deploys more on days when more is happening on it, and
whatever else is happening consumes more memory than the deploys free. §4 identifies at least
one concrete channel by which that happens. The per-day table makes the confound visible
directly — 07/16 and 07/17 carry 65 and 41 restarts and are two of the three worst days.

**The naive claim "more deploys means more clearing, so drive deploys up before firing" is
REFUSED.** The aggregate correlation runs the other way; the single-event effect is a
within-event freshening that says nothing about what to do with the aggregate; and acting on
either reading by timing a fire to a deploy is separately forbidden by PDS-D93 on mechanical
grounds that no amount of new correlation data can reach.

---

## 4. THE CONTENTION CHANNEL — a sibling cgroup nobody had modelled

The epic's memory model accounted for BEAM growth plus steady-state services. It did not
account for the box's own site-build pipeline.

**Survey measurement, quoted; not re-run** (two independent 90-second steps):

> A running `bp-site-build-*` systemd unit depressed MemAvailable by **379 MiB** and by
> **496 MiB** in two independent 90-second steps, while beam `VmSwap` stayed **flat at
> ~36 MB** and beam RSS **fell**.

Those two controls are what make the reading load-bearing. A flat VmSwap rules out paging as
the explanation; a *falling* BEAM RSS rules out BEAM growth. The memory went somewhere the
BEAM is not — a **sibling systemd cgroup**. Builds recurred roughly every four minutes.
Because the sampling cadence was 90 seconds and the builds are shorter-lived than that, **379
and 496 MiB are lower bounds**, exactly as PDS-D114 rules for the 1 Hz export peak.

### 4a. Week-scale corroboration — re-derived here

The survey caught the channel in two steps. The week's data shows it at scale, and this is
the first time the finding has been checked against anything other than its own two samples.

`Started bp-site-build-*` across the week: **2228 units**, and they are **not spread across
the week** — every one of them falls on 07/17 (1149) and 07/18 (1079). Those are two of the
three worst clearing days in §1a (60.8% and 65.7%), and 07/18 owns the week's global minimum
of 991 MiB.

Scoring each sar sample by whether any build started in the preceding 10 minutes:

| sample class | n | clear rate | median MiB |
|---|---|---|---|
| build-adjacent | 224 | **58.0%** | 2326 |
| quiet | 777 | **85.1%** | 2567 |

A 27-point clearing gap and a 241 MiB median gap, on the same box in the same week.

**Freshness is controlled.** Restricting to samples that are build-adjacent *and* taken on a
BEAM less than 30 minutes old — i.e. exactly the "otherwise-fresh BEAM" case the epic has been
recording as *unexplained* cond_b misses — **41 samples fall below the 2235.43 MiB demand**.
The most extreme, with BEAM age in minutes and build starts in the preceding 10 minutes:

```
2026-07-17 23:50:00  memavail=1385 MiB  BEAM age=0.0  builds started in prior 10min=17
2026-07-18 02:10:00  memavail= 991 MiB  BEAM age=0.9  builds started in prior 10min=25
2026-07-17 04:30:00  memavail=1528 MiB  BEAM age=0.8  builds started in prior 10min=19
2026-07-17 07:10:05  memavail=1725 MiB  BEAM age=0.1  builds started in prior 10min=13
```

A BEAM 54 seconds old sitting at 991 MiB is not BEAM-uptime decay. **Some fraction of this
epic's "unexplained" cond_b misses were site-build contention on a perfectly fresh BEAM.**

Honest limit on that leg: `sar` samples every 10 minutes and the journal records build
*starts*, so "build-adjacent" is a proxy for "a build was running at the sample instant" and
not a direct observation of it. With 13–25 starts in each preceding 10-minute bucket the
proxy is a safe one, but it is a proxy, and the 27-point gap is an association at week scale
rather than the causal 90-second step the survey measured. The two legs are complementary:
the survey has the mechanism, this has the scale.

**Operational consequence:** MemAvailable alone cannot see this channel arriving, and neither
can VmSwap. A fire predicate needs an explicit `systemctl list-units 'bp-site-build-*'
--state=running` stand-down leg. It is not a reclaim lever — these are real builds doing real
work, and there is nothing to free. It is purely a do-not-fire-now signal.

---

## 5. THE RESIDUAL — what this data cannot close

Everything above measures the *probability that the window is open*. None of it measures the
*probability that the window stays open*, and that is the quantity the fire actually depends
on.

**cond_b is a single instantaneous read. The export then runs 130 seconds.** Combine that
with §2: MemAvailable oscillates by ~550 MB within one BEAM epoch. So a fire taken at a
measured 2586 MB can meet a 2036 MB trough mid-export, and the read that authorised it will
have been perfectly accurate at the instant it was taken.

**No floor value prevents this.** Raising the threshold raises the *starting* point of the
walk; it does not constrain the walk. The trough in §4 arrives from a sibling cgroup on a
four-minute recurrence that the authorising read cannot see coming, and §1's own week
contains a 130-minute continuous FAIL streak that necessarily began at a sample which had
just cleared.

This is the one thing wave 10 must not claim to have solved. The honest positions the data
does support:

1. The window is the majority state (79.0%), so polling for it is nearly free and a miss
   costs no export attempt (PDS-D92).
2. A stand-down leg on running site-builds removes the single largest *identified* source of
   mid-window collapse (§4).
3. The residual after both is a real, unquantified probability of a mid-export trough, and it
   is a reason to expect an eventual miss — **not** a reason to treat the window as a lottery,
   which is the premise this record retires.

---

## Cross-references

- **PDS-D185** — the 2235.43 MiB demand every figure here is scored against.
- **PDS-D190** — the window is the box's majority state; this file is its dataset.
- **PDS-D191** — PDS-D93 amended, not repealed; §3 is the amendment's evidence.
- **PDS-D92** — check-and-go on a ~10-minute cadence; §1's streak figures are its margin.
- **PDS-D114** — the lower-bound rule §4's step figures inherit.
- `task-6fc6820c62e9b646` — the site-build contention finding, filed unevidenced in wave 10
  and first corroborated by §4 of this file.
