defmodule BarkparkCloud.EdgeCapabilitiesContractTest do
  @moduledoc """
  The EDGE-capability CROSS-SURFACE contract (pure — no DB), the sibling of
  `providers_capabilities_contract_test.exs` for what a provider adds IN FRONT
  of a Barkpark box rather than what it can provision.

  `cloud/priv/static/__fixtures__/edge_capabilities.json` MUST be a byte-for-byte
  copy of the canonical Go fixture `internal/cli/cloud/edge_capabilities.json`.

  ## The lock is on BOTH sides

  Two copies with a test each is an unlocked mirror — each suite would only ever
  read its own file. So this test and its Go twin
  (`TestEdgeFixtureCopyIsByteIdentical` in `internal/cli/cloud/`) each decode
  BOTH copies: editing either file alone reds BOTH suites. Refresh the copy with
  a straight `cp` of the Go fixture — never hand-edit one side.

  ## The row content is DERIVED, not opinionated

  `cloudflare`'s bools are gated against `BarkparkCloud.Cloudflare.capabilities/0`
  by a PREDICATE, not a list: a key is true exactly when it is in that module's
  declared menu (`[:dns, :tls, :cdn]`; "Tunnel + storage are backlog"). Flip a
  fixture bool without the code, or extend the menu without the fixture, and this
  reds — the edge analogue of the compute matrix's parity test.

  `vercel` states only `full_host`, which `Vercel.deploy_for/1` derives (it calls
  `deploy_project` and stores a live `deployment_url` — Vercel serves the app
  itself). Every other edge key is named in `unknown`: this repo's Vercel context
  contains no TLS, CDN, DNS, tunnel, storage or edge-function call whatsoever, so
  BOTH bools would assert something unproven — and `false` is the worse lie of the
  two, because the conduit would then emit a gap reason ("the tls capability isn't
  available on this provider yet") about a provider we simply do not drive.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Cloudflare

  @cp_fixture Path.expand(
                "../../priv/static/__fixtures__/edge_capabilities.json",
                __DIR__
              )

  @go_fixture Path.expand(
                "../../../internal/cli/cloud/edge_capabilities.json",
                __DIR__
              )

  @unknown_key "unknown"

  defp rows, do: @cp_fixture |> File.read!() |> Jason.decode!()

  defp capability_bools(row),
    do: for({key, value} <- row, is_boolean(value), into: %{}, do: {key, value})

  defp unknown_keys(row), do: Map.get(row, @unknown_key, [])

  defp stated_or_unknown(row),
    do: row |> capability_bools() |> Map.keys() |> Enum.concat(unknown_keys(row)) |> Enum.sort()

  test "the CP copy is BYTE-IDENTICAL to the canonical Go fixture" do
    assert File.exists?(@go_fixture),
           "canonical Go fixture missing at #{@go_fixture}"

    go_bytes = File.read!(@go_fixture)
    cp_bytes = File.read!(@cp_fixture)

    assert cp_bytes == go_bytes,
           "cloud/priv/static/__fixtures__/edge_capabilities.json has drifted " <>
             "from internal/cli/cloud/edge_capabilities.json — refresh it with a " <>
             "straight `cp` of the Go fixture (never hand-edit one side)."
  end

  test "the fixture parses to per-kind edge rows (structural sanity)" do
    parsed = rows()

    assert is_map(parsed) and parsed != %{}

    for {kind, row} <- parsed do
      assert is_binary(kind)
      assert is_map(row)

      # Every value is a capability bool EXCEPT "unknown", which is a list of
      # capability names. This is the shape the conduit's generic
      # `is_boolean(value)` filter already handles with zero conduit change —
      # the same role `tier` plays in the compute matrix.
      for {key, value} <- row do
        if key == @unknown_key do
          assert is_list(value) and value != []
          assert Enum.all?(value, &is_binary/1)
        else
          assert is_boolean(value), "#{kind}.#{key} must be a boolean capability"
        end
      end

      # A key may be stated OR declared unknown, never both.
      bools = capability_bools(row)

      for key <- unknown_keys(row) do
        refute Map.has_key?(bools, key),
               "#{kind}.#{key} is both a bool and named unknown — one is a lie"
      end
    end
  end

  test "every kind covers the SAME edge key set (stated or explicitly unknown)" do
    parsed = rows()
    [{_first_kind, reference} | _] = Enum.sort(parsed)
    contract = stated_or_unknown(reference)

    for {kind, row} <- parsed do
      assert stated_or_unknown(row) == contract,
             "#{kind} covers #{inspect(stated_or_unknown(row))} but the edge contract is " <>
               "#{inspect(contract)} — a new edge key may not be quietly omitted for one kind"
    end
  end

  # THE DERIVATION GATE. A predicate, not an enumeration: cloudflare claims an
  # edge capability exactly when BarkparkCloud.Cloudflare declares it. Flipping
  # a bool in the fixture without the code (or extending the module's menu
  # without the fixture) reds here.
  test "cloudflare's bools match Cloudflare.capabilities/0 exactly" do
    menu = Cloudflare.capabilities() |> Enum.map(&Atom.to_string/1)

    # Guard the guard: a menu that went empty would make every `false` pass.
    assert menu != []

    row = rows() |> Map.fetch!("cloudflare")
    bools = capability_bools(row)

    assert bools != %{}
    assert unknown_keys(row) == []

    for {capability, claimed} <- bools do
      assert claimed == capability in menu,
             "edge_capabilities.json says cloudflare.#{capability}=#{claimed}, but " <>
               "Cloudflare.capabilities/0 is #{inspect(menu)} — the fixture and the " <>
               "module disagree about a capability we either implement or don't."
    end

    # And the menu is fully represented: a capability the module declares may
    # not be missing from the fixture altogether.
    for capability <- menu do
      assert Map.get(bools, capability) == true,
             "Cloudflare declares #{capability} but the edge fixture doesn't claim it"
    end
  end

  # Vercel: only what deploy_for/1 actually proves. The rest is `unknown`, NOT
  # false — a false here would put a gap reason on a surface about a provider
  # this repo does not drive.
  test "vercel states only the capability its deploy seam derives" do
    row = rows() |> Map.fetch!("vercel")

    assert capability_bools(row) == %{"full_host" => true}
    assert unknown_keys(row) != []
  end
end
