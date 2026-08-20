<!-- doc-tier: cold | canonical-for: onb-w6-release-cache-criteria-vs-d38 | budget: 900tok -->
# onb-w6: release-cache criteria vs D38 — re-derivation recipe

RULING: the task's acceptance_criteria are ALREADY D38-aligned. No criterion
demands plain `bp doctor` (or any offline path) write cli-release-cache.json.
No D39-style pre-build criteria rewrite is owed. Only the TASK TITLE is stale
(cosmetic; does not gate the wall — merge_criteria CAS is on criterion text).

## Re-derive

    # Criteria (verbatim) — criterion 2 explicitly forbids the plain-doctor writer:
    bp task get onb-backlog-release-cache-refresh-widening -o json \
      | python3 -c 'import json,sys;print(json.dumps([c["criterion"] for c in json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"]],indent=2))'
    #  -> criterion[1]: "...plain bp doctor gains no network call (no
    #     latestReleaseVersion/writeReleaseCache reference appears in
    #     doctor_cmd.go, evidenced by grep of the diff)"  == D38, not against it.

    # Stale TITLE (the only stale artifact):
    #  "Widen the release-cache refresh surface: bp upgrade + plain bp doctor also write cli-release-cache.json"
    #  D38 (charter:86) itself flags this: "The task title's 'plain bp doctor writes the cache' is REJECTED".

    git show origin/main:.claude/workflows/bp-onboarding-composition-charter.md | sed -n '86p'

## Builder anchors (origin/main, pinned)

    git show origin/main:internal/cli/update_notice.go | grep -n 'go func\|latestReleaseVersion\|c.Latest\|saveUpdateCache(c)\|ch <- latest'
    #  170 go func()   171 latest,err:=latestReleaseVersion(...)   177 c.Latest=latest
    #  178 saveUpdateCache(c)   179 ch <- latest
    #  INSERT `_ = writeReleaseCache(latest)` inside the goroutine after the successful
    #  resolve, alongside saveUpdateCache(c) at 178 (before 179). D38 anchor "line 171".

    git show origin/main:internal/cli/upgrade.go | grep -n 'func runUpgrade\|latestReleaseVersion(base)\|func writeReleaseCache'
    #  320 writeReleaseCache exists   516 runUpgrade   558 latest,err:=latestReleaseVersion(base)
    #  INSERT `_ = writeReleaseCache(latest)` after the successful resolve at 558.

    git show origin/main:internal/cli/doctor_onboarding.go | sed -n '399,403p'
    #  STALE COMMENT at 399-401: "The doctor is the ONLY surface that pays the network
    #  cost of this resolve" — builder MUST update once upgrade + update-notice also write.
    #  (This is bp doctor --onboarding / onboardingCLIFreshness, NOT plain bp doctor.)

    git show origin/main:internal/cli/doctor_cmd.go | grep -n 'writeReleaseCache\|latestReleaseVersion'
    #  -> (empty). Plain doctor already has ZERO network resolve; criterion 2 pins this.
