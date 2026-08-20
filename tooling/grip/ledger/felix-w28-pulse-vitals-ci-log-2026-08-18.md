# felix-w28 pulse-vitals-ci-log — re-derivation recipe

Claim: the pulse-vitals Elixir red that the digest attributes to "two train PRs"
(#12038 + #12039) is a load-sensitive test-infra flake, and the exact failing
assertion is `assert snap.cursor_per_s > 0` with `left: 0.0` — the 2s-timer
counter-drain race signature. CORRECTION: it hit ONLY #12039's attempt 1.
#12038's attempt-1 red was a DIFFERENT flake (InstanceSiteDeployControllerTest
door-census `observed_in_flight == 0`, another 0→1→0 counter race). Both PRs'
attempt-2 reruns are green; both are MERGED.

## Re-derive

    # both PRs are attempt-2 green; the flake lives in attempt 1
    gh api repos/{owner}/{repo}/actions/runs/32067966446 --jq '.run_attempt,.conclusion'   # PR12038 elixir run: attempt 2, success
    gh api repos/{owner}/{repo}/actions/runs/32068004798 --jq '.run_attempt,.conclusion'   # PR12039 elixir run: attempt 2, success
    gh api repos/{owner}/{repo}/actions/runs/32067966446/attempts/1 --jq .conclusion        # failure
    gh api repos/{owner}/{repo}/actions/runs/32068004798/attempts/1 --jq .conclusion        # failure

    # PR12039 attempt-1 Test job = the pulse flake, exact signature
    gh api repos/{owner}/{repo}/actions/jobs/95506963493/logs | grep -A8 'bumps flow into per-interval rates'
    #   1) test bumps flow into per-interval rates and vitals are sane (Barkpark.Pulse.MetricsTest)
    #      test/barkpark/pulse_metrics_test.exs:31
    #      Assertion with > failed
    #      code:  assert snap.cursor_per_s > 0
    #      left:  0.0
    #      right: 0
    #      test/barkpark/pulse_metrics_test.exs:40: (test)

    # PR12038 attempt-1 Test job = NOT pulse; different flake
    gh api repos/{owner}/{repo}/actions/jobs/95506005198/logs | grep -E '[0-9]\) test '
    #   1) test the door census ... observed_in_flight goes 0 → 1 → 0 ... (BarkparkWeb.InstanceSiteDeployControllerTest)
    gh api repos/{owner}/{repo}/actions/jobs/95506005198/logs | grep -c 'cursor_per_s\|MetricsTest'   # 0

## Verdict

- Failing assertion = `cursor_per_s > 0` (survey's mechanism-derived suspect), NOT
  strikes_per_min and NOT the assert_receive broadcast. left: 0.0 EXACTLY matches
  the globally-supervised sampler's 2s-timer draining the asserted counter.
- Flake, not defect: both reruns green, no code change between attempts.
- Premise correction for Decide: "hit two train PRs" is wrong — #12039 only for
  the pulse assertion; #12038's red is a sibling counter-race flake in a different
  suite. Same conclusion (deflake), but the classification generalizes to a family
  of 0→1→0 in-flight-counter timer races, not one test.
