defmodule BarkparkCloud.ProvidersCatalogCapabilityTest do
  @moduledoc """
  The control plane may not serve `catalog: false` for a kind IT ITSELF catalogs.

  `providers_capabilities.json` is the GO SEAM's contract: `hetzner.catalog` and
  `azure.catalog` are false because no Go provider implements `Catalog(ctx)`
  (`DetectCapabilities` type-asserts `Cataloger`). That bool is honest THERE.

  But this control plane implements the catalog itself — `defp
  build_provider_catalog("hetzner", …)` and `("azure", …)` fetch, price and
  normalize a real size-and-region menu behind `GET /v1/providers/:kind/catalog`,
  and the console paints those priced regions in the launch wizard. Passing the
  Go-seam bool through `GET /v1/providers/capabilities` made the CP attach
  `FailureCopy.capability_gap_reason(_kind, "catalog")` — "doesn't publish a
  size-and-region catalog HERE yet" — to a capability it serves two clicks away.

  This arm's domain is DERIVED from the router source, never hand-listed, and it
  joins BOTH ways:

    * the `build_provider_catalog/2` clause heads = what the CP can ACTUALLY
      build, and
    * `@neutral_kinds` = what the CP DECLARES routable at
      `/v1/providers/:kind/catalog`.

  Both directions matter. Clause-head-only would let a deleted clause buy
  silence: the route stays declared, serves a 502, and the capability payload
  goes back to calling it a gap — the same lie in a different costume. And a
  source-text regex is blind to a macro-generated clause, so the declared list is
  the cross-check that catches a derivation that quietly went empty.

  The fixture is NOT the fix: flipping it to `true` reds the Go seam's own
  honesty tests. The CP overlays exactly the `catalog` key for the derived kinds
  and leaves every other capability flowing from the fixture.

  Provider kinds are named ABOVE ONLY AS NARRATIVE. No assertion below reads a
  hand-written kind: every kind in this file's logic comes out of the router
  source. A new catalog-backed provider is covered the day its clause lands.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @router_source Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @external_resource @router_source

  @fixture Path.expand("../../priv/static/__fixtures__/providers_capabilities.json", __DIR__)
  @external_resource @fixture

  @opts Router.init([])

  ## Derivation ───────────────────────────────────────────────────────────────

  defp router_source, do: File.read!(@router_source)

  # Kinds the CP can ACTUALLY build a catalog for: one `defp
  # build_provider_catalog("<kind>", …)` clause head each.
  defp implemented_catalog_kinds do
    ~r/^\s*defp\s+build_provider_catalog\(\s*"([a-z0-9_-]+)"/m
    |> Regex.scan(router_source())
    |> Enum.map(fn [_full, kind] -> kind end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Kinds the CP DECLARES catalog-routable (`@neutral_kinds ~w(…)`), i.e. the
  # kinds `/v1/providers/:kind/catalog` answers instead of 404 unknown_kind.
  defp declared_catalog_kinds do
    case Regex.run(~r/^\s*@neutral_kinds\s+~w\(([^)]*)\)/m, router_source()) do
      [_full, inner] -> inner |> String.split(~r/\s+/, trim: true) |> Enum.sort()
      nil -> []
    end
  end

  defp catalog_kinds, do: Enum.uniq(implemented_catalog_kinds() ++ declared_catalog_kinds())

  ## The served payload ───────────────────────────────────────────────────────

  defp served_providers do
    {:ok, user} =
      Accounts.register_user(%{
        email: "catalog-cap-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, token} = Accounts.create_user_session_token(user)

    conn =
      :get
      |> conn("/v1/providers/capabilities")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)["providers"]
  end

  defp fixture_rows, do: @fixture |> File.read!() |> Jason.decode!()

  ## Arms ─────────────────────────────────────────────────────────────────────

  test "the derivation is non-vacuous — a regex that matched nothing cannot pass" do
    assert implemented_catalog_kinds() != [],
           "no `defp build_provider_catalog(\"<kind>\"` clause head found in #{@router_source} — " <>
             "the derivation went blind (renamed helper, or a macro-generated clause). " <>
             "Re-derive it; do not weaken this arm."

    assert declared_catalog_kinds() != [],
           "no `@neutral_kinds ~w(…)` found in #{@router_source} — the declared catalog " <>
             "kinds could not be derived."
  end

  test "BOTH WAYS: every declared catalog kind is implemented, and vice-versa" do
    implemented = implemented_catalog_kinds()
    declared = declared_catalog_kinds()

    assert declared -- implemented == [],
           "declared catalog-routable but with NO build_provider_catalog clause: " <>
             "#{inspect(declared -- implemented)}. GET /v1/providers/<kind>/catalog stays " <>
             "declared and answers 502 catalog_unavailable — deleting the clause head must " <>
             "not buy silence here."

    assert implemented -- declared == [],
           "implemented a catalog for kinds not in @neutral_kinds: " <>
             "#{inspect(implemented -- declared)}. The builder is unreachable — the route " <>
             "404s unknown_kind."
  end

  test "no kind the CP catalogs is served catalog: false" do
    providers = served_providers()
    kinds = catalog_kinds()

    missing = for kind <- kinds, not is_map(providers[kind]), do: kind

    assert missing == [],
           "#{inspect(missing)} have a catalog in this control plane but no row in the " <>
             "served capability payload."

    # Collected, not short-circuited: the failure must name EVERY lying kind, not
    # just the first one in sort order.
    lying = for kind <- kinds, providers[kind]["capabilities"]["catalog"] == false, do: kind

    assert lying == [],
           "#{inspect(lying)} are served capabilities.catalog=false while this control " <>
             "plane builds their catalog (build_provider_catalog(\"<kind>\", …)) and serves " <>
             "it at GET /v1/providers/<kind>/catalog. Fix the CP's own claim — NOT the " <>
             "Go-seam fixture, whose false is honest about the Go provider."
  end

  test "no catalog gap sentence is attached to a kind the CP catalogs" do
    providers = served_providers()

    gapped =
      for kind <- catalog_kinds(),
          reason = providers[kind]["gaps"]["catalog"],
          do: {kind, reason}

    assert gapped == [],
           "#{inspect(gapped)} — a catalog gap reason the launch wizard's priced regions " <>
             "refute in the same session."
  end

  test "the overlay is exactly one key: every other capability still flows from the fixture" do
    providers = served_providers()
    catalog_kinds = catalog_kinds()

    for {kind, fixture_row} <- fixture_rows() do
      served = providers[kind]["capabilities"]

      for {key, value} <- fixture_row, is_boolean(value) do
        overlaid? = key == "catalog" and kind in catalog_kinds

        unless overlaid? do
          assert served[key] == value,
                 "#{kind}.#{key} drifted from the fixture (served #{inspect(served[key])}, " <>
                   "fixture #{inspect(value)}). This slice widens the catalog key for " <>
                   "CP-catalogued kinds and nothing else."
        end
      end
    end
  end

  test "a kind the CP does NOT catalog keeps the fixture's catalog bool and its gap reason" do
    providers = served_providers()
    catalog_kinds = catalog_kinds()

    for {kind, fixture_row} <- fixture_rows(),
        kind not in catalog_kinds,
        Map.has_key?(fixture_row, "catalog") do
      assert providers[kind]["capabilities"]["catalog"] == fixture_row["catalog"],
             "#{kind} has no catalog in this control plane, so its catalog bool must be the " <>
               "fixture's — the overlay must not leak past the derived kinds."

      if fixture_row["catalog"] == false do
        assert is_binary(providers[kind]["gaps"]["catalog"]),
               "#{kind} is served catalog=false with no reason — every false capability owes " <>
                 "the reader a sentence."
      end
    end
  end
end
