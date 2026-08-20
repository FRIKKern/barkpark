# onb-w6 residue disposition — re-derivation recipes (2026-08-18)

Verifier: verify-residue-disposition (wave 6, onboarding-composition-epic).
Every load-bearing fact behind the five close rulings, with the command that re-derives it.

## 1. #11987 supersession proof (wave-4-log ruling)

- PR state OPEN + CONFLICTING, docs-only (charter + 7 grip-ledger notes):
  `gh pr view 11987 --json state,mergeable,files`
- Every charter line on its branch is verbatim on origin/main (0 missing):
  ```
  git fetch origin epic-charter/onboarding-composition-epic-20260817T194811Z
  git diff origin/main...FETCH_HEAD -- .claude/workflows/bp-onboarding-composition-charter.md \
    | grep '^+' | grep -v '^+++' | sed 's/^+//' | while IFS= read -r l; do
      git show origin/main:.claude/workflows/bp-onboarding-composition-charter.md | grep -qxF "$l" || echo "MISSING: $l"; done
  ```
  Result 2026-08-18: zero MISSING lines (33 branch-added charter lines all on main;
  wave-4 log = main charter line 164; D23-D42 present).
- Branch-unique content = exactly 7 tooling/grip/ledger/onb-* notes (verifier scratch):
  `git diff --name-only origin/main...FETCH_HEAD` — only the charter file is ON main.

## 2. Task states at ruling time

- wave-4-log: done 1/2 with close_override listing unmet index 1 ("PR merged"):
  `bp task get onboarding-composition-epic-wave-4-log -o json` (close_override.criteria.unmet)
- backfill: in_progress 3/5; unmet = MERGE-GATED (now stampable, #12061 merged cf07df26)
  + HUMAN GATE (SSH backfill + gyldendal redeploy):
  `bp task get onb-backlog-cloud-url-fleet-backfill -o json`
- relativeage-clock-injection / release-cache-unify: both open 0/3, P4, unclaimed:
  `bp task get onb-backlog-relativeage-clock-injection -o json`
  `bp task get onb-backlog-release-cache-unify -o json`
- residue umbrella done 3/3 with 6 open/considering children (onb16..22):
  `bp task get onb-backlog-authoring-audit-residue -o json`
- epic 0/3, unclaimed, 32 children; wave-1 set = the eight onb-w1-* ids:
  `bp task get onboarding-composition-epic -o json`
- fleet-health-decompose open 2/6 — both met stamps SELF-ANNOTATED "STALE — do not count"
  (stranded-build stamps; met-ratchet practice = annotate, never clear):
  `bp task get onb-w1-fleet-health-decompose -o json`
- wave-5-log precedent: clean 2/2, its charter PR #12044 MERGED (7883e8d697):
  `bp task get onboarding-composition-epic-wave-5-log -o json`

## 3. Merge shas quoted in the C3 stamp draft

- #12035 MERGED 15056195cda2557f91c74e41c66b0f566c74dad4: `gh pr view 12035 --json state,mergeCommit`
- #12029 MERGED df589ddf58a573a06890ad1d23937b06011fd0f5: `gh pr view 12029 --json state,mergeCommit`
