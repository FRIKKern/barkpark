# Judge calibration — tob-w1-judge-calibration

One-shot dedup audit of the live backlog + calibration of the tier-2 judge,
**before** the matcher gates anything (task-obsession build order, step 2). Run
2026-07-06 against guerrilla (`bp task ls --limit 500`, 365 tasks).

## Method

1. **Mechanical candidate generation** (`gen_candidate_pairs.py`) — deterministic,
   no API, the same shape tier-1 (`tob-w2-match-in-create`) will run in
   `task.create`. Similarity `= 0.7·Jaccard(title+desc tokens) + 0.3·Jaccard(labels)`;
   top-K=3 neighbours per active anchor, deduped. **FTS top-k, not O(n²)** — 114
   active tasks × top-3 = 239 candidate pairs, not ~6,400.
2. **Structural exclusion** — the calibration's central finding (below) folded
   back into the generator: same-parent siblings and parent-chain (milestone⊇step)
   pairs are recorded and **never sent to the judge**.
3. **Judge** — the cross-residue gray zone (sim ≥ 0.30) judged against the frozen
   `judge_prompt.md`, emitting `{relation, confidence, reason}`.

## What the mechanical filter produced

| Bucket | Count | Sent to judge? |
|---|---:|---|
| `structural_sibling` (same parent) | 143 | no — intended epic decomposition (D1) |
| `structural_chain` (milestone ⊇ step / shared ancestor) | 65 | no — `expands`, not duplicate |
| `auto_distinct` (cross, sim < 0.30) | 25 | no |
| `gray_zone` (cross, 0.30 ≤ sim < 0.55) | **6** | **yes** |
| `auto_similar` (cross, sim ≥ 0.55) | 0 | flag for human |

**87 % of lexically-similar pairs (208/239) are benign structure.** Only 6 pairs
warranted the judge.

## Findings

1. **Zero true duplicates in the active backlog.** All 47 pairs at sim ≥ 0.40 —
   and all 6 in the final judge residue — are `distinct` or `expands`. The
   backlog is well-decomposed; there is no accidental same-change-twice task to
   clean up. (Verdicts: `calibration-verdicts.json`.)

2. **Similarity alone is a poor dedup signal — the discriminator is compound.**
   Three benign structures dominate the high-similarity band and MUST be excluded
   before any similarity threshold is applied, or tier-1 would refuse nearly
   every legitimate epic-seeding create:
   - **Same-parent siblings** — one epic decomposed into slices (e.g. all
     `au-w5-*` under `aesthetic-unification-epic`: "author component blocks" vs
     "build the styleguide gallery" — different work, similar words).
   - **Milestone ⊇ step** — a parent task and one of its children (e.g.
     `pdd-m1` ⊇ its done child `pdd-t1-template`): `expands`, never `duplicate`.
   - **Shared-boilerplate batches** — pipeline-mined `loop-low-*` tasks share a
     "Round N backlog" template; the shared text inflates similarity between
     unrelated subjects. Judge on the title's specific subject, not the template.

3. **`drafts.` prefix gotcha** — a task's `parent_id` references the *published*
   id (`pdd-m1`) while a draft doc's own id carries a `drafts.` prefix
   (`drafts.pdd-m1`). Chain detection must normalise the prefix or it silently
   misses every draft's parent link. Fixed in `norm_id()`.

4. **One initiative-level overlap for human review** (below the automated floor,
   surfaced by judgment): `parity-page` and `aesthetic-unification-epic` are two
   OPEN epics both about cross-surface visual consistency. Not a task-level
   duplicate, but the two initiatives may overlap in scope — a human should
   decide whether to merge or explicitly delineate them.

## Calibrated parameters (frozen for tob-w2-llm-judge)

- **Structural exclusion is the primary lever** (removes 87 %): exclude
  same-parent and parent-chain pairs (drafts-normalised) before scoring.
- **Judge floor `lo = 0.30`** on cross pairs (6 pairs here). **Auto-flag `hi = 0.55`**
  (0 here). Below `lo` → auto-distinct, no judge call.
- **Judge prompt** — `judge_prompt.md`, encoding the four relations and the three
  exclusion classes so the judge is robust even if the mechanical filter misses one.

## Spend

No external Anthropic Batch API spend: no API key / `ant` credential is available
in this environment, so the judge residue (6 pairs) was rendered inline by the
session model (claude-fable-5) against the frozen prompt. The Batch API at 50 %
price remains the right mechanism for **tier-2 in production** (`tob-w2-llm-judge`)
once a key is provisioned — the residue is tiny (single-digit pairs per backlog
sweep), so per-run cost there is negligible. Recorded honestly: the calibration
deliverables (verdict set, thresholds, frozen prompt) are complete; the
production judge wiring + key is the follow-on task.

## Reproduce

```bash
bp task ls --limit 500 -o json > /tmp/tob-tasks.json
python3 tooling/task-obsession/gen_candidate_pairs.py \
  --tasks /tmp/tob-tasks.json --out tooling/task-obsession/calibration-pairs.json
```
