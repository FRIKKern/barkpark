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

  # An unauthenticated `?offset=` used to pass through unclamped. Delivery.Search
  # turns it into `limit(limit + offset + 20)` and then `Enum.drop(offset)` in the
  # BEAM (search.ex paginate_ids/2), so an offset of five million materialises
  # five million rows in process heap on an anonymous GET. The clamp is the fence.
  test "a huge offset is clamped to @max_offset" do
    assert MediaSearchParams.parse(%{"offset" => "5000000"})[:offset] == 10_000
    assert MediaSearchParams.parse(%{"offset" => 5_000_000})[:offset] == 10_000
    # Exactly at the bound survives untouched.
    assert MediaSearchParams.parse(%{"offset" => "10000"})[:offset] == 10_000
  end

  test "a negative offset floors at 0" do
    assert MediaSearchParams.parse(%{"offset" => "-1"})[:offset] == 0
    assert MediaSearchParams.parse(%{"offset" => -5_000_000})[:offset] == 0
  end

  test "an ordinary offset passes through unchanged" do
    assert MediaSearchParams.parse(%{"offset" => "100"})[:offset] == 100
    assert MediaSearchParams.parse(%{})[:offset] == 0
    assert MediaSearchParams.parse(%{"offset" => "not-a-number"})[:offset] == 0
  end

  test "limit keeps its existing clamp (the offset fix did not disturb it)" do
    assert MediaSearchParams.parse(%{"limit" => "5000"})[:limit] == 500
    assert MediaSearchParams.parse(%{"limit" => "25"})[:limit] == 25
    assert MediaSearchParams.parse(%{})[:limit] == 50
  end
end
