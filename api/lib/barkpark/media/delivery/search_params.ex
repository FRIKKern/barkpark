defmodule Barkpark.Media.Delivery.SearchParams do
  @moduledoc false

  @default_limit 50
  @max_limit 500

  # `offset` was clamped to nothing while `limit` was clamped to 500. That is not
  # a "the database skips more rows" cost: `Delivery.Search.paginate_ids/2` asks
  # Postgres for `limit(limit + offset + 20)` and then does `Enum.uniq_by/2` and
  # `Enum.drop(offset)` IN THE BEAM, so `?offset=5000000` materialises ~5M
  # {uuid, timestamp} tuples plus a 5M-key uniqueness map in one request's heap.
  # GET /v1/media/:dataset/search sits on the `:api` pipeline (OptionalToken), so
  # no credential is needed to ask for that.
  #
  # 10_000 is the bound because deep paging here is the cursor's job, not the
  # offset's: this module already parses `cursor`, and `Search.next_cursor/1`
  # hands one back on every page. An offset window of 10k rows covers every
  # UI-shaped "jump to page N" caller (200 pages at the max limit) while capping
  # the worst-case materialisation at 10_520 rows. Clamp rather than 400 for the
  # same reason `limit` clamps: a well-behaved caller that overshoots keeps
  # working, and a scanner learns nothing from the response.
  @max_offset 10_000

  @doc "Parse query params into search options for `Barkpark.Media.Delivery.Search`."
  @spec parse(map()) :: keyword()
  def parse(params) when is_map(params) do
    [
      limit: parse_int(params["limit"], @default_limit) |> min(@max_limit),
      offset: parse_int(params["offset"], 0) |> min(@max_offset),
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
