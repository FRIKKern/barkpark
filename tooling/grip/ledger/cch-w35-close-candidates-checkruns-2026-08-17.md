# W35 close-candidates check-runs — re-derivation recipe (2026-08-17)

Verifier lane `close-candidates-checkruns`. Belt-and-suspenders for 5 close-by-evidence ledger rows.
All 4 PR merge commits are ancestors of origin/main; CI ran on PR HEAD (not the merge SHA).
Required gate set at merge (2026-07-23) predates the 2026-08-03 four-gate set; the load-bearing
required proxies present at merge were `PR references an active task`, `Prod compile gate`, `Test`,
`Typecheck + tests`, and `Cloud shim confinement` — all green on the relevant heads.

## Merge SHAs (all ON origin/main)
    git merge-base --is-ancestor <sha> origin/main   # exit 0 = ancestor
    #5926 merge=58b9394f9982c5b82c9ef188f9913954443ce54e head=18f2ae4bd472542e958f65461eb49fcc560715a8
    #5971 merge=9191a71d3d8d272e9798244b7270077aafa36429 head=d8eba26b733fa3d581834a648ad40e7efae3563f
    #5972 merge=54612facdb7a7e18c63af407d5e206edcc6c385b head=d24fa2e4fa93e433708dfc8f6826bd856ea99cee
    #5937 merge=2c05eff194bfc9429f3e7cb6a5259db534b9a5e9 head=2644b57db0fa4545767892d506d47b57d943682c

## Per-commit check-runs (query HEAD, not merge SHA)
    gh api "repos/{owner}/{repo}/commits/<HEAD_SHA>/check-runs?per_page=100" \
      --jq '.check_runs[] | "\(.name): \(.conclusion)"' | sort -u

Result summary (HEAD SHAs):
- #5926: PR-references-active-task=success, Prod compile=success, Test=success, Typecheck+tests=success,
  Cloud shim confinement=success. FAILS: Format(advisory), Sobelow(regression, waived stale-baseline). Vercel status=failure (not required).
- #5971: PR-references-active-task=success, Prod compile=success, Test=success, Typecheck+tests=success,
  Cloud shim confinement=success. FAILS: Format(advisory) only. No Sobelow failure.
- #5972: PR-references-active-task=success, Prod compile=success, Test=success, CVE audit(blocking)=success.
  FAILS: Format(advisory), Sobelow(regression, waived). reviews=0 (SECURITY: E2 self-declared, merged unreviewed).
- #5937: HEAD check-runs = ONLY "Vercel Preview Comments: success". GitHub-Actions NEVER dispatched.

## #5937 zero-CI-dispatch record (the criterion's literal ask)
    gh api "repos/{owner}/{repo}/commits/2644b57db0fa4545767892d506d47b57d943682c/check-suites?per_page=100" \
      --jq '.total_count, (.check_suites[] | "\(.app.slug) \(.status) \(.conclusion)")'
    # total_count=4 : vercel(completed/success), codemagic-ci-cd(queued), payload-cms(queued), claude(queued)
    # NO github-actions check-suite exists → required Elixir/Cloud/Console gates never ran. Anomaly CONFIRMED.

## vitest v4 major bump
    git show origin/main:connectors/package.json | grep -i vitest
    # "vitest": "^4.1.10"   → 2→4 bump landed. Stale-premise (already merged) CONFIRMED.
