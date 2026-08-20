# Re-derivation recipe — does the gate run THREE census arms or FOUR?

Base: `origin/main` = `467f7e2837b0690d45a2c8a573e7242b6d720833` (2026-08-05).

## The chain, one command per link

    # (1) no workflow names the census directly
    grep -rn 'pds_elixir_census\|pds-elixir-receipt-census' .github/workflows/
    # -> NO OUTPUT

    # (2) the rider carries FOUR test arms
    git show origin/main:api/test/barkpark/pds_elixir_census_test.exs | grep -n 'test "'
    # 135: "the receipt census runs GREEN over the live corpus"
    # 145: "the gate CAN red: a one-token mutant exits 1 with FAIL  CLASSIFICATION-TOTAL"
    # 187: "the population baseline REFUSES: a perturbed literal exits 1 with FAIL  D448-DRIFT-REFUSES"
    # 210: "the census REFUSES an unknown flag — ARGV-STRICT, not a shrug"

    # (3) the rider carries NO excludable tag — only a timeout moduletag
    git show origin/main:api/test/barkpark/pds_elixir_census_test.exs | grep -n '@tag\|@moduletag'
    # 85:  @moduletag timeout: 600_000

    # (4) nothing in test_helper's exclude list can reach it
    git show origin/main:api/test/test_helper.exs | sed -n '50,75p'
    # exclude: [:bokbasen_integration, :phase8_demo, :requires_wi3, :requires_wi4,
    #           :flaky, :boot_test, :plugin_routes, :requires_vips, :idp_interop, :real_binary]

    # (5) the required gate runs the plain default invocation
    git show origin/main:.github/workflows/elixir.yml | grep -n 'run: mix test'
    # 455:        run: mix test          (job `mix-test`, name "Test (Elixir … / OTP …)")
    # 484:        run: mix test --only boot_test …   (separate step, different file)
    # (the working tree reports 417/446 — it is off origin/main's lineage; quote origin/main)

## Verdict

**CI runs FOUR arms**, every time the `mix-test` job runs. The job is path-conditional
(`if: needs.changes.outputs.test == 'true'`), and `scripts/pds-elixir-receipt-census.exs` is in
`ELIXIR_TEST_ONLY_PATHS` (`scripts/elixir-path-escape-check.sh:100`), so a census-only PR still
dispatches it.

`scripts/pds-door-census.sh:286` therefore prices "the THREE GATED ARMS SUMMED" for a gate that
runs four. This is a **stale price**, not a CI hole — the fix is NOT "add the arm to the gate".
And it is not prose-only either: the rider's own moduledoc (:42-47) records 28,9 s wall for three
arms vs 42,0 s for four, so the row's `CPU=26.47+2.26=28.73s` must be RE-METERED, not reworded.
