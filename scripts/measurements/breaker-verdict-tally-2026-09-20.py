#!/usr/bin/env python3
"""breaker-verdict-tally-2026-09-20.py — the arithmetic behind the packet's tables.

Reads the census outdir written by breaker-verdict-census-2026-09-20.sh, applies
the RECHECK corrections (see the packet's "the instrument's own defect" section),
and prints the three-window table plus the verdict decomposition.

A SKIPPED breaker job has NO log: the endpoint returns a 215-byte BlobNotFound
XML body on stdout, which the census's `[ -z "$log" ]` test does not catch, so a
skipped job and a TRANSIENTLY FAILED FETCH landed in the same NO-BREAKER-OUTPUT
bucket. The error is ONE-DIRECTIONAL -- a positive verdict requires its sentence
to be literally present, so INHERITED / OWNERSHIP-UNDETERMINED / FAIL / green
counts can only be UNDER-stated, never over-stated. The recheck re-reads every
NON-SKIPPED NO-BREAKER-OUTPUT row with retries and is a strict correction upward.

usage: python3 breaker-verdict-tally-2026-09-20.py <census-outdir> <recheck-out.tsv>
"""
import sys, collections

census, recheck = sys.argv[1], sys.argv[2]
fix = {}
for line in open(recheck):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 8: fix[p[3]] = p[7]          # job_id -> corrected verdict

rows = []
for line in open(census + "/verdicts.tsv"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 7: continue
    win, wf, run, jid, jname, concl, v = p[:7]
    rows.append((win, wf, run, jid, jname, concl, fix.get(jid, v)))

pop = collections.Counter()
for line in open(census + "/population.tsv"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 5 and p[4].isdigit(): pop[p[0]] += int(p[4])

sampled = collections.Counter()
for line in open(census + "/sample.tsv"):
    p = line.rstrip("\n").split("\t")
    if p and p[0]: sampled[p[0]] += 1

V = ("INHERITED-FROM-MAIN", "OWNERSHIP-UNDETERMINED", "THIS-PRS-OWN",
     "RUNNER-LOCAL", "GREEN-NO-VERDICT", "NO-BREAKER-OUTPUT", "LOG-UNREADABLE")
by = collections.defaultdict(collections.Counter)
never_ran = collections.Counter()
for win, wf, run, jid, jname, concl, v in rows:
    by[win][v] += 1
    if v == "NO-BREAKER-OUTPUT" and concl in ("skipped", "cancelled"): never_ran[win] += 1

LABEL = {"W1": "W1 BEFORE  2026-09-04..09-05 (pre-9cc549964)",
         "W2": "W2 BETWEEN 2026-09-06T00:21:33Z..19:43:20Z (PARTIAL DAY)",
         "W3": "W3 AFTER   2026-09-09..09-11 (post-ad80d3bce, no breaker commit inside)"}

print("== POPULATION AND SAMPLE (population EXACT from the list endpoint's total_count) ==")
print(f"{'window':<62}{'PR runs':>9}{'sampled':>9}{'job logs':>9}")
for w in ("W1", "W2", "W3"):
    print(f"{LABEL[w]:<62}{pop[w]:>9}{sampled[w]:>9}{sum(by[w].values()):>9}")

print("\n== VERDICT DECOMPOSITION (SAMPLED; counts are of breaker JOBS, not runs) ==")
print(f"{'verdict':<26}" + "".join(f"{w:>10}" for w in ("W1", "W2", "W3")))
for v in V:
    print(f"{v:<26}" + "".join(f"{by[w][v]:>10}" for w in ("W1", "W2", "W3")))

print("\n== THE NUMBER c3 ASKS FOR: reds that reached a verdict, split three ways ==")
print(f"{'':<26}" + "".join(f"{w:>10}" for w in ("W1", "W2", "W3")))
red = {}
for w in ("W1", "W2", "W3"):
    red[w] = by[w]["INHERITED-FROM-MAIN"] + by[w]["OWNERSHIP-UNDETERMINED"] + by[w]["THIS-PRS-OWN"] + by[w]["RUNNER-LOCAL"]
for v in ("INHERITED-FROM-MAIN", "OWNERSHIP-UNDETERMINED", "THIS-PRS-OWN", "RUNNER-LOCAL"):
    print(f"{v:<26}" + "".join(f"{by[w][v]:>10}" for w in ("W1", "W2", "W3")))
print(f"{'TOTAL reds with a verdict':<26}" + "".join(f"{red[w]:>10}" for w in ("W1", "W2", "W3")))
print(f"{'  of which cannot-tell %':<26}" + "".join(
    (f"{100.0*by[w]['OWNERSHIP-UNDETERMINED']/red[w]:>9.1f}%" if red[w] else f"{'n/a':>10}")
    for w in ("W1", "W2", "W3")))
print(f"{'  green (no red at all)':<26}" + "".join(f"{by[w]['GREEN-NO-VERDICT']:>10}" for w in ("W1", "W2", "W3")))
print(f"{'  never ran (skip/cancel)':<26}" + "".join(f"{never_ran[w]:>10}" for w in ("W1", "W2", "W3")))
