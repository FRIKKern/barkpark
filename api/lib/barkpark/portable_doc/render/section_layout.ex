defmodule Barkpark.PortableDoc.Render.SectionLayout do
  @moduledoc false

  def grid(%{"layout" => %{"mode" => "grid"} = layout}) do
    tracks = grid_tracks(Map.get(layout, "tracks"))
    gap = gap_token_var(Map.get(layout, "gap"))
    %{style: "--bp-tracks:#{tracks};--bp-grid-gap:#{gap}"}
  end

  def grid(_block), do: nil

  def frame_class(%{"variant" => "framed"}), do: "bp-section--framed"
  def frame_class(%{"variant" => "wide"}), do: "bp-section--wide"
  def frame_class(_block), do: nil

  def cell_style(child) when is_map(child) do
    parts =
      []
      |> put_order(Map.get(child, "order"))
      |> put_span(Map.get(child, "span"))

    case parts do
      [] -> nil
      values -> Enum.join(values, ";")
    end
  end

  def cell_style(_child), do: nil

  def cell_order(child) when is_map(child), do: order_int(Map.get(child, "order")) || 0
  def cell_order(_child), do: 0

  def stack_rules?(block, style) do
    not (style == :article and is_nil(Map.get(block, "title")) and opens_with_heading?(block))
  end

  defp opens_with_heading?(%{"blocks" => [%{"type" => "heading"} | _]}), do: true
  defp opens_with_heading?(_block), do: false

  defp grid_tracks(n) when is_integer(n) and n > 0, do: n

  defp grid_tracks(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> 2
    end
  end

  defp grid_tracks(_), do: 2

  defp put_span(parts, span) do
    case span_int(span) do
      nil -> parts
      n -> ["grid-column:span #{n}" | parts]
    end
  end

  defp put_order(parts, order) do
    case order_int(order) do
      nil -> parts
      k -> ["order:#{k}" | parts]
    end
  end

  defp span_int(n) when is_integer(n) and n > 0, do: n

  defp span_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp span_int(_), do: nil

  defp order_int(n) when is_integer(n), do: n

  defp order_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp order_int(_), do: nil

  defp gap_token_var("none"), do: "var(--bp-space-none,0)"
  defp gap_token_var("sm"), do: "var(--bp-space-sm,0.8rem)"
  defp gap_token_var("md"), do: "var(--bp-space-md,1.6rem)"
  defp gap_token_var("lg"), do: "var(--bp-space-lg,2.4rem)"
  defp gap_token_var(_), do: "var(--bp-space-md,1.6rem)"
end
