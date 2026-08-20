# spec-drift-check-scope — re-derivation recipes (2026-07-28, origin/main @ ab396959c)

Question: does CI check `Required-check spec drift (advisory)` compare the FULL
spec or only `.protection`? And does felix-w23-s3-amend-d75's "the baseline
floor is 10" collide with a clean regen that emits 6 exclusions?

Answer: **only `.protection`** (plus `repo`/`branch`/`enforced`). The drift job
never regenerates the spec, so the 10→6 exclusions delta cannot red it.
The two "10"s are unrelated: felix's 10 is `api/.sobelow-skips` unannotatable
entries, not `required-checks.json` exclusions.

## Recipes

    # 1. the drift job's ONLY spec-comparison step is verify --ci
    sed -n '/Three-way drift check/,$p' .github/workflows/required-checks-drift.yml

    # 2. verify.sh never reads .exclusions
    grep -c exclusions scripts/required-checks-verify.sh          # => 0

    # 3. clean 2-sha regen; .protection is byte-identical, exclusions 10 vs 6
    ./scripts/required-checks-generate.sh \
      --sha 2053319d3e4bd5618dfc79d0bc6f013d9755a408 \
      --sha cc38bd37bafa3c562ecf50af3a0a34d55ff3fda1 --out /tmp/drift.json
    diff <(jq -S .protection .github/required-checks.json) \
         <(jq -S .protection /tmp/drift.json)                     # => no output
    jq '.exclusions|length' .github/required-checks.json /tmp/drift.json  # 10, 6

    # 4. the only exclusions assertion anywhere in CI (test.sh:293) — regen passes
    jq '[.exclusions[]|select(.reason|startswith("S0"))]|length' /tmp/drift.json  # 0

    # 5. THE REAL TRAP: required-checks.test.sh section 11 self-contradicts once
    #    the committed spec carries enforced=true (FULLMUT becomes SPEC)
    sed -n '513,532p' scripts/required-checks.test.sh
    jq '.enforced=true' /tmp/drift.json > /tmp/a.json
    jq '.enforced=true' /tmp/a.json     > /tmp/b.json
    diff /tmp/a.json /tmp/b.json                                   # => identical

    # 6. baseline: test.sh is green on main today
    bash scripts/required-checks.test.sh | tail -3   # 55 passed, 0 failed

    # 7. felix's "10" is Sobelow, not exclusions
    git show origin/main:docs/ops/merge-gates.md | sed -n '159,190p'
    git log --oneline -1 c608819c6      # docs(merge-gates): amend D75 ... (#6618)
