defmodule Barkpark.Search.MediaIntelligence do
  @moduledoc """
  Media DAM adapter for `Barkpark.Search.Intelligence`.

  Translates WoodWing-style v1 media search params into core search context.
  The Media Desk, picker, and `/v1/media/:dataset/search` API should use this
  module — not the core directly.
  """

  alias Barkpark.Media.Delivery.SearchParams, as: MediaSearchParams
  alias Barkpark.Search.Intelligence

  @surface "media"

  @doc false
  def surface, do: @surface

  def retention_days, do: Intelligence.retention_days()
  def prune(opts \\ []), do: Intelligence.prune(opts)

  def record(scope, params, total, duration_ms, opts \\ []) when is_binary(scope) do
    Intelligence.record(
      @surface,
      scope,
      context_from_params(scope, params),
      total,
      duration_ms,
      opts
    )
  end

  def suggestions(scope, actor_key, prefix \\ nil, opts \\ []) when is_binary(scope) do
    Intelligence.suggestions(@surface, scope, actor_key, prefix, opts)
  end

  def insights(scope, opts \\ []) when is_binary(scope) do
    Intelligence.insights(@surface, scope, opts)
  end

  def record_interaction(scope, attrs, opts \\ []) when is_binary(scope) and is_map(attrs) do
    Intelligence.record_interaction(@surface, scope, attrs, opts)
  end

  # The recorded `offset` MUST be the offset the request was SERVED at, so it is
  # read off the SAME `MediaSearchParams.parse/1` result the controller feeds to
  # `Media.search_files/2` — never re-derived from the raw params.
  #
  # It used to be re-derived by a private `parse_offset/1` doing
  # `Integer.parse(to_string(params["offset"]))`, which diverged from
  # `SearchParams.parse_int/2` on every non-binary/non-integer shape Phoenix can
  # hand a query string, with two consequences:
  #
  #   * `?offset[a]=1` → `params["offset"]` is a MAP → `to_string/1` raises
  #     `Protocol.UndefinedError`. The search itself had already succeeded
  #     (`parse_int/2`'s catch-all clause returns the default for a map), so a
  #     served 200 became a 500 inside the analytics recorder. `record/6`
  #     evaluates `context_from_params/2` EAGERLY as an argument, so the
  #     `record: false` / `disabled` skips could not shield it either.
  #   * `?offset[]=0&offset[]=1` → `to_string(["0", "1"])` is `"01"` → 1, while
  #     the page actually served was offset 0. `Intelligence.record/6` skips with
  #     `{:skipped, :offset_page}` for any `offset > 0`, so a repeated `offset`
  #     param silently suppressed the search event for a page-1 request.
  #
  # `parsed[:offset]` is already `clamp_offset(parse_int(params["offset"], 0))` —
  # total over every input shape, and by construction the served value.
  @doc false
  def context_from_params(_scope, params) when is_map(params) do
    parsed = MediaSearchParams.parse(params)

    %{
      offset: parsed[:offset],
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
end
