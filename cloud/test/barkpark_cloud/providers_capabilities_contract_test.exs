defmodule BarkparkCloud.ProvidersCapabilitiesContractTest do
  @moduledoc """
  The provider-capabilities CROSS-SURFACE contract (pure — no DB):

  `cloud/priv/static/__fixtures__/providers_capabilities.json` MUST be a
  byte-for-byte copy of the canonical Go fixture
  `internal/cli/cloud/providers_capabilities.json`. The Go seam owns the
  contract (a capability claimed but unimplemented reds a Go test; one
  implemented but unclaimed reds the SPA harness — charter Decision 8). The
  control plane SERVES that same contract over `GET /v1/providers/capabilities`
  so the SPA and `bp` CLI read one truth instead of each re-parsing the file and
  inventing gap copy.

  This test is the drift gate on the COPY: any edit to the Go fixture that isn't
  mechanically mirrored into the CP copy (or vice-versa) reds here. Refresh the
  copy with a straight `cp` of the Go fixture — never hand-edit either side.
  """
  use ExUnit.Case, async: true

  # The CP's committed copy (served by the capability conduit).
  @cp_fixture Path.expand(
                "../../priv/static/__fixtures__/providers_capabilities.json",
                __DIR__
              )

  # The canonical Go fixture — the seam owns the contract. Path.expand up out of
  # cloud/ into the repo root, then into internal/cli/cloud/.
  @go_fixture Path.expand(
                "../../../internal/cli/cloud/providers_capabilities.json",
                __DIR__
              )

  test "the CP copy is BYTE-IDENTICAL to the canonical Go fixture" do
    assert File.exists?(@go_fixture),
           "canonical Go fixture missing at #{@go_fixture}"

    go_bytes = File.read!(@go_fixture)
    cp_bytes = File.read!(@cp_fixture)

    assert cp_bytes == go_bytes,
           "cloud/priv/static/__fixtures__/providers_capabilities.json has drifted " <>
             "from internal/cli/cloud/providers_capabilities.json — refresh it with a " <>
             "straight `cp` of the Go fixture (never hand-edit one side)."
  end

  test "the fixture parses to per-kind capability rows (structural sanity)" do
    parsed = @cp_fixture |> File.read!() |> Jason.decode!()

    assert is_map(parsed) and parsed != %{}

    for {kind, row} <- parsed do
      assert is_binary(kind)
      assert is_map(row)
      # Every non-"tier" value is a capability bool; "tier" (when present) is a
      # string. This mirrors what the conduit's split_provider_tier/1 relies on.
      for {key, value} <- row do
        if key == "tier",
          do: assert(is_binary(value)),
          else: assert(is_boolean(value), "#{kind}.#{key} must be a boolean capability")
      end
    end
  end
end
