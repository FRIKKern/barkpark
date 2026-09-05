defmodule Barkpark.Media.Delivery.SearchParams do
  @moduledoc false

  @default_limit 50
  @max_limit 500

  # The pagination ceiling, shared with the document route
  # (`QueryController.index/2`, `SearchController`): `|> max(0) |> min(100_000)`.
  # It is NOT cosmetic here. `Delivery.Search.paginate_ids/2` computes
  # `fetch = limit + offset + 20`, issues `LIMIT <fetch>` with NO SQL OFFSET,
  # `Repo.all`s the rows and only then `Enum.drop(offset)` — so an unclamped
  # `?offset=5000000` materializes up to five million `{uuid, naive_datetime}`
  # tuples in the BEAM to return nothing, on a route a tokenless caller reaches.
  @max_offset 100_000

  @doc "Parse query params into search options for `Barkpark.Media.Delivery.Search`."
  @spec parse(map()) :: keyword()
  def parse(params) when is_map(params) do
    [
      limit: parse_int(params["limit"], @default_limit) |> min(@max_limit),
      offset: clamp_offset(parse_int(params["offset"], 0)),
      cursor: blank_to_nil(params["cursor"]),
      q: blank_to_nil(params["q"]),
      mime_type: blank_to_nil(params["type"] || params["mimeType"]),
      kind: blank_to_nil(params["kind"]),
      status: blank_to_nil(params["status"]),
      processing: blank_to_nil(params["processing"] || params["processingStatus"]),
      visibility: blank_to_nil(params["visibility"]),
      collection: blank_to_nil(params["collection"]),
      tags: blank_to_nil(params["tags"]),
      sort: blank_to_nil(params["sort"]) || "created-desc",
      facets: parse_facets(params["facets"]),
      facet_selections: parse_facet_selections(params)
    ]
  end

  @doc """
  Clamp a pagination offset into `0..#{@max_offset}`.

  Public because the media read paths that do NOT go through `parse/1` —
  `V1.MediaController.index/2` builds its own opts list — must land on the SAME
  ceiling; a second hand-written literal is how one door keeps the hazard.
  """
  @spec clamp_offset(integer()) :: non_neg_integer()
  def clamp_offset(offset) when is_integer(offset), do: offset |> max(0) |> min(@max_offset)

  @doc "The pagination offset ceiling."
  @spec max_offset() :: pos_integer()
  def max_offset, do: @max_offset

  defp parse_facets(nil), do: []
  defp parse_facets(""), do: []

  defp parse_facets(facets) when is_binary(facets) do
    facets
    |> String.split(",", trim: true)
    |> Enum.filter(&(&1 in Barkpark.Media.Delivery.Search.facet_fields()))
  end

  # Fail-soft on a non-binary `facets` param — Phoenix parses `?facets[]=x` to a
  # list and `?facets[k]=v` to a map, either of which would otherwise raise
  # FunctionClauseError -> 500 on GET /v1/media/search. Treat it as no facets,
  # matching the array-param posture of the sibling params (mime_type, facet
  # selections).
  defp parse_facets(_), do: []

  defp parse_facet_selections(params) do
    nested =
      case params["facet"] do
        map when is_map(map) -> map
        _ -> %{}
      end

    flat =
      params
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "facet.") end)
      |> Map.new(fn {"facet." <> field, value} -> {field, value} end)

    Map.merge(flat, nested)
    |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)
    |> Map.new()
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_int(_, default), do: default

  defp blank_to_nil(v) when is_binary(v) and v != "", do: v
  defp blank_to_nil(_), do: nil
end
