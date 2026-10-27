defmodule Barkpark.Groq.GeoTest do
  @moduledoc """
  task-ce93ff890a895f54: `geo::latLng/2` and `geo::distance/2` answer as
  Sanity does. Every expected value below was read off Sanity's query API
  (e2e-local, 2026-10-26).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}

  defp q(query) do
    {:ok, tree} = Parser.parse(query)
    {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new([]))
    value
  end

  test "geo::latLng renders as a GeoJSON Point, [lng, lat]" do
    assert q("geo::latLng(59.91, 10.75)") == %{"type" => "Point", "coordinates" => [10.75, 59.91]}
    assert q("geo::latLng(59, 10)") == %{"type" => "Point", "coordinates" => [10, 59]}
    assert q("geo::latLng(-90, 180)") == %{"type" => "Point", "coordinates" => [180, -90]}
  end

  test "geo::latLng is null for a non-number or out-of-range coordinate" do
    for query <- [
          "geo::latLng(null, 1)",
          "geo::latLng(1, null)",
          ~s|geo::latLng("59", 10)|,
          "geo::latLng(true, 10)",
          "geo::latLng(91, 0)",
          "geo::latLng(0, 181)",
          "geo::latLng(0, -200)"
        ],
        do: assert(q(query) == nil, query)
  end

  test "a geo value is opaque: its fields read null and it equals nothing" do
    assert q("geo::latLng(59.5, 10.25).lat") == nil
    assert q("[geo::latLng(1, 2)][0].coordinates[1]") == nil
    assert q("geo::latLng(59, 10) == geo::latLng(59, 10)") == false
  end

  test "geo::distance is haversine in metres on Sanity's sphere" do
    assert q("geo::distance(geo::latLng(0, 0), geo::latLng(0, 1))") == 111_319.49079327357
    assert q("geo::distance(geo::latLng(90, 0), geo::latLng(-90, 0))") == 20_037_508.342789244
    assert q("geo::distance(geo::latLng(0, 0), geo::latLng(0, 0))") == 0

    # Off-axis answers can sit an ulp or two from Sanity's, and the libm
    # trig differs between macOS and Linux, so these match to a micrometre.
    assert_in_delta q("geo::distance(geo::latLng(59.91, 10.75), geo::latLng(60.39, 5.32))"),
                    305_476.8338102688,
                    1.0e-6

    assert_in_delta q("geo::distance(geo::latLng(59.91, 10.75), geo::latLng(-33.86, 151.2))"),
                    15_966_242.858284688,
                    1.0e-6
  end

  test "geo::distance takes geopoint objects and GeoJSON Points" do
    one_degree = 111_319.49079327357

    for query <- [
          ~s|geo::distance({"_type": "geopoint", "lat": 0, "lng": 0}, geo::latLng(0, 1))|,
          ~s|geo::distance({"lat": 0, "lng": 0}, geo::latLng(0, 1))|,
          ~s|geo::distance({"type": "Point", "coordinates": [1, 0]}, geo::latLng(0, 0))|,
          ~s|geo::distance({"_type": "geopoint", "lat": 0, "lng": 0, "alt": 5}, {"lat": 0, "lng": 1})|
        ],
        do: assert(q(query) == one_degree, query)
  end

  test "geo::distance is null for anything that is not a point in range" do
    for query <- [
          "geo::distance(null, geo::latLng(0, 1))",
          "geo::distance(geo::latLng(0, 0), null)",
          "geo::distance(1, 2)",
          ~s|geo::distance("x", geo::latLng(0, 1))|,
          "geo::distance([0, 0], geo::latLng(0, 1))",
          ~s|geo::distance({"lat": 91, "lng": 0}, geo::latLng(0, 1))|,
          ~s|geo::distance({"lat": 0}, geo::latLng(0, 1))|,
          ~s|geo::distance({"lat": "0", "lng": 0}, geo::latLng(0, 1))|,
          ~s|geo::distance({"type": "Point", "coordinates": [0]}, geo::latLng(0, 0))|,
          ~s|geo::distance({"type": "Point", "coordinates": [200, 0]}, geo::latLng(0, 0))|,
          ~s|geo::distance({"type": "Polygon", "coordinates": [[[0,0],[1,0],[1,1],[0,0]]]}, geo::latLng(0, 0))|
        ],
        do: assert(q(query) == nil, query)
  end

  # task-1db8d92a284a23d2: the shapes themselves are pinned in GeoShapeTest.
  test "geo::contains and geo::intersects take a geo::latLng point" do
    square = ~s|{"type": "Polygon", "coordinates": [[[0,0],[10,0],[10,10],[0,10],[0,0]]]}|

    assert q("geo::contains(#{square}, geo::latLng(5, 5))") == true
    assert q("geo::contains(#{square}, geo::latLng(0, 5))") == false
    assert q("geo::intersects(#{square}, geo::latLng(0, 5))") == true
    assert q("geo::intersects(geo::latLng(5, 5), #{square})") == true
    assert q(~s|geo::contains(#{square}, {"lat": 5, "lng": 5})|) == true
    assert q("geo::contains(null, geo::latLng(5, 5))") == nil
  end

  test "the wrong number of arguments is a parse error, as on Sanity" do
    for query <- [
          "geo::latLng(1)",
          "geo::latLng(1, 2, 3)",
          "geo::distance(geo::latLng(0, 0))",
          "geo::contains(geo::latLng(0, 0))",
          "geo::intersects(1, 2, 3)"
        ] do
      assert {:error, e} = Parser.parse(query)
      assert e.description =~ "Incorrect number of arguments to function", query
    end
  end
end
