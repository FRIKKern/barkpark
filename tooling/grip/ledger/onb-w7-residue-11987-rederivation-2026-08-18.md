<!-- doc-tier: cold | canonical-for: onb-w7-residue-11987-rederivation | budget: 900tok -->

# onb wave-7 residue + #11987 close — re-derivation recipes (2026-08-18)

Verifier V8-close-residue-11987. Each disposition below is recorded-reason (met stays false), never a met-flip. Re-run any row to re-derive.

## #11987 — close UNMERGED (superseded wave-4 charter, CONFLICTING)

- OPEN + CONFLICTING, head 8ef508e2:
  `gh pr view 11987 --json state,mergeable,headRefOid`
- head NOT on main:
  `git merge-base --is-ancestor 8ef508e2fade219a394fd4a260dcfa349491d6ea origin/main && echo MERGED || echo UNMERGED`  → UNMERGED
- 7 scratch ledger notes ABSENT on main, and UNREFERENCED:
  loop `git cat-file -e origin/main:tooling/grip/ledger/<name>-2026-08-17.md` over the 7 → all absent;
  `git grep -l -iE 'onb-alias-prune-and-rebuild|onb-comp-fence-recheck|onb-go-gate-and-freshness|onb-live-fleet-probes|onb-signup-postcommit-shape|onb-w4-ledger-dedup|onb-w4-local-controlplane-identity-journey' origin/main` → empty
- Charter lines: 26 of 27 non-empty added lines verbatim on main (D23-D32 superseded). NUANCE: the ONE line not on main is the "**Wave 4 (2026-08-17 …)**" wave-log narrative paragraph — a per-wave log entry, NOT a decision; D43 handles wave-log dead-lines separately. So "all 33 charter lines verbatim on main" is slightly overstated: every DECISION is present; only the wave-4 log paragraph is unique to the PR and safe to drop.
  Re-derive: extract PR charter `+` lines, `line in set(open(main_charter))`.

## onboarding-composition-epic-wave-4-log — already done, honest

- `bp task get onboarding-composition-epic-wave-4-log -o json` → lifecycle_status=done, close_override present; criterion[1] 'PR merged (lead closes on merge)' met=false. D43 annotation edits EVIDENCE only, never flips met.

## onb-backlog-relativeage-clock-injection — wont-do close (gate satisfied)

- Gate #12086 (LAST-SEEN) IS on main: `git merge-base --is-ancestor 25d7c27d1c origin/main` → YES (merged as #12086, 25d7c27d1c). So the wont-do close is NOT deferred.
- No relativeage code/PR on main → genuine wont-do (not a merge-close). All criteria met=false; close_override records the wont-do reason, met stays false.

## onb-backlog-release-cache-unify — stays OPEN/enumerated

- `bp task get` → lifecycle_status=open, all 3 criteria met=false. Distinct from #12089 (release-cache-refresh-widening). Stays enumerated backlog.

## onb-backlog-cloud-url-fleet-backfill — 3/5 → 4/5, human gate open

- Currently criteria [0,1,2]=true, [3]=false (MERGE-GATED 'PR merged'), [4]=false (HUMAN GATE).
- Merge-gate satisfiable: PR #12061 (cf07df265f) IS on main — `git merge-base --is-ancestor cf07df26 origin/main` → YES. Flipping criterion[3] to met=true is a LEGITIMATE merge-stamp (real merge), not a tidy-flip. Criterion[4] HUMAN GATE stays met=false, task stays open at 4/5 by design.
