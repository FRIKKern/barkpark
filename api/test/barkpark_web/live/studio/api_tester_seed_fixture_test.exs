defmodule BarkparkWeb.Studio.ApiTesterSeedFixtureTest do
  @moduledoc """
  Run all's two content probes follow the fixture THIS instance has.

  Stranger walk (2026-09-30): on a clean-seeded instance (`bp setup --target
  local`) "Get single document" (post p1) and "Search" (q = GROQ) always
  failed — both are DEMO-seed content — so a healthy server's first Run all
  read 32 Pass / 3 Fail (the third a plugin probe). The clean seed's published `welcome` paper now stands
  in when p1 is absent.
  """
  use ExUnit.Case, async: true

  alias Barkpark.ApiTester.Endpoints
  alias BarkparkWeb.Studio.ApiTesterLive

  @config %{base: "http://node", dataset: "production", token: ""}

  defp scenario(endpoint_id, label) do
    Endpoints.all("production")
    |> Enum.find(&(&1.id == endpoint_id))
    |> Map.fetch!(:scenarios)
    |> Enum.find(&(&1.label == label))
  end

  defp getter(present) do
    fn url -> if Enum.any?(present, &String.ends_with?(url, &1)), do: 200, else: 404 end
  end

  test "demo seed (p1 present): the catalog defaults stand" do
    assert ApiTesterLive.seed_fixture_overrides(@config, getter(["/post/p1"])) == %{}
  end

  test "clean seed (only the welcome paper): both probes point at it, and the label says so" do
    fixtures = ApiTesterLive.seed_fixture_overrides(@config, getter(["/paper/welcome"]))

    single =
      ApiTesterLive.apply_seed_fixture(
        scenario("query-single", "gets document p1"),
        "query-single",
        fixtures
      )

    assert single.path_overrides == %{"type" => "paper", "doc_id" => "welcome"}
    assert single.label =~ "welcome paper"
    assert single.expect == {200, :envelope_top_level}, "the expectation itself is unchanged"

    search =
      ApiTesterLive.apply_seed_fixture(
        scenario("search-documents", "search with results"),
        "search-documents",
        fixtures
      )

    assert search.query_overrides["q"] == "Welcome"
    assert search.expect == {200, :search_has_results}

    typed =
      ApiTesterLive.apply_seed_fixture(
        scenario("search-documents", "search with type filter"),
        "search-documents",
        fixtures
      )

    assert typed.query_overrides == %{"q" => "Welcome", "type" => "paper"}

    other = scenario("search-documents", "search no matches")

    assert ApiTesterLive.apply_seed_fixture(other, "search-documents", fixtures) == other,
           "only the two content probes are redirected"
  end

  test "neither fixture: defaults stay, and fail honestly" do
    assert ApiTesterLive.seed_fixture_overrides(@config, getter([])) == %{}
  end
end
