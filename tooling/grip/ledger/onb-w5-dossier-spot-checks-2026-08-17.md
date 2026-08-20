# onb-w5 dossier spot-checks — re-derivation recipe (2026-08-17)

Hardens C3's close-by-evidence dossier for the onboarding-composition epic seal.
All commands run from repo root against origin/main + the guerrilla bp server.

## (a) D29 11-ref dossier map — ALL PRESENT

    for pr in 3401 3402 3403 3463 3464 3466 3467 3468; do git log --oneline origin/main | grep -m1 "(#$pr)" || echo "MISSING #$pr"; done
    git merge-base --is-ancestor 1928df610e origin/main && echo 1928df610e-on-main
    git merge-base --is-ancestor f71b1444cb origin/main && echo f71b1444cb-on-main

All 8 PRs resolve; both commits are ancestors.
  - 1928df610e = feat(setup): inject cloud URL during provision (BARKPARK_CLOUD_URL / BP-ONB-04)
  - f71b1444cb = fix(cli): reject malformed stable release tags (release-cadence guard / epic crit 2)

## (b) wave-2/3 papers — NO itemized next-wave residue survives

    bp doc get paper onboarding-composition-wave-2026-07-14 -o json   # Wave 2, 4 blocks
    bp doc get paper onboarding-composition-wave-2026-07-16 -o json   # Wave 3, 4 blocks

Both are compressed "Survey PPCC2-S029" editorial-repaired forms: heading + ingress +
callout + byline only. The "Next action" byline carries NO enumerated items. Residue
lives in backlog TASKS (onb-backlog-*, onb-w1-*), NOT the papers — do not mine the papers
for next-wave items; they were flattened.

## (c) stamp map — only the final merge-gated criterion is unmet in each

    bp doc get task onboarding-composition-epic-wave-4-log -o json
    bp doc get task onb-backlog-isprod-custom-host-write-confirm -o json

wave-4-log: crit[0] met=true (charter PR open+green); crit[1] "PR merged (lead closes on
merge)" met=false, evidence empty → merge-gated.
isprod: crit[0..3] met=true (fail-closed mutation-proven; 3-caller confirm; /v1/meta bool;
gates green); crit[4] "MERGE-GATED (lead closes on merge): PR merged after independent
second review" met=false, evidence empty → merge-gated. No presumed entries.

## (d) doctor release-cadence line — GREEN

    bash scripts/doctor.sh 2>&1 | grep -i 'release cadence'
    #   ✓ release cadence current (cli-v1.17.0: 114 commit(s) / 3d behind main)

## epic criteria state (context)

    bp doc get task onboarding-composition-epic -o json   # 3 criteria, ALL met=false, evidence empty (0/3)
