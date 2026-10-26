defmodule Barkpark.Groq.GeoShape do
  @moduledoc """
  The shapes behind `geo::contains(a, b)` and `geo::intersects(a, b)`
  (task-1db8d92a284a23d2), as Sanity's API answers them (ecu57yeh, 26 Oct).

    * Planar: a position is `[lng, lat]` on a flat plane, edges are straight
      in that plane, and nothing wraps at ±180 (a ring from 170 to -170
      encloses longitude 0, as on Sanity).
    * `contains` is strict: a point on an edge or a vertex is not contained.
      `intersects` counts the boundary.
    * A hole's interior is outside its polygon; a MultiPolygon answers for
      any member.
    * Shapes: a GeoJSON Point, LineString, Polygon or MultiPolygon, a
      `{lat, lng}` object (a Sanity geopoint) or a `geo::latLng` value. Anything else, or a polygon
      ring that is not closed or has under four positions, answers null.
    * A shape may hold at most `@max_positions` positions; past that the
      answer is `{:error, :too_many_positions}`, decided by counting before
      any geometry runs, so a crafted polygon cannot burn CPU. One evaluation
      pass may spend at most `@max_work` units over all its calls (see
      `reset_budget/0`); past that the answer is `{:error, :work_budget}`.
  """

  @max_positions 1_000
  @max_work 5_000_000

  @doc "The position cap per shape."
  def max_positions, do: @max_positions

  @doc "The work budget per evaluation pass."
  def max_work, do: @max_work

  @spec contains(term(), term()) :: boolean() | nil | {:error, :too_many_positions | :work_budget}
  def contains(a, b), do: with_shapes(a, b, &contains?/2)

  @spec intersects(term(), term()) ::
          boolean() | nil | {:error, :too_many_positions | :work_budget}
  def intersects(a, b), do: with_shapes(a, b, &intersects?/2)

  defp with_shapes(a, b, fun) do
    na = positions_in(a)
    nb = positions_in(b)

    cond do
      na > @max_positions or nb > @max_positions ->
        {:error, :too_many_positions}

      not charge(max(na, 1) * max(nb, 1)) ->
        {:error, :work_budget}

      true ->
        case {shape(a), shape(b)} do
          {nil, _} -> nil
          {_, nil} -> nil
          {sa, sb} -> fun.(sa, sb)
        end
    end
  end

  @doc """
  Start an evaluation pass's geometry budget: `#{@max_work}` work units,
  positions of `a` × positions of `b`, summed over every call in this
  process. `Barkpark.Groq.Evaluator.evaluate/2` starts one per round, beside
  its memo reset, and the source-map pass starts its own. A call that would
  pass it is refused before it runs, e.g. `*[geo::contains($big, location)]`
  over thousands of documents. A process that never started a budget (a
  listen filter matching one document) is held only by the position cap.
  """
  def reset_budget, do: Process.put(:groq_geo_work, 0)

  defp charge(units) do
    case Process.get(:groq_geo_work) do
      nil ->
        true

      used when used + units > @max_work ->
        false

      used ->
        Process.put(:groq_geo_work, used + units)
        true
    end
  end

  # ── Shapes ────────────────────────────────────────────────────────────────
  #
  # {:point, {x, y}} | {:line, [{x, y}]} | {:polygons, [[ring]]} where a ring
  # is a closed list of {x, y} and each polygon is [outer | holes].

  defp positions_in(%{"coordinates" => coords}), do: count(coords, 0)
  defp positions_in(_), do: 1

  # Counts numbers' parent lists, stopping as soon as the cap is passed.
  defp count(_, acc) when acc > @max_positions, do: acc
  defp count([x, y | _], acc) when is_number(x) and is_number(y), do: acc + 1
  defp count(list, acc) when is_list(list), do: Enum.reduce_while(list, acc, &count_step/2)
  defp count(_, acc), do: acc

  defp count_step(item, acc) do
    acc = count(item, acc)
    if acc > @max_positions, do: {:halt, acc}, else: {:cont, acc}
  end

  defp shape(%{"type" => "Point", "coordinates" => c}), do: with_pos(c, &{:point, &1})
  defp shape({:geo, lat, lng}), do: {:point, {lng * 1.0, lat * 1.0}}

  defp shape(%{"type" => "LineString", "coordinates" => cs})
       when is_list(cs) and length(cs) >= 2 do
    case positions(cs) do
      nil -> nil
      ps -> {:line, ps}
    end
  end

  defp shape(%{"type" => "Polygon", "coordinates" => rings}) do
    case polygon(rings) do
      nil -> nil
      poly -> {:polygons, [poly]}
    end
  end

  defp shape(%{"type" => "MultiPolygon", "coordinates" => polys})
       when is_list(polys) and polys != [] do
    ps = Enum.map(polys, &polygon/1)
    if Enum.any?(ps, &is_nil/1), do: nil, else: {:polygons, ps}
  end

  defp shape(%{"lat" => lat, "lng" => lng}) when is_number(lat) and is_number(lng),
    do: {:point, {lng * 1.0, lat * 1.0}}

  defp shape(_), do: nil

  defp polygon(rings) when is_list(rings) and rings != [] do
    rs = Enum.map(rings, &ring/1)
    if Enum.any?(rs, &is_nil/1), do: nil, else: rs
  end

  defp polygon(_), do: nil

  defp ring(cs) when is_list(cs) and length(cs) >= 4 do
    case positions(cs) do
      [first | _] = ps -> if first == List.last(ps), do: ps, else: nil
      nil -> nil
    end
  end

  defp ring(_), do: nil

  defp positions(cs) do
    ps = Enum.map(cs, &pos/1)
    if Enum.any?(ps, &is_nil/1), do: nil, else: ps
  end

  defp with_pos(c, fun) do
    case pos(c) do
      nil -> nil
      p -> fun.(p)
    end
  end

  defp pos([x, y | _]) when is_number(x) and is_number(y), do: {x * 1.0, y * 1.0}
  defp pos(_), do: nil

  # ── contains ──────────────────────────────────────────────────────────────

  defp contains?({:point, p}, {:point, q}), do: p == q
  defp contains?({:point, _}, _), do: false
  defp contains?({:line, ps}, {:point, q}), do: on_path?(q, ps) and not endpoint?(q, ps)
  defp contains?({:line, _}, _), do: false

  # Each member of a MultiPolygon operand must lie in some member of `a`.
  defp contains?({:polygons, polys}, {:polygons, others}),
    do: Enum.all?(others, &polygons_contain?(polys, {:polygons, [&1]}))

  defp contains?({:polygons, polys}, b), do: polygons_contain?(polys, b)

  defp polygons_contain?(polys, b) do
    bb = bbox(b)

    Enum.any?(polys, fn [outer | _] = poly ->
      box_holds?(bbox({:line, outer}), bb) and polygon_contains?(poly, b)
    end)
  end

  defp polygon_contains?(poly, {:point, q}), do: where(poly, q) == :inside

  defp polygon_contains?(poly, {:line, ps}) do
    Enum.all?(ps, &(where(poly, &1) != :outside)) and
      Enum.any?(segments(ps), fn {a, b} -> where(poly, mid(a, b)) == :inside end) and
      not crosses?(segments(ps), poly_segments(poly))
  end

  defp polygon_contains?(poly, {:polygons, others}) do
    Enum.all?(others, fn [outer | _] = other ->
      Enum.all?(outer, &(where(poly, &1) != :outside)) and
        interior_inside?(poly, other) and
        not crosses?(poly_segments(other), poly_segments(poly)) and
        holes_clear?(poly, other)
    end)
  end

  # Some point inside `other` is inside `poly` too (a polygon equal to `poly`,
  # or sharing its edges, has every vertex on the boundary). The candidates
  # are the ring's centroid and midpoints from its first vertex; the first one
  # strictly inside `other` decides.
  defp interior_inside?(poly, [outer | _] = other) do
    [first | rest] = outer
    {xs, ys} = Enum.unzip(tl(outer))
    n = length(xs)
    centroid = {Enum.sum(xs) / n, Enum.sum(ys) / n}

    [centroid | Enum.map(rest, &mid(first, &1))]
    |> Enum.find(&(where(other, &1) == :inside))
    |> case do
      nil -> false
      q -> where(poly, q) == :inside
    end
  end

  # No hole of `poly` lies inside `other`.
  defp holes_clear?([_outer | holes], other),
    do: not Enum.any?(holes, fn hole -> Enum.any?(hole, &(where(other, &1) == :inside)) end)

  # ── intersects ────────────────────────────────────────────────────────────

  defp intersects?({:point, p}, {:point, q}), do: p == q
  defp intersects?({:point, _} = a, b), do: intersects?(b, a)
  defp intersects?({:line, ps}, {:point, q}), do: on_path?(q, ps)
  defp intersects?({:line, ps}, {:line, qs}), do: touches?(segments(ps), segments(qs))
  defp intersects?({:line, _} = a, {:polygons, _} = b), do: intersects?(b, a)

  defp intersects?({:polygons, polys}, b) do
    bb = bbox(b)

    Enum.any?(polys, fn [outer | _] = poly ->
      boxes_meet?(bbox({:line, outer}), bb) and polygon_intersects?(poly, b)
    end)
  end

  defp polygon_intersects?(poly, {:point, q}), do: where(poly, q) != :outside

  defp polygon_intersects?(poly, {:line, ps}),
    do:
      Enum.any?(ps, &(where(poly, &1) != :outside)) or touches?(segments(ps), poly_segments(poly))

  defp polygon_intersects?(poly, {:polygons, others}) do
    Enum.any?(others, fn [outer | _] = other ->
      Enum.any?(outer, &(where(poly, &1) != :outside)) or
        Enum.any?(hd(poly), &(where(other, &1) != :outside)) or
        touches?(poly_segments(other), poly_segments(poly))
    end)
  end

  # ── geometry ──────────────────────────────────────────────────────────────

  defp bbox({:point, {x, y}}), do: {x, y, x, y}
  defp bbox({:line, ps}), do: box_of(ps)
  defp bbox({:polygons, polys}), do: polys |> Enum.map(&hd/1) |> Enum.concat() |> box_of()

  defp box_of(ps) do
    {xs, ys} = Enum.unzip(ps)
    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp boxes_meet?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 <= bx1 and bx0 <= ax1 and ay0 <= by1 and by0 <= ay1

  defp box_holds?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 <= bx0 and ay0 <= by0 and bx1 <= ax1 and by1 <= ay1

  # :inside, :boundary or :outside of a polygon [outer | holes].
  defp where([outer | holes], q) do
    case ring_where(outer, q) do
      :inside ->
        Enum.reduce_while(holes, :inside, fn hole, _ ->
          case ring_where(hole, q) do
            :inside -> {:halt, :outside}
            :boundary -> {:halt, :boundary}
            :outside -> {:cont, :inside}
          end
        end)

      other ->
        other
    end
  end

  defp ring_where(ring, q) do
    segs = segments(ring)

    if Enum.any?(segs, fn {a, b} -> on_segment?(q, a, b) end) do
      :boundary
    else
      {x, y} = q

      inside =
        Enum.reduce(segs, false, fn {{x1, y1}, {x2, y2}}, inside ->
          if y1 > y != y2 > y and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1,
            do: not inside,
            else: inside
        end)

      if inside, do: :inside, else: :outside
    end
  end

  defp segments([_]), do: []
  defp segments([a, b | rest]), do: [{a, b} | segments([b | rest])]
  defp segments(_), do: []

  defp poly_segments(rings), do: Enum.flat_map(rings, &segments/1)

  defp mid({x1, y1}, {x2, y2}), do: {(x1 + x2) / 2, (y1 + y2) / 2}

  defp on_path?(q, ps), do: Enum.any?(segments(ps), fn {a, b} -> on_segment?(q, a, b) end)
  defp endpoint?(q, ps), do: q == hd(ps) or q == List.last(ps)

  defp on_segment?({x, y}, {x1, y1}, {x2, y2}) do
    cross(x2 - x1, y2 - y1, x - x1, y - y1) == 0 and
      x >= min(x1, x2) and x <= max(x1, x2) and y >= min(y1, y2) and y <= max(y1, y2)
  end

  # Any two segments meeting, touching included.
  defp touches?(as, bs),
    do: Enum.any?(as, fn a -> Enum.any?(bs, &segments_meet?(a, &1, false)) end)

  # Any two segments crossing properly (through each other's interiors).
  defp crosses?(as, bs),
    do: Enum.any?(as, fn a -> Enum.any?(bs, &segments_meet?(a, &1, true)) end)

  defp segments_meet?({{x1, y1} = p1, {x2, y2} = p2}, {{x3, y3} = p3, {x4, y4} = p4}, proper?) do
    # Two segments whose boxes do not overlap cannot meet: one comparison
    # instead of four orientations for almost every pair.
    if max(x1, x2) < min(x3, x4) or max(x3, x4) < min(x1, x2) or
         max(y1, y2) < min(y3, y4) or max(y3, y4) < min(y1, y2) do
      false
    else
      segments_meet_exact?(p1, p2, p3, p4, proper?)
    end
  end

  defp segments_meet_exact?(p1, p2, p3, p4, proper?) do
    d1 = orient(p3, p4, p1)
    d2 = orient(p3, p4, p2)
    d3 = orient(p1, p2, p3)
    d4 = orient(p1, p2, p4)

    cond do
      d1 * d2 < 0 and d3 * d4 < 0 ->
        true

      proper? ->
        false

      true ->
        on_segment?(p1, p3, p4) or on_segment?(p2, p3, p4) or on_segment?(p3, p1, p2) or
          on_segment?(p4, p1, p2)
    end
  end

  defp orient({ax, ay}, {bx, by}, {cx, cy}), do: sign(cross(bx - ax, by - ay, cx - ax, cy - ay))
  defp cross(ux, uy, vx, vy), do: ux * vy - uy * vx
  defp sign(v) when v > 0, do: 1
  defp sign(v) when v < 0, do: -1
  defp sign(_), do: 0
end
