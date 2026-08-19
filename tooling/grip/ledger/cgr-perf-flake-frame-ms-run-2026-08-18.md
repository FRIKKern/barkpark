# Re-derivation: sheets-presence perf-flake frame_ms (Cloud GUI remake reconcile wave)

Wave: cloud-gui-remake-wave-2026-08-18 · Verifier assignment: [perf-flake-run]
origin/main pinned at `f532028339efaae3867f2d74c533187e573457b4`

## Claim

The perf-budget flake is `assert frame_ms < 10` at
`api/test/barkpark_web/live/studio/studio_live_sheet_presence_test.exs:321`
(test "MEASURE:" begins at line 257) — NOT `api/test/bench/validation_perf_test.exs`
(which asserts SHAPE, e.g. `length(scalar_keys) == 200`, never timing). Below-bar:
its only failure mode is false-RED under host load, never a false-GREEN. api/ fence,
Elixir gate.

## Re-derive the assertion location

    cd /Volumes/SATECHI/github/barkpark/api
    git show origin/main:api/test/barkpark_web/live/studio/studio_live_sheet_presence_test.exs | sed -n '300,322p'
    # -> line 321: `assert frame_ms < 10`, budget comment "10ms review budget ... headroom for slow CI boxes"

    git show origin/main:api/test/bench/validation_perf_test.exs | grep -nE "assert" | head
    # -> only shape asserts (length ==, kinds == ~w(...)); comment line 7: "the regression gate runs in CI (perf.yml)"

## Re-run the measurement (quiet host)

    cd /Volumes/SATECHI/github/barkpark/api
    MIX_ENV=test mix test test/barkpark_web/live/studio/studio_live_sheet_presence_test.exs:257

## Measured frame_ms, 5 runs on a quiet host (2026-08-18)

    7.45ms  (moving 19.67 - baseline 12.22)
    5.35ms  (moving 17.89 - baseline 12.54)
    0.0ms   (moving 11.32 - baseline 12.15)   # clamped by max(_,0.0)
    0.0ms   (moving 12.73 - baseline 16.99)   # clamped
    9.05ms  (moving 20.68 - baseline 11.63)

All PASS (< 10). Swing 0.0–9.05ms across 5 quiet-host runs; thin headroom below the
10ms ceiling. frame_ms = max(median(moving) - median(baseline), 0.0): two independently
noisy wall-clock medians subtracted, so host load that inflates the `moving` loop
disproportionately tips it over 10 -> false RED. A real render regression inflates
moving but NOT the no-op baseline (identical-presence frame skips render), so it is
caught -> no false-GREEN in the expected direction. Below-bar confirmed.

## Escape-hatch input

If a builder widens the budget: grounded number is 9.05ms peak on a QUIET host; a
budget of ~15–20ms with recorded rationale (or n-of-m / retry) absorbs load spikes
without masking the pre-fix ~15ms regression the comment cites.
