defmodule Barkpark.Content.SearchIntelligence do
  @moduledoc """
  Document search adapter for `Barkpark.Search.Intelligence`.

  Translates `/v1/data/search/:dataset` params into core search context.
  Studio pickers, reference fields, and public search API should use this
  module — not the core directly.
  """

  alias Barkpark.Search.Intelligence

  @surface "documents"

  @doc false
  def surface, do: @surface

  def retention_days, do: Intelligence.retention_days()
  def prune(opts \\ []), do: Intelligence.prune(opts)

  def record(scope, params, total, duration_ms, opts \\ []) when is_binary(scope) do
    Intelligence.record(@surface, scope, context_from_params(params), total, duration_ms, opts)
  end

  def suggestions(scope, actor_key, prefix \\ nil, opts \\ []) when is_binary(scope) do
    Intelligence.suggestions(@surface, scope, actor_key, prefix, opts)
  end

  def insights(scope, opts \\ []) when is_binary(scope) do
    Intelligence.insights(@surface, scope, opts)
  end

  @doc false
  def context_from_params(params) when is_map(params) do
    %{
      offset: parse_offset(params),
      query: display_query(params),
      filters: filters_snapshot(params)
    }
  end

  defp display_query(%{"q" => q}) when is_binary(q), do: String.trim(q)
  defp display_query(%{q: q}) when is_binary(q), do: String.trim(q)
  defp display_query(_), do: ""

  defp filters_snapshot(params) do
    %{
      "type" => blank_to_nil(params["type"] || params[:type]),
      "perspective" => perspective_label(params)
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp perspective_label(params) do
    case params["perspective"] || params[:perspective] do
      "drafts" -> "drafts"
      "raw" -> "raw"
      _ -> "published"
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp parse_offset(params) do
    value = params["offset"] || params[:offset]

    case value do
      nil ->
        0

      value ->
        case Integer.parse(to_string(value)) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end
    end
  end
end
