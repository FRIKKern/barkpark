defmodule BarkparkCloud.Web.RouterProvidersCapabilitiesTest do
  @moduledoc """
  The CP-served capability/tier conduit (S11a, charter Decision 16):

    * `GET /v1/providers/capabilities` → `{providers: {kind: {tier, capabilities,
      gaps}}}`, built from the committed cross-surface fixture so the SPA and the
      `bp` CLI read ONE contract.
    * tier is the fixture value ("dev" for fake) or the "prod" default.
    * capabilities are passed through GENERICALLY (every boolean key) — no
      hardcoded key list, so S9's facet split flows through unchanged.
    * gaps carry a server-owned reason for EVERY false capability, and none is
      reason-less.
    * dev-tier rows are INCLUDED (the reading surface filters, not the conduit).
    * require_user: no auth → 401.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, FailureCopy}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(token) do
    conn = conn(:get, "/v1/providers/capabilities")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp body(token), do: call(token).resp_body |> Jason.decode!()

  test "no auth → 401" do
    assert call(nil).status == 401
  end

  test "200 with a providers map keyed by kind, each carrying tier/capabilities/gaps" do
    conn = call(session_token(user_fixture()))
    assert conn.status == 200

    %{"providers" => providers} = Jason.decode!(conn.resp_body)
    assert is_map(providers) and providers != %{}

    for {_kind, row} <- providers do
      assert Enum.sort(Map.keys(row)) == ~w(capabilities gaps tier)
      assert is_binary(row["tier"])
      assert is_map(row["capabilities"]) and row["capabilities"] != %{}
      assert Enum.all?(Map.values(row["capabilities"]), &is_boolean/1)
      assert is_map(row["gaps"])
    end
  end

  test "tier: fake is dev (fixture value); hetzner/azure default to prod" do
    providers = body(session_token(user_fixture()))["providers"]

    assert providers["fake"]["tier"] == "dev"
    assert providers["hetzner"]["tier"] == "prod"
    assert providers["azure"]["tier"] == "prod"
  end

  test "dev-tier rows are INCLUDED (the reading surface filters, not the conduit)" do
    providers = body(session_token(user_fixture()))["providers"]
    assert Map.has_key?(providers, "fake")
  end

  test "capabilities are the raw fixture bools — no 'tier' key leaks in as a capability" do
    providers = body(session_token(user_fixture()))["providers"]

    # hetzner: core+labels true, pause false (matches fixture).
    assert providers["hetzner"]["capabilities"]["core"] == true
    assert providers["hetzner"]["capabilities"]["labels"] == true
    assert providers["hetzner"]["capabilities"]["pause"] == false
    # `catalog` is the ONE key the CP answers itself rather than reading — this
    # control plane builds the hetzner/azure catalogs (build_provider_catalog/2)
    # even though the Go seam has no Cataloger. Owned by
    # providers_catalog_capability_test.exs; the fixture bool stays false there.
    assert providers["hetzner"]["capabilities"]["catalog"] == true
    # tier is metadata, never a capability.
    refute Map.has_key?(providers["fake"]["capabilities"], "tier")
  end

  test "gaps carry a server-owned reason for EVERY false capability, and only those" do
    providers = body(session_token(user_fixture()))["providers"]

    for {kind, row} <- providers do
      false_caps =
        row["capabilities"]
        |> Enum.filter(fn {_k, v} -> v == false end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      # gaps key set == the false capabilities exactly (no reason-less gap, no
      # gap for a satisfied capability).
      assert Enum.sort(Map.keys(row["gaps"])) == false_caps

      # And each reason is the server-owned FailureCopy string (single source).
      for {cap, reason} <- row["gaps"] do
        assert reason == FailureCopy.capability_gap_reason(kind, cap)
        assert is_binary(reason) and reason != ""
      end
    end
  end

  test "fake (all capabilities true) has an empty gaps map" do
    providers = body(session_token(user_fixture()))["providers"]
    assert providers["fake"]["gaps"] == %{}
  end
end
