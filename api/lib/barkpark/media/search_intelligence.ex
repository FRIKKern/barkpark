defmodule Barkpark.Media.SearchIntelligence do
  @moduledoc """
  Media DAM adapter for `Barkpark.Search.Intelligence`.

  Translates WoodWing-style v1 media search params into core search context.
  The Media Desk, picker, and `/v1/media/:dataset/search` API should use this
  module — not the core directly.
  """

  alias Barkpark.Search.Intelligence
  alias BarkparkWeb.V1.MediaSearchParams

  @surface "media"

  @doc false
  def surface, do: @surface

  def retention_days, do: Intelligence.retention_days()
  def prune(opts \\ []), do: Intelligence.prune(opts)

  def record(scope, params, total, duration_ms, opts \\ []) when is_binary(scope) do
    Intelligence.record(@surface, scope, context_from_params(scope, params), total, duration_ms, opts)
  end

  def suggestions(scope, actor_key, prefix \\ nil, opts \\ []) when is_binary(scope) do
    Intelligence.suggestions(@surface, scope, actor_key, prefix, opts)
  end

  def insights(scope, opts \\ []) when is_binary(scope) do
    Intelligence.insights(@surface, scope, opts)
  end

  @doc false
  def context_from_params(_scope, params) when is_map(params) do
    parsed = MediaSearchParams.parse(params)

    %{
      offset: parse_offset(params),
      query: display_query(parsed, filters_snapshot(parsed)),
      filters: filters_snapshot(parsed)
    }
  end

  defp display_query(parsed, _filters) do
    case parsed[:q] do
      q when is_binary(q) -> String.trim(q)
      _ -> ""
    end
  end

  defp filters_snapshot(parsed) do
    selections = parsed[:facet_selections] || %{}

    base =
      %{
        "kind" => first_present([parsed[:kind], selections["kind"]]),
        "collection" => parsed[:collection],
        "facets" =>
          selections
          |> Map.drop(["kind"])
          |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
          |> Map.new()
      }

    base
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] or (is_map(v) and map_size(v) == 0) end)
    |> Map.new()
  end

  defp first_present(values), do: Enum.find(values, fn v -> v not in [nil, ""] end)

  defp parse_offset(params) do
    case params["offset"] do
      nil -> 0
      value ->
        case Integer.parse(to_string(value)) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end
    end
  end
end
