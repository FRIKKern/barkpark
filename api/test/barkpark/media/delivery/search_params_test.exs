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

  describe "offset ceiling" do
    # `Delivery.Search.paginate_ids/2` issues `LIMIT limit + offset + 20` with NO
    # SQL OFFSET and drops `offset` rows IN THE BEAM, so an unclamped offset is a
    # heap-materialization lever, not a slow query. The document route already
    # clamps at `|> max(0) |> min(100_000)` (query_controller.ex, search_controller.ex).

    test "an absurd offset is clamped to the ceiling, not passed through" do
      opts = MediaSearchParams.parse(%{"offset" => "5000000"})

      assert opts[:offset] == 100_000
      assert opts[:offset] == MediaSearchParams.max_offset()
    end

    test "an offset BELOW the ceiling is untouched (the clamp is a ceiling, not a constant)" do
      # Without this, a clamp written as `_ -> 100_000` would pass the test above.
      assert MediaSearchParams.parse(%{"offset" => "120"})[:offset] == 120
      assert MediaSearchParams.parse(%{})[:offset] == 0
    end

    test "the ceiling holds for an INTEGER offset too, not only the string form" do
      # `parse_int/2` accepts a bare integer (Phoenix hands strings, but a
      # server-side caller can hand an int), and that clause bypassed nothing
      # before the clamp moved outside it.
      assert MediaSearchParams.parse(%{"offset" => 9_999_999})[:offset] == 100_000
    end

    test "clamp_offset/1 floors at zero" do
      assert MediaSearchParams.clamp_offset(-1) == 0
      assert MediaSearchParams.clamp_offset(0) == 0
    end
  end
end
