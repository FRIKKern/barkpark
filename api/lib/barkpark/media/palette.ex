defmodule Barkpark.Media.Palette do
  @moduledoc """
  An image's colour palette in Sanity's `sanity.imagePalette` shape
  (task-fd05a9327034f89c): seven swatches — `dominant`, `vibrant`,
  `darkVibrant`, `lightVibrant`, `muted`, `darkMuted`, `lightMuted` — each
  `%{"background", "foreground", "title", "population"}`.

  Sanity computes it with node-vibrant, and this is that algorithm, ported:

    1. a histogram of the pixels at 5 bits per channel, skipping pixels that are
       mostly transparent (alpha < 125) or near white (all channels > 250);
    2. modified median cut (MMCQ) into at most 64 colour boxes, by population
       for the first 75 % of splits and by population × volume after;
    3. each target (vibrant, dark vibrant, …) takes the unused box whose
       saturation and luminance are closest to the target's, weighted 3 : 6.5,
       with population weighted 0.5; a target with no box in its ranges is
       derived from a neighbour, as node-vibrant does;
    4. `dominant` is the most populous box.

  `foreground` and `title` are the text colours node-vibrant pairs with a
  swatch (body text and title text, `#fff` or `#000` by YIQ brightness).
  `population` is the swatch's share of the counted pixels in percent.

  Pure Elixir over a pixel binary: the caller decodes and downsamples the image
  (`Barkpark.Media.ImageBackend.Vix.analyze/2`), so this module runs and is
  tested without libvips.
  """

  import Bitwise

  @sigbits 5
  @rshift 8 - @sigbits
  @max_colors 64
  @fract_by_population 0.75
  @max_iterations 1000

  # node-vibrant's DefaultGenerator targets: {name, target luma, min, max, target saturation, min, max}.
  @targets [
    {"vibrant", 0.5, 0.3, 0.7, 1.0, 0.35, 1.0},
    {"lightVibrant", 0.74, 0.55, 1.0, 1.0, 0.35, 1.0},
    {"darkVibrant", 0.26, 0.0, 0.45, 1.0, 0.35, 1.0},
    {"muted", 0.5, 0.3, 0.7, 0.3, 0.0, 0.4},
    {"lightMuted", 0.74, 0.55, 1.0, 0.3, 0.0, 0.4},
    {"darkMuted", 0.26, 0.0, 0.45, 0.3, 0.0, 0.4}
  ]

  @weight_saturation 3.0
  @weight_luma 6.5
  @weight_population 0.5

  @doc """
  The palette of an interleaved 8-bit pixel binary with `bands` channels (3 or
  4; a 4th is alpha), or nil when no pixel counts.
  """
  @spec from_pixels(binary(), 1..4) :: map() | nil
  def from_pixels(pixels, bands) when is_binary(pixels) and bands in [3, 4] do
    {histo, counted} = histogram(pixels, bands)

    if counted == 0 do
      nil
    else
      boxes = quantize(histo)
      swatches = Enum.map(boxes, &swatch/1)
      generate(swatches, counted)
    end
  end

  def from_pixels(_pixels, _bands), do: nil

  # ── histogram ────────────────────────────────────────────────────────────────

  defp histogram(pixels, bands) do
    pixels
    |> pixel_stream(bands)
    |> Enum.reduce({%{}, 0}, fn {r, g, b, a}, {histo, n} ->
      if a >= 125 and not (r > 250 and g > 250 and b > 250) do
        key = color_index(r >>> @rshift, g >>> @rshift, b >>> @rshift)
        {Map.update(histo, key, 1, &(&1 + 1)), n + 1}
      else
        {histo, n}
      end
    end)
  end

  defp pixel_stream(pixels, 3), do: for(<<r, g, b <- pixels>>, do: {r, g, b, 255})
  defp pixel_stream(pixels, 4), do: for(<<r, g, b, a <- pixels>>, do: {r, g, b, a})

  defp color_index(r, g, b), do: (r <<< (2 * @sigbits)) + (g <<< @sigbits) + b

  defp unpack(index) do
    mask = (1 <<< @sigbits) - 1
    {index >>> (2 * @sigbits) &&& mask, index >>> @sigbits &&& mask, index &&& mask}
  end

  # ── MMCQ ─────────────────────────────────────────────────────────────────────

  # A box: {r1, r2, g1, g2, b1, b2} in quantized space, inclusive.
  defp quantize(histo) do
    entries = Enum.map(histo, fn {index, count} -> {unpack(index), count} end)

    {rs, gs, bs} =
      Enum.reduce(entries, {[], [], []}, fn {{r, g, b}, _}, {rs, gs, bs} ->
        {[r | rs], [g | gs], [b | bs]}
      end)

    first = {Enum.min(rs), Enum.max(rs), Enum.min(gs), Enum.max(gs), Enum.min(bs), Enum.max(bs)}
    boxes = [box(first, entries)]

    boxes
    |> split_until(trunc(@fract_by_population * @max_colors), &population/1)
    |> split_until(@max_colors, &(population(&1) * volume(&1)))
  end

  # The box shrinks to the colours inside it, so a later cut always separates two.
  defp box(bounds, entries) do
    inside = Enum.filter(entries, fn {c, _} -> contains?(bounds, c) end)

    %{
      bounds: tight(inside, bounds),
      entries: inside,
      count: Enum.reduce(inside, 0, fn {_, n}, s -> s + n end)
    }
  end

  defp tight([], bounds), do: bounds

  defp tight(inside, _bounds) do
    {rs, gs, bs} =
      {Enum.map(inside, &elem(elem(&1, 0), 0)), Enum.map(inside, &elem(elem(&1, 0), 1)),
       Enum.map(inside, &elem(elem(&1, 0), 2))}

    {Enum.min(rs), Enum.max(rs), Enum.min(gs), Enum.max(gs), Enum.min(bs), Enum.max(bs)}
  end

  defp contains?({r1, r2, g1, g2, b1, b2}, {r, g, b}),
    do: r >= r1 and r <= r2 and g >= g1 and g <= g2 and b >= b1 and b <= b2

  defp population(%{count: n}), do: n

  defp volume(%{bounds: {r1, r2, g1, g2, b1, b2}}),
    do: (r2 - r1 + 1) * (g2 - g1 + 1) * (b2 - b1 + 1)

  defp split_until(boxes, target, priority), do: split_until(boxes, target, priority, 0)

  defp split_until(boxes, target, _priority, iteration)
       when length(boxes) >= target or iteration >= @max_iterations,
       do: boxes

  defp split_until(boxes, target, priority, iteration) do
    sorted = Enum.sort_by(boxes, priority, :desc)

    case Enum.split_with(sorted, &splittable?/1) do
      {[], _} ->
        boxes

      {[biggest | _], _} ->
        rest = List.delete(boxes, biggest)
        split_until(rest ++ median_cut(biggest), target, priority, iteration + 1)
    end
  end

  defp splittable?(%{count: n, entries: entries}), do: n > 0 and length(entries) > 1

  defp median_cut(%{bounds: {r1, r2, g1, g2, b1, b2}, entries: entries, count: total}) do
    {axis, lo, hi} =
      Enum.max_by([{0, r1, r2}, {1, g1, g2}, {2, b1, b2}], fn {_, lo, hi} -> hi - lo end)

    # The cut: the first plane where the running population passes half, moved
    # towards the far side as MMCQ does so neither half is empty.
    counts = for v <- lo..hi, do: {v, plane_count(entries, axis, v)}

    {cut, _} =
      Enum.reduce_while(counts, {lo, 0}, fn {v, n}, {_, acc} ->
        if acc + n > total / 2, do: {:halt, {v, acc + n}}, else: {:cont, {v, acc + n}}
      end)

    cut =
      if cut - lo <= hi - cut,
        do: min(hi - 1, cut + div(hi - cut, 2)),
        else: max(lo, cut - 1 - div(cut - lo, 2))

    cut = cut |> max(lo) |> min(hi - 1)

    {left, right} =
      case axis do
        0 -> {{r1, cut, g1, g2, b1, b2}, {cut + 1, r2, g1, g2, b1, b2}}
        1 -> {{r1, r2, g1, cut, b1, b2}, {r1, r2, cut + 1, g2, b1, b2}}
        2 -> {{r1, r2, g1, g2, b1, cut}, {r1, r2, g1, g2, cut + 1, b2}}
      end

    Enum.reject([box(left, entries), box(right, entries)], &(&1.count == 0))
  end

  defp plane_count(entries, axis, v) do
    Enum.reduce(entries, 0, fn {c, n}, s -> if elem(c, axis) == v, do: s + n, else: s end)
  end

  # ── swatches ─────────────────────────────────────────────────────────────────

  # A box's average colour, each channel at the centre of its quantization step.
  defp swatch(%{entries: entries, count: count}) do
    step = 1 <<< @rshift

    {r, g, b} =
      Enum.reduce(entries, {0, 0, 0}, fn {{r, g, b}, n}, {sr, sg, sb} ->
        {sr + n * (r + 0.5) * step, sg + n * (g + 0.5) * step, sb + n * (b + 0.5) * step}
      end)

    rgb = {round(r / count), round(g / count), round(b / count)}
    %{rgb: rgb, population: count, hsl: hsl(rgb)}
  end

  defp generate(swatches, counted) do
    max_pop = swatches |> Enum.map(& &1.population) |> Enum.max(fn -> 1 end)

    {found, _used} =
      Enum.reduce(@targets, {%{}, MapSet.new()}, fn {name, _, _, _, _, _, _} = target,
                                                    {acc, used} ->
        case best(swatches, target, used, max_pop) do
          nil -> {acc, used}
          s -> {Map.put(acc, name, s), MapSet.put(used, s.rgb)}
        end
      end)

    found = fill_missing(found)
    dominant = Enum.max_by(swatches, & &1.population)

    ["dominant" | Enum.map(@targets, &elem(&1, 0))]
    |> Map.new(fn
      "dominant" -> {"dominant", out(dominant, counted)}
      name -> {name, found[name] && out(found[name], counted)}
    end)
    |> Map.put("_type", "sanity.imagePalette")
  end

  defp best(swatches, {_, t_luma, min_luma, max_luma, t_sat, min_sat, max_sat}, used, max_pop) do
    swatches
    |> Enum.filter(fn %{hsl: {_, s, l}, rgb: rgb} ->
      s >= min_sat and s <= max_sat and l >= min_luma and l <= max_luma and
        not MapSet.member?(used, rgb)
    end)
    |> Enum.max_by(
      fn %{hsl: {_, s, l}, population: p} ->
        values = [
          {1 - abs(s - t_sat), @weight_saturation},
          {1 - abs(l - t_luma), @weight_luma},
          {p / max_pop, @weight_population}
        ]

        Enum.reduce(values, 0, fn {v, w}, acc -> acc + v * w end) /
          (@weight_saturation + @weight_luma + @weight_population)
      end,
      fn -> nil end
    )
  end

  # node-vibrant's generateEmptySwatches: a missing vibrant comes from dark
  # vibrant (and the reverse) at the other target luma, population 0.
  defp fill_missing(found) do
    found
    |> derive("vibrant", "darkVibrant", 0.5)
    |> derive("darkVibrant", "vibrant", 0.26)
  end

  defp derive(found, missing, from, luma) do
    case {found[missing], found[from]} do
      {nil, %{hsl: {h, s, _}}} ->
        rgb = rgb_of({h, s, luma})
        Map.put(found, missing, %{rgb: rgb, population: 0, hsl: {h, s, luma}})

      _ ->
        found
    end
  end

  defp out(%{rgb: {r, g, b} = rgb, population: p}, counted) do
    yiq = (r * 299 + g * 587 + b * 114) / 1000

    %{
      "_type" => "sanity.imagePaletteSwatch",
      "background" => hex(rgb),
      "foreground" => if(yiq < 150, do: "#fff", else: "#000"),
      "title" => if(yiq < 200, do: "#fff", else: "#000"),
      "population" => Float.round(p * 100 / counted, 2)
    }
  end

  defp hex({r, g, b}),
    do:
      "#" <>
        Enum.map_join(
          [r, g, b],
          &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
        )

  # ── colour space ─────────────────────────────────────────────────────────────

  defp hsl({r, g, b}) do
    {r, g, b} = {r / 255, g / 255, b / 255}
    max = Enum.max([r, g, b])
    min = Enum.min([r, g, b])
    l = (max + min) / 2

    if max == min do
      {0.0, 0.0, l}
    else
      d = max - min
      s = if l > 0.5, do: d / (2 - max - min), else: d / (max + min)

      h =
        cond do
          max == r -> (g - b) / d + if(g < b, do: 6, else: 0)
          max == g -> (b - r) / d + 2
          true -> (r - g) / d + 4
        end

      {h / 6, s, l}
    end
  end

  defp rgb_of({h, s, l}) do
    if s == 0 do
      v = round(l * 255)
      {v, v, v}
    else
      q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
      p = 2 * l - q

      {round(hue(p, q, h + 1 / 3) * 255), round(hue(p, q, h) * 255),
       round(hue(p, q, h - 1 / 3) * 255)}
    end
  end

  defp hue(p, q, t) do
    t = if t < 0, do: t + 1, else: t
    t = if t > 1, do: t - 1, else: t

    cond do
      t < 1 / 6 -> p + (q - p) * 6 * t
      t < 1 / 2 -> q
      t < 2 / 3 -> p + (q - p) * (2 / 3 - t) * 6
      true -> p
    end
  end
end
