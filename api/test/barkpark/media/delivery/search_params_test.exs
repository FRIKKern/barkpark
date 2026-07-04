defmodule Barkpark.Media.Delivery.SearchParamsTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.Delivery.SearchParams, as: MediaSearchParams

  test "array/nested query params parse fail-soft to nil instead of crashing" do
    opts =
      MediaSearchParams.parse(%{
        "type" => ["x"],
        "facet" => %{"mimeType" => ["y"]}
      })

    assert opts[:mime_type] == nil
    assert opts[:facet_selections] == %{}
  end

  test "normal string type param still yields the mime_type" do
    opts = MediaSearchParams.parse(%{"type" => "image/png"})

    assert opts[:mime_type] == "image/png"
  end

  test "array/map facets param fails soft to [] instead of crashing (?facets[]=)" do
    # Phoenix parses ?facets[]=x to a list and ?facets[k]=v to a map; either
    # would raise FunctionClauseError -> 500 before the catch-all clause.
    assert MediaSearchParams.parse(%{"facets" => ["mimeType"]})[:facets] == []
    assert MediaSearchParams.parse(%{"facets" => %{"a" => "b"}})[:facets] == []
  end

  test "comma-separated string facets still parse to known facet fields" do
    # A valid facet field survives; unknown tokens are dropped. Proves the
    # catch-all didn't shadow the real is_binary clause.
    opts = MediaSearchParams.parse(%{"facets" => "mimeType,not_a_real_facet"})
    assert "mimeType" in opts[:facets]
    refute "not_a_real_facet" in opts[:facets]
  end
end
