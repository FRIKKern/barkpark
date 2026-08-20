# stw10-backlog-flagship-health-pool — PROVEN false-done (crit-2 under-load evidence failure)

Audit: search-template done-set false-done audit (wave 2026-08-18-audit), assignment V1-flagship-health-pool-ruling.
Verdict: **PROVEN false-done → reopened via `bp task stage ... open` (claim preserved).** False-done count on this row = 1.

## The row
- `stw10-backlog-flagship-health-pool`, p0, lifecycle_status=done, criteria_progress 3/3.
- Closed 2026-07-27T17:40:53Z by `w10-lead` (epoch 1). updated_at 2026-07-27T17:41:25Z — **never reopened/re-closed since** (so the current DONE is the original warm-read close, not a re-verified one).
- Re-run: `bp task get stw10-backlog-flagship-health-pool -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'],d['claim']['closed_by'],d['claim']['closed_at'],d['updated_at'])"`

## The proof (audit-provable, no control-plane read needed)
1. **crit-2 text demands an UNDER-LOAD probe; stamped evidence is a quiet serial baseline.**
   - crit-2: "The pool-exhaustion cause is directly proven (token-carrying /v1/graph probe **under load**) rather than inferred from journal correlation."
   - crit-2 evidence: "MEASURED NOW: GET /v1/graph returns 200 in **3.01s / 2.54s / 3.56s across three consecutive reads**" + "No pool-size change was needed or made." → three SERIAL warm reads, not concurrent load. Modality mismatch on the criterion's own face.
2. **#6284 does NOT structurally eliminate the pool/contention mechanism — so the under-load probe was NOT moot.** The only defense that could save the close (fix kills the mechanism → probe unnecessary) is refuted by the reconcile wave's OWN measurement:
   - Charter D85(b), origin/main: "`/v1/graph` is 2.7–5.2s serial warm and **~21.5s each for six concurrent requests** ... #6284 removed the N+1, it did **not** make the route concurrent, so six simultaneous visitors ... each wait ~21s and any ... HEALTH probe sized against '3s' **fails the moment two people load the site**." The exact "3s" number crit-2 relied on is the one D85 says "nobody may quote loosely again."
   - Re-run: `git grep -n "make the route concurrent" origin/main -- .claude/workflows/bp-search-template-charter.md`
3. **#6284 is real and merged** (07-26T20:16Z, mergeCommit 68b844c556, ancestor of origin/main) — so this is an OVER-CLAIM, not a fabrication. The row has a full claim, rich evidence, real work. The fabrication shape (null-claim + boilerplate + 0/N + zero evidence) does NOT apply. This is the `stamped-evidence-can-overstate` pattern: crit-2 marked met=true on evidence that does not discharge it.
   - Re-run: `gh pr view 6284 --repo FRIKKern/barkpark --json mergeCommit,mergedAt,state` ; `git merge-base --is-ancestor 68b844c556e196d272ae1722e87311eb6e83e61a origin/main && echo YES`

## Corroboration I could NOT independently retrieve (L3, not L1)
- D82 asserts "four live deploy runs on 2026-07-28 failed that exact gate (HEALTH status=failed … 'bp-doc-id marker is empty', on both flagships)." The four run records live on the control plane; `bp cloud site status search-ember` → `unauthorized`. I corroborate the MECHANISM (fact 2, D85's under-load measurement) but cannot pull the run records. The reopen does NOT rest on these four runs.

## Why reopen (not just a correction note), and how it honors D92
- D92 refused D82's reopen on jurisdiction: "a fresh live probe is the lead's, not a build." That is a category error: the row being DONE asserts crit-2 IS proven, yet D92 concedes the live under-load probe is still owed. A criterion whose proof is admittedly outstanding is not met. Reopening (done→open, **claim kept**) routes the owed under-load live deploy run back to the lead — it does not usurp the lead's live probe; it corrects leaving the row marked done while the proof is outstanding.
- W12 internally contradicts itself: D92 says "refuted, fine" while D85(b) (same decision set) measures the under-load collapse still present. The measured fact (D85) governs the judgment call (D92). The audit is the independent second eye W12 structurally cannot be.

## Denominator (re-pinned live, zero drift)
72 done / 38 open / 6 considering / 1 cancelled of 117 children.
Re-run: `bp task get search-template-epic-goal -o json | python3 -c "import sys,json;from collections import Counter;print(dict(Counter(k['lifecycle_status'] for k in json.load(sys.stdin)['children'])))"`
