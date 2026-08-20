<!-- doc-tier: cold | canonical-for: onb-w7-c2-provenance-doctor | budget: 400tok -->
# onb-w7 C2 provenance — doctor.sh §1b guard commit (2026-08-18)

Re-derivation recipes for the wave-7 C2 stamp (guard-existence-plus-green-§1b-verdict).

## Fresh §1b green line (C2 verdict evidence)
    bash scripts/doctor.sh 2>&1 | grep -iE 'release cadence'
    # → ✓ release cadence current (cli-v1.17.0: 174 commit(s) / 3d behind main)

## The REAL §1b guard commit is f71b1444cb (cite this)
    git show f71b1444cb --stat --format='%s' | grep -E 'doctor.sh|%'
    # → fix(cli): reject malformed stable release tags ; scripts/doctor.sh | 40 +++++++++
    git blame -L 39,39 scripts/doctor.sh
    # → f71b1444cb4 ... # ── 1b. Release cadence — has releases/latest drifted behind main?

## 1928df610e is a PHANTOM (never cite for §1b)
    git show 1928df610e --stat --format='%s' | grep -E 'doctor.sh|caddy'
    # → feat(setup): inject cloud URL during provision ; internal/cli/setup/caddy.go
    # touches ONLY setup/caddy.go(+test); does NOT modify scripts/doctor.sh

## Honest C2 wording
GUARD-EXISTENCE-PLUS-GREEN-§1b-VERDICT: the doctor.sh §1b release-cadence
guard EXISTS (added by f71b1444cb, +40 lines) and RETURNS GREEN live.
Never "zero drift" (it reports 174 commits / 3d behind — green means
within-threshold, not zero). Never cite 1928df610e.
