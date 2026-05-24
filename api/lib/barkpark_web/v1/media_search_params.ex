defmodule BarkparkWeb.V1.MediaSearchParams do
  @moduledoc false

  @default_limit 50
  @max_limit 500

  @doc "Parse query params into search options for `Barkpark.Media.Search`."
  @spec parse(map()) :: keyword()
  def parse(params) when is_map(params) do
    [
      limit: parse_int(params["limit"], @default_limit) |> min(@max_limit),
      offset: parse_int(params["offset"], 0),
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
    |> Enum.filter(&(&1 in Barkpark.Media.Search.facet_fields()))
  end

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
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
