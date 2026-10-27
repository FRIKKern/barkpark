defmodule Barkpark.Groq.GeoShapeTest do
  @moduledoc """
  task-1db8d92a284a23d2: the shape tests behind `geo::contains` and
  `geo::intersects`. Every expected value is Sanity's (ecu57yeh, 26 Oct):
  planar point-in-polygon on lng/lat, a strict `contains`, an `intersects`
  that counts the boundary, holes, multipolygons, lines, and null for an
  invalid shape. Barkpark adds a cap on positions per shape.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.GeoShape

  defp poly(rings), do: %{"type" => "Polygon", "coordinates" => rings}
  defp ring(points), do: points ++ [hd(points)]
  defp square(x0, y0, x1, y1), do: ring([[x0, y0], [x1, y0], [x1, y1], [x0, y1]])
  defp pt(lat, lng), do: %{"type" => "Point", "coordinates" => [lng, lat]}

  defp sq, do: poly([square(0, 0, 10, 10)])
  defp hole, do: poly([square(0, 0, 10, 10), square(4, 4, 6, 6)])

  defp multi,
    do: %{
      "type" => "MultiPolygon",
      "coordinates" => [[square(0, 0, 1, 1)], [square(5, 5, 6, 6)]]
    }

  test "contains is strict: inside yes, edge and vertex no" do
    assert GeoShape.contains(sq(), pt(5, 5)) == true
    assert GeoShape.contains(sq(), pt(15, 5)) == false
    assert GeoShape.contains(sq(), pt(0, 5)) == false
    assert GeoShape.contains(sq(), pt(0, 0)) == false
    assert GeoShape.contains(sq(), pt(10, 10)) == false
  end

  test "intersects counts the boundary" do
    assert GeoShape.intersects(sq(), pt(5, 5)) == true
    assert GeoShape.intersects(sq(), pt(0, 5)) == true
    assert GeoShape.intersects(sq(), pt(15, 5)) == false
  end

  test "a hole is outside; a multipolygon answers for any member" do
    assert GeoShape.contains(hole(), pt(5, 5)) == false
    assert GeoShape.contains(hole(), pt(2, 2)) == true
    assert GeoShape.contains(hole(), pt(4, 5)) == false
    assert GeoShape.intersects(hole(), pt(5, 5)) == false
    assert GeoShape.contains(multi(), pt(0.5, 0.5)) == true
    assert GeoShape.contains(multi(), pt(5.5, 5.5)) == true
    assert GeoShape.contains(multi(), pt(3, 3)) == false
  end

  test "polygons, lines and points against each other" do
    assert GeoShape.intersects(sq(), poly([square(5, 5, 15, 15)])) == true
    assert GeoShape.intersects(sq(), poly([square(20, 20, 30, 30)])) == false
    assert GeoShape.contains(sq(), poly([square(1, 1, 2, 2)])) == true
    assert GeoShape.contains(sq(), poly([square(5, 5, 15, 15)])) == false
    assert GeoShape.contains(pt(5, 5), pt(5, 5)) == true
    assert GeoShape.intersects(pt(5, 5), pt(5, 5)) == true

    assert GeoShape.contains(sq(), %{"type" => "LineString", "coordinates" => [[1, 1], [2, 2]]}) ==
             true

    assert GeoShape.contains(sq(), sq()) == true
    assert GeoShape.contains(sq(), poly([square(0, 0, 5, 5)])) == true
    assert GeoShape.intersects(sq(), poly([square(10, 0, 20, 10)])) == true
    assert GeoShape.intersects(sq(), poly([square(10, 10, 20, 20)])) == true
    assert GeoShape.contains(hole(), poly([square(1, 1, 9, 9)])) == false

    edge = %{"type" => "LineString", "coordinates" => [[0, 0], [10, 0]]}
    assert GeoShape.contains(sq(), edge) == false

    assert GeoShape.contains(sq(), %{"type" => "LineString", "coordinates" => [[0, 0], [5, 5]]}) ==
             true

    diag = %{"type" => "LineString", "coordinates" => [[0, 0], [10, 10]]}

    assert GeoShape.intersects(diag, %{
             "type" => "LineString",
             "coordinates" => [[0, 10], [10, 0]]
           })

    assert GeoShape.contains(diag, pt(5, 5)) == true
    assert GeoShape.contains(diag, pt(0, 0)) == false
    assert GeoShape.intersects(diag, pt(0, 0)) == true

    small = %{
      "type" => "MultiPolygon",
      "coordinates" => [[square(0.2, 0.2, 0.4, 0.4)], [square(5.2, 5.2, 5.4, 5.4)]]
    }

    assert GeoShape.contains(multi(), small) == true

    line = %{"type" => "LineString", "coordinates" => [[-1, 5], [11, 5]]}
    assert GeoShape.intersects(line, sq()) == true
  end

  test "a point may be a GeoJSON Point or {lat, lng}; the plane is lng/lat as written" do
    assert GeoShape.contains(sq(), %{"lat" => 5, "lng" => 5}) == true

    wrap = poly([ring([[170, 0], [-170, 0], [-170, 10], [170, 10]])])
    assert GeoShape.contains(wrap, pt(5, 180)) == false
    assert GeoShape.contains(wrap, pt(5, 0)) == true
  end

  test "null, a non-shape or an invalid polygon answers null" do
    assert GeoShape.contains(nil, pt(5, 5)) == nil
    assert GeoShape.contains(sq(), nil) == nil
    assert GeoShape.contains("x", pt(5, 5)) == nil
    assert GeoShape.contains(poly([[[0, 0], [10, 0], [10, 10]]]), pt(5, 5)) == nil
    assert GeoShape.contains(poly([]), pt(5, 5)) == nil
    assert GeoShape.contains(poly([[[0, 0], [10, 0], [10, 10], [0, 10]]]), pt(5, 5)) == nil
  end

  test "a shape past the position cap is refused fast" do
    n = 50_000

    big =
      poly([
        ring(
          for i <- 0..(n - 1), do: [:math.cos(i / n * 6.28) * 10, :math.sin(i / n * 6.28) * 10]
        )
      ])

    {micros, result} = :timer.tc(fn -> GeoShape.intersects(big, big) end)
    assert result == {:error, :too_many_positions}
    assert micros < 100_000, "took #{div(micros, 1000)} ms"
  end

  # The lead's case: one big polygon tested against every document. 70-120 ms
  # per call at the cap would add up; the query's budget refuses it early.
  test "a query's calls share one work budget and stop early" do
    GeoShape.reset_budget()
    n = 1_000

    big =
      poly([
        ring(
          for i <- 0..(n - 2), do: [:math.cos(i / n * 6.28) * 10, :math.sin(i / n * 6.28) * 10]
        )
      ])

    other =
      poly([
        ring(for i <- 0..(n - 2), do: [:math.cos(i / n * 6.28) * 5, :math.sin(i / n * 6.28) * 5])
      ])

    {micros, results} =
      :timer.tc(fn -> for _ <- 1..10_000, do: GeoShape.contains(big, other) end)

    # The work, not the clock: each call is 1000 × 1000 positions, so exactly
    # five fit the budget and every later one is refused before any geometry.
    {answered, refused} = Enum.split_while(results, &is_boolean/1)
    assert answered == List.duplicate(true, div(GeoShape.budget(), 1_000_000))
    assert length(answered) == 5
    assert Enum.all?(refused, &(&1 == {:error, :work_budget}))
    # Only a hang guard: 9,995 refused calls cost nothing, five answered ones ~1 s.
    assert micros < 5_000_000, "took #{div(micros, 1000)} ms"

    GeoShape.reset_budget()
    assert GeoShape.contains(big, pt(1, 1)) == true
  end

  # A listen filter runs in the stream's process for its whole life and never
  # starts a budget, so a geo filter must not use one up and turn false.
  test "a listen filter with geo never runs out of budget" do
    circle = fn r ->
      poly([
        ring(for i <- 0..998, do: [:math.cos(i / 999 * 6.28) * r, :math.sin(i / 999 * 6.28) * r])
      ])
    end

    {:ok, filter} =
      BarkparkWeb.ListenFilter.parse(%{
        "query" => "*[geo::intersects($big, area)]",
        "$big" => Jason.encode!(circle.(10))
      })

    doc = %{"_id" => "a", "_type" => "place", "area" => circle.(5)}

    # A million position pairs a match: ten matches pass a query's budget twice.
    for _ <- 1..10, do: assert(BarkparkWeb.ListenFilter.query_match?(filter.query, doc))
  end
end
