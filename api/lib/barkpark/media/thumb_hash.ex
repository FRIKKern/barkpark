defmodule Barkpark.Media.ThumbHash do
  @moduledoc """
  ThumbHash, the placeholder hash Sanity stores as `metadata.thumbHash`
  (task-dbfa49e99510e0f1): a port of Evan Wallace's reference `rgbaToThumbHash`
  (MIT). `encode/3` takes an image of at most 100 x 100 pixels as RGBA bytes;
  Sanity's value is the base64 of the hash of the image thumbnailed to fit
  100 x 100. Pure Elixir, a few milliseconds per image.
  """

  import Bitwise

  @doc "The ThumbHash bytes for `w` x `h` RGBA `pixels` (w, h <= 100)."
  @spec encode(pos_integer(), pos_integer(), binary()) :: binary()
  def encode(w, h, pixels) when w <= 100 and h <= 100 and byte_size(pixels) == w * h * 4 do
    px = for <<r, g, b, a <- pixels>>, do: {r, g, b, a}

    {sr, sg, sb, sa} =
      Enum.reduce(px, {0.0, 0.0, 0.0, 0.0}, fn {r, g, b, a}, {ar, ag, ab, aa} ->
        alpha = a / 255
        {ar + alpha / 255 * r, ag + alpha / 255 * g, ab + alpha / 255 * b, aa + alpha}
      end)

    {avg_r, avg_g, avg_b} = if sa > 0, do: {sr / sa, sg / sa, sb / sa}, else: {sr, sg, sb}

    has_alpha = sa < w * h
    l_limit = if has_alpha, do: 5, else: 7
    lx = max(1, js_round(l_limit * w / max(w, h)))
    ly = max(1, js_round(l_limit * h / max(w, h)))

    lpqa =
      Enum.map(px, fn {r, g, b, a} ->
        alpha = a / 255
        r = avg_r * (1 - alpha) + alpha / 255 * r
        g = avg_g * (1 - alpha) + alpha / 255 * g
        b = avg_b * (1 - alpha) + alpha / 255 * b
        {(r + g + b) / 3, (r + g) / 2 - b, r - g, alpha}
      end)

    chan = fn i -> lpqa |> Enum.map(&elem(&1, i)) |> List.to_tuple() end

    {l_dc, l_ac, l_scale} = channel(chan.(0), w, h, max(3, lx), max(3, ly))
    {p_dc, p_ac, p_scale} = channel(chan.(1), w, h, 3, 3)
    {q_dc, q_ac, q_scale} = channel(chan.(2), w, h, 3, 3)
    {a_dc, a_ac, a_scale} = if has_alpha, do: channel(chan.(3), w, h, 5, 5), else: {0, [], 0}

    landscape = w > h

    header24 =
      js_round(63 * l_dc) ||| js_round(31.5 + 31.5 * p_dc) <<< 6 |||
        js_round(31.5 + 31.5 * q_dc) <<< 12 ||| js_round(31 * l_scale) <<< 18 |||
        if(has_alpha, do: 1, else: 0) <<< 23

    header16 =
      if(landscape, do: ly, else: lx) ||| js_round(63 * p_scale) <<< 3 |||
        js_round(63 * q_scale) <<< 9 ||| if(landscape, do: 1, else: 0) <<< 15

    head =
      [
        header24 &&& 255,
        header24 >>> 8 &&& 255,
        header24 >>> 16,
        header16 &&& 255,
        header16 >>> 8
      ] ++
        if(has_alpha, do: [js_round(15 * a_dc) ||| js_round(15 * a_scale) <<< 4], else: [])

    acs = if has_alpha, do: l_ac ++ p_ac ++ q_ac ++ a_ac, else: l_ac ++ p_ac ++ q_ac

    nibbles =
      acs
      |> Enum.map(&js_round(15 * &1))
      |> Enum.chunk_every(2, 2, [0])
      |> Enum.map(fn [lo, hi] -> lo ||| hi <<< 4 end)

    :erlang.list_to_binary(head ++ nibbles)
  end

  # The DCT of one channel: its DC term and its AC terms scaled into 0..1.
  defp channel(c, w, h, nx, ny) do
    terms =
      for cy <- 0..(ny - 1), cx <- 0..(nx - 1), cx * ny < nx * (ny - cy) do
        fx = for x <- 0..(w - 1), do: :math.cos(:math.pi() / w * cx * (x + 0.5))
        fx = List.to_tuple(fx)

        f =
          Enum.reduce(0..(h - 1), 0.0, fn y, acc ->
            fy = :math.cos(:math.pi() / h * cy * (y + 0.5))

            Enum.reduce(0..(w - 1), acc, fn x, acc ->
              acc + elem(c, x + y * w) * elem(fx, x) * fy
            end)
          end)

        {cx, cy, f / (w * h)}
      end

    [{0, 0, dc} | rest] = terms
    ac = Enum.map(rest, &elem(&1, 2))
    scale = Enum.reduce(ac, 0.0, &max(abs(&1), &2))
    ac = if scale > 0, do: Enum.map(ac, &(0.5 + 0.5 / scale * &1)), else: ac
    {dc, ac, scale}
  end

  # JavaScript's Math.round: halves go up.
  defp js_round(x), do: floor(x + 0.5)
end
