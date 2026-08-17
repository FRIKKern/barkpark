# felix-w27 · Sobelow classification + required-4 snapshot (2026-08-17)

Verifier assignment [sobelow-classify]. Re-derivation recipes for each load-bearing fact.

## Sobelow red on #12037 / #12042 is STALE-BASELINE line-shift, NOT a real new finding

Both PRs emit the IDENTICAL 6 findings, all `Config.CSRF: Missing CSRF Protections -
High Confidence` in `lib/barkpark_web/router.ex` (pipelines: media_mutate L646,
user_auth L577, session_token_root L553, scoped_media_mutate L288, shared_media_api
L229, sso_browser L131). Neither PR touches router.ex (#12037 = dataset-slug regex,
#12042 = release_capture bounds). A dataset-slug diff and a release_capture diff
producing the same router CSRF set proves the finding is diff-independent = baseline
fingerprint line-drift (onboarding-w5 added auth pipelines, shifting router.ex lines
off the .sobelow-skips line-keyed baseline).

    # 12037 scan (job id from: gh pr checks 12037)
    gh run view --log-failed --job=95505680736 | grep -c 'Missing CSRF Protections'   # -> 6
    gh run view --log-failed --job=95505680736 | grep 'File:' | grep -v router.ex | sort -u  # -> empty
    # 12042 scan
    gh run view --log-failed --job=95505875052 | grep -c 'Missing CSRF Protections'   # -> 6

## Sobelow CANNOT keep any required gate red

The `sobelow` job (security.yml:221) is `continue-on-error: true` and is DELIBERATELY
EXCLUDED from the `security-gate` aggregator's `needs` (security.yml:459-478 comment:
a continue-on-error red reads as `success` in needs, so aggregating it would launder a
red into green — it is excluded so its own red is the only signal). Sobelow lives in
security.yml, not elixir.yml, so it never feeds the required "Elixir gate" at all.
Required-4 contexts confirmed from branch protection.

    grep -n 'continue-on-error' .github/workflows/security.yml   # sobelow job = the one true
    sed -n '459,478p' .github/workflows/security.yml
    gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.contexts'
    # -> ["Elixir gate","PR references an active task","Cloud gate","Console gate"]

## #12041 has a REAL Elixir-gate failure (independent of sobelow)

    gh pr checks 12041 | grep 'Elixir gate'   # fail
    gh run view --log-failed --job=95506272788 | grep -A6 '1) test'
    # 13900 tests, 1 failure: BarkparkWeb.Studio.ChatRenderGoldenTest
    # "sidebar-scoped byte-lock (wsc charter D11) ... byte-identical to pinned golden"
    # chat_render_golden_test.exs:200 — stale golden snapshot; needs fix-in-place before merge
