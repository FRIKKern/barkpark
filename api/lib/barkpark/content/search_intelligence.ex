defmodule Barkpark.Content.SearchIntelligence do
  @moduledoc """
  Document search adapter for `Barkpark.Search.Intelligence`.

  Translates `/v1/data/search/:dataset` params into core search context.
  Studio pickers, reference fields, and public search API should use this
  module — not the core directly.
  """

  alias Barkpark.Search.Intelligence

  @surface "documents"

  # Same ceiling `Content.Query`, the document HTTP routes, and the search
  # channel use. A page past it is a table scan with nothing to return.
  @max_offset 100_000

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

  def record_interaction(scope, attrs, opts \\ []) when is_binary(scope) and is_map(attrs) do
    Intelligence.record_interaction(@surface, scope, attrs, opts)
  end

  def record_correction(scope, attrs, opts \\ []) when is_binary(scope) and is_map(attrs) do
    Intelligence.record_correction(@surface, scope, attrs, opts)
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

  # THE offset parse for the documents search surface — public because the
  # recorded offset MUST be the offset the request was SERVED at, and the only
  # way to guarantee that is for the recorder and the route to share ONE
  # function. `SearchController` reads it for `Content.search_documents/3`;
  # `context_from_params/1` reads it for the analytics event.
  #
  # The media surface gets this for free: `MediaIntelligence` reads
  # `parsed[:offset]` off the `MediaSearchParams.parse/1` result the controller
  # already computed. The documents surface has NO equivalent parser module —
  # the clamp was inline in `SearchController` — so the fix here is to clamp at
  # the door and give the door ONE definition instead of two.
  #
  # It used to be a private `parse_offset/1` doing
  # `Integer.parse(to_string(params["offset"]))`, byte-for-byte the function
  # PR #16871 deleted from `MediaIntelligence`. It diverged from the route's
  # `parse_int(params["offset"], 0) |> max(0) |> min(100_000)` on every shape
  # Phoenix can decode a query string into, with two consequences:
  #
  #   * `?offset[a]=1` -> `params["offset"]` is a MAP -> `to_string/1` raises
  #     `Protocol.UndefinedError`. The search had ALREADY succeeded (the route's
  #     parser returns the default for a map), so a served 200 became a 500
  #     inside the analytics recorder. `SearchIntelligence.record/5` evaluates
  #     `context_from_params/1` EAGERLY as a call argument, outside
  #     `Intelligence.record/6`'s rescue, so `record: false` could not shield it.
  #   * `?offset[]=0&offset[]=1` -> `to_string(["0", "1"])` is `"01"` -> 1,
  #     while the page actually served was offset 0. `Intelligence.record/6`
  #     drops any `offset > 0` as `{:skipped, :offset_page}`, so a repeated
  #     `offset` param silently suppressed the search event for a page-0 request.
  #
  # This clause set is TOTAL: every term reaches a clause, and the result is
  # always in `0..@max_offset`.
  @doc false
  @spec parse_offset(map()) :: non_neg_integer()
  def parse_offset(params) when is_map(params) do
    (params["offset"] || params[:offset])
    |> to_offset()
    |> max(0)
    |> min(@max_offset)
  end

  defp to_offset(value) when is_integer(value), do: value

  defp to_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_offset(_), do: 0
end
