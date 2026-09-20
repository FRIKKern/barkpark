# The main-red breaker, measured over THREE windows — and the window the row asked for does not exist

Dated 2026-09-20 (clock: `date -u` 2026-09-20T20:06:33Z at collection start).
Task `task-33682262f429d104`. Tree: `origin/main` e922f67e6cb0af763c75210e1e12ba19370644d1.

Derivation, all of it re-runnable by a stranger:

| file | what it is |
|---|---|
| `breaker-verdict-census-2026-09-20.sh` | the collector — populations, sample, one job log per breaker job |
| `breaker-verdict-tally-2026-09-20.py` | the arithmetic that turns the raw rows into the tables below |
| `breaker-census-population-2026-09-20.tsv` | EXACT per-window population (the list endpoint's own `total_count`) |
| `breaker-census-verdicts-2026-09-20.tsv` | every sampled breaker job: window, workflow, **run id, job id**, conclusion, verdict |
| `breaker-census-recheck-2026-09-20.tsv` | the 36 rows re-read after the collector's 404 defect was found (below) |
| `breaker-selftest-transcripts-2026-09-20.txt` | three consecutive `ci-measure.sh --selftest` runs, one under load |

Re-run: `bash scripts/measurements/breaker-verdict-census-2026-09-20.sh <outdir> 60`
then `python3 scripts/measurements/breaker-verdict-tally-2026-09-20.py <outdir> <outdir>/recheck-out.tsv`.

## THE HEADLINE, before any number

**The row's premise — "one intervention (#16265), contaminated by a second
(#16572)" — undercounts the contamination by six.** `scripts/main-red-breaker.sh`
changed ELEVEN times between its birth and 2026-09-13. **EIGHT of those land
strictly after 9cc549964**; the amendment names exactly one of them (#16572), so
**six are unnamed**. Two of the unnamed ones (#16371, #16384) land INSIDE the
between-window the amendment proposes to measure, and four (#16908, #16928,
#16943, #16976) land inside any 3-full-day AFTER window that starts on 09-07.

UTC commit times, `git log --date=iso-local` with `TZ=UTC`, on `scripts/main-red-breaker.sh`:

| when (UTC) | sha | PR | note |
|---|---|---|---|
| 2026-09-03T05:26:01Z | 3d30f14f1 | #15740 | the breaker is BORN |
| 2026-09-03T17:54:36Z | b07c410fd | #15842 | |
| 2026-09-03T18:36:35Z | 8527591cf | #15854 | **W1's code state** |
| 2026-09-06T00:21:33Z | 9cc549964 | #16265 | the row's intervention — **W1/W2 boundary** |
| 2026-09-06T09:01:05Z | 92ef3586e | #16371 | **INSIDE the between-window — the amendment does not name it** |
| 2026-09-06T09:34:03Z | e96934ec0 | #16384 | **INSIDE the between-window — the amendment does not name it** |
| 2026-09-06T19:43:20Z | ad80d3bce | #16572 | the amendment's second intervention — **W2/W3 boundary** |
| 2026-09-08T04:20:26Z | 9d7fa3ad2 | #16908 | inside any AFTER window starting 09-07 |
| 2026-09-08T05:01:23Z | c556a826a | #16928 | " |
| 2026-09-08T05:44:58Z | bb8a1c73e | #16943 | " |
| 2026-09-08T07:52:07Z | e5ef630bc | #16976 | **W3's code state** — last change before 09-13 |
| 2026-09-13T13:26:47Z | 53af54f9d | #18161 | closes W3's clean run |

Two consequences the row does not anticipate:

1. **There is no 3-full-day BEFORE window.** The breaker was born
   2026-09-03T05:26Z and changed twice more the same day. Only 09-04 and 09-05
   are pre-9cc days with a stable breaker — **TWO full days, not three.** W1 is
   reported as two days and labelled so. The criterion's "at least 3 FULL days"
   is not satisfiable on the BEFORE side without measuring a breaker that
   changed underneath the window.
2. **The first clean 3-full-day AFTER window is 09-09..09-11**, not 09-07..09-09.
   The four 09-08 commits rule out anything earlier. W3 is that window, and it
   contains zero commits to `main-red-breaker.sh`.

## The three windows

| | window (UTC) | full days | breaker code inside | commits to the breaker inside |
|---|---|---|---|---|
| **W1 BEFORE** | 2026-09-04T00:00:00Z .. 2026-09-05T23:59:59Z | 2 | 8527591cf (#15854) | 0 |
| **W2 BETWEEN** | 2026-09-06T00:21:33Z .. 2026-09-06T19:43:20Z | **0 — 19h21m47s, PARTIAL DAY** | 9cc549964 → e96934ec0 | **2 (#16371, #16384)** |
| **W3 AFTER** | 2026-09-09T00:00:00Z .. 2026-09-11T23:59:59Z | 3 | e5ef630bc (#16976) | 0 |

This is the amendment's option **(b)**, three windows — with **(c)** applied to
W2's *comparability*, not to its measurement: W2 is measured and its rows are
published, but it is **NOT v-stable** (a fifth of a day, and the breaker changed
twice inside it), so **no rate derived from W2 is comparable with W1 or W3.**
It is shown because it is what #16572 landed into, not because it settles anything.

## The breaker job set GREW between the windows — a second confound

The job list is DERIVED from `.github/workflows` **as they were at each window's
sha**, never typed:

| window | breaker jobs | delta |
|---|---|---|
| W1 (8527591cf) | 8 | — |
| W2 (e96934ec0) | 10 | `required-checks-drift.yml` gained 2 (`Required-check spec gate`, `Head does not silently revert main (stale tree)`) |
| W3 (e5ef630bc) | 10 | — |

So a **per-run** count is not comparable across W1→W2: the same PR meets 25%
more breaker jobs after the growth. Everything below is therefore counted
**per breaker JOB**, and the denominator is printed with every number.

## THE TABLE (c2) — walkable back

Populations are **EXACT**: each is the list endpoint's own `total_count` for
`workflow_runs?event=pull_request&created=<window>`, per workflow, summed. No
window came near the 1000-item pagination cap (largest single workflow: 893).
Verdicts are **SAMPLED and therefore ESTIMATED**; the sample is systematic
(evenly spaced by `created_at`), never the head of the list.

| window | PR runs (EXACT) | runs sampled | **breaker job logs read** | sampling fraction |
|---|---|---|---|---|
| W1 | 1104 | 60 | **108** | 5.4% |
| W2 | 1080 | 60 | **107** | 5.6% |
| W3 | 3631 | 60 | **106** | 1.7% |

Every one of the 321 sampled jobs is in
`breaker-census-verdicts-2026-09-20.tsv` with its run id and job id. The 44
non-green verdicts (post-correction), which are the rows that carry the whole
finding, are listed individually in `breaker-census-verdicts-*.tsv` and
`breaker-census-recheck-*.tsv`, and each can be re-read with
`gh api repos/FRIKKern/barkpark/actions/jobs/<job_id>/logs`.

## THE DECOMPOSITION (c3)

Counts are of breaker JOBS in the sample, after the recheck correction below.

| verdict | W1 BEFORE | W2 BETWEEN | W3 AFTER |
|---|---|---|---|
| INHERITED-FROM-MAIN | 20 | 8 | 7 |
| **OWNERSHIP-UNDETERMINED** | **0** | **2** | **1** |
| this-PR's-own (`FAIL`) | 4 | 1 | 1 |
| RUNNER-LOCAL | 0 | 0 | 0 |
| **reds that reached a verdict** | **24** | **11** | **9** |
| — of which "cannot tell" | **0.0%** | 18.2% | **11.1%** |
| green, no red at all | 27 | 35 | 21 |
| never ran (skipped/cancelled) | 57 | 60 | 76 |

### The W1 zero is a PRECONDITION, not an observation

This is the one number here that needs no sample at all. Counting the literal
`OWNERSHIP-UNDETERMINED` in the breaker source at each window's sha, with a
control string that must be present in all five:

```
8527591cf  OWNERSHIP-UNDETERMINED=0   MAIN-FAILED-STEP=0     <- W1's code
9cc549964  OWNERSHIP-UNDETERMINED=2   MAIN-FAILED-STEP=3
e96934ec0  OWNERSHIP-UNDETERMINED=2   MAIN-FAILED-STEP=3     <- W2's code
ad80d3bce  OWNERSHIP-UNDETERMINED=4   MAIN-FAILED-STEP=3
e5ef630bc  OWNERSHIP-UNDETERMINED=4   MAIN-FAILED-STEP=3     <- W3's code
control: INHERITED-FROM-MAIN = 2,3,3,3,3 — present at all five, so the read works
```

In W1 the verdict **could not be emitted**. Every red that reached a verdict in
W1 was therefore assigned a DEFINITE blame — 20 to main, 4 to the PR — including
whichever of them the breaker would today decline to judge. That is the shape
the row wanted named: not "reds went down", but "reds stopped being blamed
when the evidence did not support a blame".

### How many reds moved from a wrong blame to an honest cannot-tell

**Measured: 1 of 9 verdict-reaching reds in W3 (11.1%), against a structural 0 of
24 in W1.** Scaled onto W1's own sampled red population, ~2.7 of its 24 reds
carried a blame the current breaker would refuse to make.

**And here is what that number will NOT support.** It rests on **one** observed
OWNERSHIP-UNDETERMINED in W3 and **two** in W2. A one-observation rate has a 95%
interval running roughly 0.3%–48%; it does not pin 11% to one significant figure
and nobody should quote it as if it did. What the sample DOES establish, at full
strength, is the **direction and the structure**: the cannot-tell verdict is
impossible before (proved from source, not sampled) and observed after
(`run=34562779297 job=103148742523`, and W2's `run=34036718204
job=101496016257`, `run=34048702712 job=101528299650`). **A rate this thin is
the honest answer to a question asked of a rare event, and it is why the
"reds per day went down" framing was never the right one:** the INHERITED share
of verdict-reaching reds is 83% / 73% / 78% across the three windows — flat.
The breaker did not neutralise more reds. It stopped mis-blaming a slice of them.

## UNMEASURED, and why

- **W2 as a comparable rate.** Measured and published, never compared. 19h21m47s
  is not a day, and the breaker changed twice inside it (#16371, #16384).
- **A per-day series within any window.** The sample is 60 runs per WINDOW; split
  three ways it would be ~20 runs a day and every daily cell would rest on zero
  or one observation.
- **A BEFORE window of 3 full days.** It does not exist. See the headline.
- **The four 09-08 commits' individual effect.** They are bundled into W3's
  code state; separating them would need four more windows, each shorter than a
  day.
- **Anything after 2026-09-13T13:26Z (#18161).** Out of scope; W3 deliberately
  ends before it.
- **A verdict decomposition from `ci-measure.sh --breaker` itself.** It cannot
  produce one — see below. Every number here comes from re-reading the same job
  logs that mode reads, with the five sentence openings the breaker actually emits.

## Why this packet does not use `ci-measure.sh --breaker`

`breaker_verdict()` is two-valued:

```sh
breaker_verdict() {
  if grep -q 'main-red-breaker: INHERITED-FROM-MAIN' ; then
    echo INHERITED-FROM-MAIN
  else
    echo NONE
  fi
}
```

`NONE` is the else branch — the same value a green job, a skipped job, an
unreadable log and an OWNERSHIP-UNDETERMINED red all receive — and
`breaker_report` drops every non-INHERITED row. **The three-way split c3 asks
for is structurally zero in that instrument at every window, in every direction.**
The prior attempt on this row recorded exactly this and deferred; the deferral
was correct about the instrument and wrong about the remedy, because the
verdicts are all in the job logs already and reading them needs no change to
`ci-measure.sh`. Nothing in `ci-measure.sh` was modified by this packet.

The five sentence openings, verified against `scripts/main-red-breaker.sh`
(`say()` at :330, and :362, :463, :757-759, :1138, :1245, :1417, :475):

```
main-red-breaker: INHERITED-FROM-MAIN —      neutralised, exit 0
main-red-breaker: OWNERSHIP-UNDETERMINED —   honest cannot-tell, exit 1
main-red-breaker: FAIL —                     this PR's own, exit 1
main-red-breaker: RUNNER-LOCAL —             the host's, neither
main-red-breaker: no gate step failed in     green, no verdict reached
```

## The collector's own defect, found and corrected mid-measurement

The first census pass reported `NO-BREAKER-OUTPUT` for two jobs that in fact
carried a `main-red-breaker: FAIL` sentence
(`job=101331128998`, `job=101448616312`). Cause: a job whose log does not exist —
a SKIPPED job, or a transient fetch failure — returns a **215-byte
`BlobNotFound` XML document on stdout**, not an empty string, so the collector's
`[ -z "$log" ]` guard let it through and it fell to the final else.

This was caught by reading the SOURCE log of a row the tally had already
bucketed, not by reading the tally. The collector now retries three times and
refuses any body under 1000 bytes as `NO-LOG`.

**The error is one-directional and the correction is a floor.** A positive
verdict requires its sentence to be literally present, so INHERITED /
OWNERSHIP-UNDETERMINED / FAIL / green can only ever be UNDER-counted by this
fault, never over-counted. All 36 non-skipped `NO-BREAKER-OUTPUT` rows were
re-read with retries; **12 of the 36 changed, every one of them upward**, and
24 were confirmed unchanged:

| correction | W1 | W2 | W3 |
|---|---|---|---|
| → INHERITED-FROM-MAIN | 2 | 0 | 0 |
| → this-PR's-own | 1 | 1 | 0 |
| → green | 4 | 1 | 3 |
| still no log (skipped/cancelled) | 4 | 1 | 19 |

The tables above are all POST-correction. The pre-correction rows are kept in
`breaker-census-verdicts-2026-09-20.tsv` beside the corrected ones in
`breaker-census-recheck-2026-09-20.tsv`, so the correction itself is walkable back.

## The instrument is quotable (c0)

`bash scripts/ci-measure.sh --selftest` on e922f67e6, three consecutive
invocations, full transcripts in `breaker-selftest-transcripts-2026-09-20.txt`:

| run | condition | result | rc |
|---|---|---|---|
| 1 | plain | `SELFTEST: 43 passed, 0 failed.` | 0 |
| 2 | plain | `SELFTEST: 43 passed, 0 failed.` | 0 |
| 3 | **8x `yes >/dev/null`, load avg 84.11** | `SELFTEST: 43 passed, 0 failed.` | 0 |

Arm **b7** — the `printf | grep -q` SIGPIPE arm the row was worried about — is
`ok` in all three, including under load. No exit 141 anywhere.

**43 is not 27.** The criterion's text names 27/27 and names
`task-d54d93ff95d44db9` as "closed"; that row is **CANCELLED**. The instrument
grew arms since the criterion was written — the `b*` breaker family and the `j*`
job-latency family are both in the 43. 27 is **stale wording, not a failing
instrument**: what c0 actually demands is that the selftest print its FULL pass
count deterministically, on three consecutive runs, one under load, with b7
sound — and it does.
