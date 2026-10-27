defmodule BarkparkWeb.ListenFilter do
  @moduledoc """
  The server-side narrowing of `GET /v1/data/listen/:dataset` (task-684369333a0f0deb).

  The SDK (`client.listen(type, filter, {perspective})`) and `bp listen` have
  always sent `?types=`, `filter[field]=value` and `?perspective=`. The
  controller read none of them, so every subscriber got every mutation in
  scope. This module parses them once at connect and decides per event.

    * `?types=a,b`: only mutations whose `_type` is in the set. Absent or
      blank means every type.
    * `?ids=a,b`: only mutations of those documents (task-66d495ccd23e7f16).
      An id names the document, so `a` and `drafts.a` both match either
      spelling; add `?perspective=published` to drop the draft writes. Absent
      or blank means every document.
    * `?perspective=`:
      * `published` drops draft writes (a `drafts.` document id).
      * `drafts` and `raw` pass both.
      * Absent keeps today's stream, which is every event.
      * Anything else is refused.
    * `filter[field]=value`: equality on the document the subscriber is
      allowed to see.
      * A comma-separated value means "any of", which is how the SDK encodes
        an array.
      * A dotted field walks nested objects.
      * An array field matches when any element equals, whether it is a bare
        value or a `{_ref}` object.
      * An operator form (`filter[f][op]=…`) is refused. The stream has no
        query engine behind it, so honouring only some operators would be a
        silent over-send.

  ORDER IS LOAD-BEARING. `types` and `perspective` read only event metadata,
  so they run first and skip the per-subscriber re-render. `filter` runs on the
  REDACTED result, after `ListenController.redacted_result/4` or `live_result/4`.
  A filter on a field the caller cannot see therefore never matches, so it
  cannot be used to probe that field's value.

  An event whose result is `nil` (nothing left to render) passes a `filter`.
  The filter cannot be evaluated against it, and a subscriber keeping a cache
  must not miss a removal.
  """

  alias Barkpark.Content.DraftId
  alias Barkpark.Groq.GeoShape

  @perspectives ["published", "drafts", "raw"]

  # `project_id` is not a query param: the controller sets it from the URL
  # (`narrow_to_project/2`) when the stream was opened on a
  # `/w/:ws/p/:proj/...` path (owner ruling #50, task-d60479a7749b0ca5).
  #
  # `only_doc_ids` is ALSO not a query param: the controller sets it from
  # `scope[:only_doc_ids]` (`narrow_to_only_doc_ids/2`, task-78dc25a4f117fa07)
  # when the connection carries a doc-scoped `Barkpark.PreviewToken` — a
  # SERVER-ENFORCED floor the caller cannot widen, unlike `ids` (a caller's
  # own `?ids=` narrowing). The two compose as an AND in `id_ok?/2` below:
  # a token scoped to {A, B} that also asks `?ids=A,C` sees only A.
  defstruct types: nil,
            ids: nil,
            perspective: nil,
            filter: %{},
            project_id: nil,
            only_doc_ids: nil,
            query: nil,
            include_result: true,
            matched: nil

  @type t :: %__MODULE__{
          types: MapSet.t(String.t()) | nil,
          ids: MapSet.t(String.t()) | nil,
          perspective: String.t() | nil,
          filter: %{optional(String.t()) => [String.t()]},
          project_id: String.t() | nil,
          only_doc_ids: MapSet.t(String.t()) | nil,
          query: %{text: String.t(), params: map(), expr: tuple()} | nil,
          include_result: boolean(),
          matched: MapSet.t(String.t()) | :unknown | nil
        }

  @doc "The `?perspective` values the listen route honours."
  def perspectives, do: @perspectives

  @doc """
  Parse the listen query params. Returns `{:ok, filter}`, or
  `{:error, {:perspective, value}}` / `{:error, {:filter, message, details}}`
  for a request the stream must refuse before it opens.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(params) when is_map(params) do
    with {:ok, perspective} <- parse_perspective(Map.get(params, "perspective")),
         {:ok, filter} <- parse_filter(Map.get(params, "filter")),
         {:ok, query} <- parse_query(Map.get(params, "query"), params) do
      {:ok,
       %__MODULE__{
         types: parse_types(Map.get(params, "types")),
         ids: parse_ids(Map.get(params, "ids")),
         perspective: perspective,
         filter: filter,
         query: query,
         include_result: Map.get(params, "includeResult") not in ["false", false]
       }}
    end
  end

  # ── `?query=` (task-72331698ada8a2f6) ──────────────────────────────────────
  #
  # `@sanity/client`'s `listen(query, params, opts)` sends the GROQ query it
  # listens to, `*[<filter>]`, with its parameters as `$name=<json>`, and
  # `includeResult`. As on Sanity, only a mutation whose document matches the
  # filter before or after the change is sent, with its `transition`:
  # `appear` (matches now, did not before), `update` (matched and matches) or
  # `disappear` (matched, no longer does). The filter only NARROWS: it runs
  # after every existing fence, on the document as this subscriber may see it
  # (`pass_result?/2`'s rule), so a field the caller cannot read never
  # matches. It is evaluated on that one document: a `->` or a subquery inside
  # the filter reads nothing and answers null, so such a filter can send less
  # than Sanity, never more.
  defp parse_query(nil, _params), do: {:ok, nil}
  defp parse_query("", _params), do: {:ok, nil}

  defp parse_query(text, params) when is_binary(text) do
    with {:ok, groq_params} <- groq_params(params),
         {:ok, tree} <- parse_groq(text, groq_params) do
      case listen_filter_expr(tree) do
        {:ok, expr} -> geo_affordable(%{text: text, params: groq_params, expr: expr})
        :ignore -> {:ok, nil}
      end
    end
  end

  defp parse_query(_other, _params),
    do: {:error, {:filter, "query must be a GROQ string", %{parameter: "query"}}}

  defp groq_params(params) do
    params
    |> Enum.filter(fn {key, _} -> is_binary(key) and String.starts_with?(key, "$") end)
    |> Enum.reduce_while({:ok, %{}}, fn {"$" <> name, raw}, {:ok, acc} ->
      case Jason.decode(to_string(raw)) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, name, value)}}

        _ ->
          {:halt,
           {:error, {:filter, "parameter $#{name} is not JSON", %{parameter: "$" <> name}}}}
      end
    end)
  end

  defp parse_groq(text, groq_params) do
    case Barkpark.Groq.Parser.parse(text, groq_params) do
      {:ok, tree} -> {:ok, tree}
      {:error, error} -> {:error, {:filter, "query: #{error.description}", %{parameter: "query"}}}
    end
  end

  # The `*[<filter>]` a listen query is built on. Sanity applies the filter and
  # ignores what follows it (a projection, `| order()`, a slice); it accepts any
  # other query too (`count(*)` opens a stream). Such a query narrows nothing
  # here (`:ignore`), which is the stream as it was before `query` was read,
  # so no caller is refused for its shape. A query that does not parse is a
  # 400, as Sanity answers it.
  defp listen_filter_expr({:memo, inner}), do: listen_filter_expr(inner)
  defp listen_filter_expr({:group, inner}), do: listen_filter_expr(inner)
  defp listen_filter_expr({:filter, {:everything}, expr}), do: {:ok, expr}
  defp listen_filter_expr({:map, base, _mapped}), do: listen_filter_expr(base)
  defp listen_filter_expr({:projection, base, _obj}), do: listen_filter_expr(base)
  defp listen_filter_expr({:pipe, base, _name, _args}), do: listen_filter_expr(base)
  defp listen_filter_expr({:slice, base, _l, _r, _inclusive?}), do: listen_filter_expr(base)
  defp listen_filter_expr({:elem, base, _index}), do: listen_filter_expr(base)
  defp listen_filter_expr(_tree), do: :ignore

  # ── Geo budget (task-04f37760a2598bbf) ───────────────────────────────────
  #
  # The filter runs once per event that passes the fences, in this listener's
  # process. Each event gets `@geo_budget` position pairs for its
  # geo::contains / geo::intersects calls: one worst-case call at the
  # 1000-position cap, about 0.2 s of CPU. A filter that could pass that on
  # some event is refused at open: each call site costs its literal operands'
  # positions, and an operand read from the document counts at the cap. A call
  # run per array element (`areas[geo::contains($b, @)]`) can still pass it;
  # that event ends the stream with `channelError` (`query_match?/2`), never a
  # silent false.
  @geo_budget 1_000_000

  defp geo_affordable(%{expr: expr} = q) do
    case geo_cost(expr) do
      cost when cost > @geo_budget ->
        {:error,
         {:filter,
          "query: its geo::contains() and geo::intersects() calls may cost #{cost} position " <>
            "pairs per event, past the listen budget of #{@geo_budget}; a field counts as a " <>
            "shape of #{GeoShape.max_positions()} positions", %{parameter: "query"}}}

      _ ->
        {:ok, q}
    end
  end

  defp geo_cost({:func, "geo", name, [a, b]} = node) when name in ["contains", "intersects"],
    do: operand_positions(a) * operand_positions(b) + children_cost(node)

  defp geo_cost(node) when is_tuple(node), do: children_cost(node)
  defp geo_cost(list) when is_list(list), do: list |> Enum.map(&geo_cost/1) |> Enum.sum()
  defp geo_cost(_), do: 0

  defp children_cost(node), do: node |> Tuple.to_list() |> geo_cost()

  defp operand_positions({:value, v}), do: GeoShape.count_positions(v)
  defp operand_positions({:func, "geo", "latLng", _}), do: 1
  defp operand_positions(_), do: GeoShape.max_positions()

  @doc """
  Decide one event under `?query=`: `{:send, transition, filter}` with
  `"appear"`, `"update"` or `"disappear"`, or `{:drop, filter}`. `result` is
  the document as this subscriber may see it (nil when deleted or hidden).
  The returned filter carries the updated set of matching document ids.
  Without a query every event is sent with no transition (`nil`). A filter
  past its geo budget on this event answers `{:limit, message, filter}`: the
  stream ends with `channelError`.
  """
  @spec query_step(t(), String.t(), map() | nil) ::
          {:send, String.t() | nil, t()} | {:drop, t()} | {:limit, String.t(), t()}
  def query_step(%__MODULE__{query: nil} = f, _doc_id, _result), do: {:send, nil, f}

  def query_step(%__MODULE__{query: q} = f, doc_id, result) do
    case query_match?(q, result) do
      {:limit, message} -> {:limit, message, f}
      now? -> step(f, doc_id, now?)
    end
  end

  defp step(%__MODULE__{matched: matched} = f, doc_id, now?) do
    before? = if is_struct(matched, MapSet), do: MapSet.member?(matched, doc_id), else: false

    matched =
      cond do
        not is_struct(matched, MapSet) -> matched
        now? -> MapSet.put(matched, doc_id)
        true -> MapSet.delete(matched, doc_id)
      end

    f = %{f | matched: matched}

    cond do
      now? and before? -> {:send, "update", f}
      now? -> {:send, "appear", f}
      before? -> {:send, "disappear", f}
      true -> {:drop, f}
    end
  end

  @doc """
  Whether the redacted `result` matches the listen query (nil never does), or
  `{:limit, message}` when the filter passed a limit on this document (its
  geo budget, a shape past the position cap).
  """
  @spec query_match?(map() | nil, map() | nil) :: boolean() | {:limit, String.t()}
  def query_match?(nil, _result), do: true
  def query_match?(_q, nil), do: false

  def query_match?(%{expr: expr}, result) when is_map(result) do
    ctx = %Barkpark.Groq.Evaluator{
      source: Barkpark.Groq.MemorySource.new([result]),
      now: DateTime.utc_now()
    }

    GeoShape.reset_budget(@geo_budget)
    Barkpark.Groq.Evaluator.eval(expr, %{value: result, parent: nil, hidden: false}, ctx) === true
  rescue
    e in Barkpark.Groq.LimitError -> {:limit, e.message}
    _ -> false
  end

  def query_match?(_q, _result), do: false

  defp parse_types(v) when is_binary(v) do
    case v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> MapSet.new(list)
    end
  end

  defp parse_types(list) when is_list(list),
    do: list |> Enum.filter(&is_binary/1) |> Enum.join(",") |> parse_types()

  defp parse_types(_), do: nil

  # Stored as published ids, so `a` and `drafts.a` name the same document.
  defp parse_ids(v) do
    case parse_types(v) do
      nil -> nil
      set -> MapSet.new(set, &DraftId.published_id/1)
    end
  end

  defp parse_perspective(nil), do: {:ok, nil}
  defp parse_perspective(v) when v in @perspectives, do: {:ok, v}
  defp parse_perspective(v), do: {:error, {:perspective, v}}

  defp parse_filter(nil), do: {:ok, %{}}

  defp parse_filter(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {field, value}, {:ok, acc} when is_binary(field) and is_binary(value) ->
        values = value |> String.split(",") |> Enum.map(&String.trim/1)
        {:cont, {:ok, Map.put(acc, field, values)}}

      {field, value}, _acc ->
        {:halt,
         {:error,
          {:filter,
           "the listen stream supports equality filters only " <>
             "(filter[field]=value, comma-separated for any of); " <>
             "filter[#{field}] carried #{inspect(value)}", %{parameter: "filter[#{field}]"}}}}
    end)
  end

  defp parse_filter(other) do
    {:error,
     {:filter,
      "the listen stream supports equality filters only (filter[field]=value); " <>
        "got filter=#{inspect(other)}", %{parameter: "filter"}}}
  end

  @doc """
  Metadata gate: `true` when the event's type and document id pass `types` and
  `perspective`. Cheap, and runs before the per-subscriber re-render.
  """
  @spec pass_meta?(t(), %{type: term(), doc_id: term()}) :: boolean()
  def pass_meta?(%__MODULE__{} = f, %{type: type, doc_id: doc_id} = event) do
    type_ok?(f.types, type) and id_ok?(f.ids, doc_id) and
      id_ok?(f.only_doc_ids, doc_id) and
      perspective_ok?(f.perspective, doc_id) and project_ok?(f.project_id, event)
  end

  @doc """
  Narrow the stream to one project (owner ruling #50). Every project's
  dataset is usually named `production`, so a stream keyed by workspace and
  dataset name carried sibling projects' changes. A stream opened on a
  `/w/:ws/p/:proj/...` URL now carries only that project's events; a flat
  `/v1/...` stream is left workspace-wide (`nil`).
  """
  @spec narrow_to_project(t(), String.t() | nil) :: t()
  def narrow_to_project(%__MODULE__{} = f, project_id) when is_binary(project_id),
    do: %{f | project_id: project_id}

  def narrow_to_project(%__MODULE__{} = f, _), do: f

  @doc """
  Narrow the stream to a `Barkpark.PreviewToken`'s own `doc_ids` claim
  (task-78dc25a4f117fa07, owner ruling #17's listen twin). This is a
  SERVER-ENFORCED floor, not a caller-chosen narrowing like `ids` above — a
  doc-scoped preview token's connection never forwards another document's
  event, on either the live leg or the Last-Event-ID replay leg (both run
  `pass_meta?/2`). `ids` already published-normalises via `DraftId` at parse
  time; `only_doc_ids` is handed the SAME normalised set `ScopeHelpers`
  already built (`scope[:only_doc_ids]`), so no second normalisation runs
  here — `nil`/`[]` (no token scope, or an empty-doc_ids dataset-wide token)
  leaves the stream unnarrowed, exactly like `narrow_to_project/2`'s `nil` arm.
  """
  @spec narrow_to_only_doc_ids(t(), [String.t()] | nil) :: t()
  def narrow_to_only_doc_ids(%__MODULE__{} = f, [_ | _] = ids),
    do: %{f | only_doc_ids: MapSet.new(ids)}

  def narrow_to_only_doc_ids(%__MODULE__{} = f, _), do: f

  # An event with no project (a shared-layer or pre-tenancy row) is not this
  # project's business either.
  defp project_ok?(nil, _event), do: true
  defp project_ok?(project_id, event), do: Map.get(event, :project_id) == project_id

  defp id_ok?(nil, _doc_id), do: true

  defp id_ok?(ids, doc_id) when is_binary(doc_id),
    do: MapSet.member?(ids, DraftId.published_id(doc_id))

  defp id_ok?(_ids, _doc_id), do: false

  defp type_ok?(nil, _type), do: true
  defp type_ok?(types, type), do: MapSet.member?(types, type)

  defp perspective_ok?("published", doc_id) when is_binary(doc_id),
    do: not String.starts_with?(doc_id, "drafts.")

  defp perspective_ok?(_, _), do: true

  @doc """
  Content gate: `true` when the REDACTED result satisfies every `filter` clause.
  A `nil` result passes (see the moduledoc).
  """
  @spec pass_result?(t(), map() | nil) :: boolean()
  def pass_result?(%__MODULE__{filter: filter}, _result) when map_size(filter) == 0, do: true
  def pass_result?(%__MODULE__{}, nil), do: true

  def pass_result?(%__MODULE__{filter: filter}, result) when is_map(result) do
    Enum.all?(filter, fn {field, wanted} -> matches?(dig(result, field), wanted) end)
  end

  def pass_result?(_, _), do: false

  defp dig(doc, field) do
    case Map.fetch(doc, field) do
      {:ok, v} ->
        v

      :error ->
        field
        |> String.replace_prefix("content.", "")
        |> String.split(".")
        |> Enum.reduce_while(doc, fn seg, acc ->
          case acc do
            %{} -> {:cont, Map.get(acc, seg)}
            _ -> {:halt, nil}
          end
        end)
    end
  end

  defp matches?(nil, _wanted), do: false
  defp matches?(list, wanted) when is_list(list), do: Enum.any?(list, &matches?(&1, wanted))
  defp matches?(%{"_ref" => ref}, wanted), do: matches?(ref, wanted)
  defp matches?(v, _wanted) when is_map(v), do: false
  defp matches?(v, wanted), do: to_string(v) in wanted
end
