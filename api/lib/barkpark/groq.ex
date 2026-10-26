defmodule Barkpark.Groq do
  @moduledoc """
  GROQ queries over a dataset: the entry point behind
  `GET|POST /w/:ws/p/:proj/v{apiVersion}/data/query/:dataset`.

  `query/3` parses the query with its parameters (`Barkpark.Groq.Parser`),
  evaluates it in a process of its own under a time and memory limit
  (`Barkpark.Groq.Evaluator` over `Barkpark.Groq.DocumentSource`), checks the
  encoded result size, and derives the sync tags.

  Limits (application env `config :barkpark, Barkpark.Groq, ...`):

    * `:max_query_bytes` — 262_144, the query text.
    * `:timeout_ms` — 10_000, wall time for one query.
    * `:max_heap_bytes` — 536_870_912, the evaluating process's heap.
    * `:max_result_bytes` — 10_485_760, the JSON-encoded result.
    * `:max_documents_per_fetch`, `:max_bytes_per_fetch`,
      `:max_documents_loaded` — see `Barkpark.Groq.DocumentSource`.
    * `:max_sync_tags` — 128, the most tags one response carries.
    * `:max_concurrent`, `:queue_ms` — how many queries evaluate at once and
      how long one waits for a slot; see `Barkpark.Groq.Slots`.

  ## Sync tags

  `bp:ds:<dataset>:type:<type>` for every type the query scanned, and
  `bp:ds:<dataset>:doc:<id>` for every document it read by id whose type was
  not scanned. These are the tags the webhook dispatcher sends on every
  mutation (`Barkpark.Webhooks.Dispatcher`), so a site can call
  `revalidateTag` with a webhook's tags. Past `:max_sync_tags`, document tags
  collapse into their type tags.
  """

  alias Barkpark.Groq.{DocumentSource, LimitError, Parser, Slots}

  @type query_error ::
          {:parse, %{description: String.t(), start: non_neg_integer(), end: non_neg_integer()}}
          | {:limit, String.t()}
          | {:eval, String.t()}
          | {:busy, String.t()}

  @doc """
  Runs `query` with `params` (decoded JSON, names without `$`). Options:

    * `:dataset` (required), `:perspective` (`:published | :drafts | :raw`)
    * `:scope_opts` — `BarkparkWeb.ScopeHelpers.scope_opts/1`
    * `:identity`, `:project_id`, `:now` — passed to the evaluator
    * `:source_map` — `:plain` or `:keyed` to also build Sanity's
      `resultSourceMap` (`Barkpark.Groq.SourceMap`); nil (the default) runs
      the query exactly as without it

  Returns `{:ok, %{result_json: iodata, sync_tags: [String.t()]}}`, plus
  `:source_map` when asked; the result is already JSON-encoded because its
  size is checked on the encoded form.
  """
  @spec query(String.t(), map(), keyword()) ::
          {:ok,
           %{
             required(:result_json) => iodata(),
             required(:sync_tags) => [String.t()],
             optional(:source_map) => map() | nil
           }}
          | {:error, query_error()}
  def query(query, params, opts) do
    max_query = limit(:max_query_bytes, 262_144)

    if byte_size(query) > max_query do
      {:error, {:limit, "the query is #{byte_size(query)} bytes; the limit is #{max_query}"}}
    else
      with {:ok, tree} <- parse(query, params) do
        run(tree, opts)
      end
    end
  end

  defp parse(query, params) do
    case Parser.parse(query, params) do
      {:ok, tree} -> {:ok, tree}
      {:error, error} -> {:error, {:parse, error}}
    end
  end

  defp run(tree, opts) do
    dataset = Keyword.fetch!(opts, :dataset)
    perspective = Keyword.get(opts, :perspective, :published)

    state =
      dataset
      |> DocumentSource.new(perspective, Keyword.get(opts, :scope_opts, []))
      |> DocumentSource.with_views(tree)

    timeout = limit(:timeout_ms, 10_000)
    max_heap_words = div(limit(:max_heap_bytes, 536_870_912), :erlang.system_info(:wordsize))

    eval_opts = [
      source_map: Keyword.get(opts, :source_map),
      now: Keyword.get(opts, :now),
      identity: Keyword.get(opts, :identity),
      project_id: Keyword.get(opts, :project_id),
      dataset: dataset
    ]

    case Slots.acquire() do
      :ok ->
        try do
          evaluate_limited(tree, state, eval_opts, timeout, max_heap_words, dataset)
        after
          Slots.release()
        end

      {:error, :busy} ->
        {:error, {:busy, "every GROQ slot on this server is busy; retry shortly"}}
    end
  end

  defp evaluate_limited(tree, state, eval_opts, timeout, max_heap_words, dataset) do
    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{size: max_heap_words, kill: true, error_logger: false})
        evaluate(tree, state, eval_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        finish(outcome, dataset)

      {:exit, :killed} ->
        {:error, {:limit, "the query used more memory than the endpoint allows"}}

      {:exit, reason} ->
        exit(reason)

      nil ->
        {:error, {:limit, "the query ran longer than #{timeout} ms"}}
    end
  end

  # Inside the task: exceptions become values so they do not take the caller
  # down with the linked task.
  defp evaluate(tree, state, eval_opts) do
    {mode, eval_opts} = Keyword.pop(eval_opts, :source_map)

    case DocumentSource.run(tree, state, eval_opts) do
      {{:ok, result}, touched} when mode in [:plain, :keyed] ->
        {{:ok, result, source_map(tree, result, state, eval_opts, mode)}, touched}

      outcome ->
        outcome
    end
  rescue
    e in LimitError -> {:limit_error, e.message}
  end

  # `resultSourceMap` (task-640e8371b8e468ce): one more pass after the rounds,
  # on the warm cache, reading anything it still needs directly. The sync tags
  # were taken from the rounds, so the pass does not change them. A pass that
  # fails leaves the map out rather than the result.
  defp source_map(tree, result, state, eval_opts, mode) do
    Process.put(:groq_src_mode, :direct)

    ctx = %Barkpark.Groq.Evaluator{
      source: {DocumentSource, state},
      now: Keyword.get(eval_opts, :now) || DateTime.utc_now(),
      identity: Keyword.get(eval_opts, :identity),
      project_id: Keyword.get(eval_opts, :project_id),
      dataset: Keyword.get(eval_opts, :dataset)
    }

    Barkpark.Groq.SourceMap.build(tree, result, ctx, mode)
  rescue
    e in LimitError -> reraise e, __STACKTRACE__
    _ -> nil
  end

  defp finish({:limit_error, message}, _dataset), do: {:error, {:limit, message}}
  defp finish({{:error, message}, _touched}, _dataset), do: {:error, {:eval, message}}

  defp finish({{:ok, result, source_map}, touched}, dataset) do
    with {:ok, out} <- finish({{:ok, result}, touched}, dataset),
         do: {:ok, Map.put(out, :source_map, source_map)}
  end

  defp finish({{:ok, result}, touched}, dataset) do
    json = Jason.encode_to_iodata!(result)
    max_result = limit(:max_result_bytes, 10_485_760)
    size = IO.iodata_length(json)

    if size > max_result do
      {:error,
       {:limit,
        "the result is #{size} bytes; the limit is #{max_result}. Project fewer fields or slice the result."}}
    else
      {:ok, %{result_json: json, sync_tags: sync_tags(dataset, touched)}}
    end
  end

  @doc false
  @spec sync_tags(String.t(), %{ids: MapSet.t(), types: MapSet.t(), id_types: map()}) :: [
          String.t()
        ]
  def sync_tags(dataset, touched) do
    types = touched.types
    id_types = Map.get(touched, :id_types, %{})

    doc_ids =
      touched.ids
      |> Enum.reject(fn id -> MapSet.member?(types, Map.get(id_types, id)) end)
      |> Enum.sort()

    type_tags = types |> Enum.sort() |> Enum.map(&"bp:ds:#{dataset}:type:#{&1}")
    doc_tags = Enum.map(doc_ids, &"bp:ds:#{dataset}:doc:#{&1}")
    max = limit(:max_sync_tags, 128)

    if length(type_tags) + length(doc_tags) <= max do
      type_tags ++ doc_tags
    else
      collapsed =
        doc_ids
        |> Enum.map(&Map.get(id_types, &1))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
        |> MapSet.union(types)
        |> Enum.sort()
        |> Enum.map(&"bp:ds:#{dataset}:type:#{&1}")

      Enum.take(collapsed, max)
    end
  end

  defp limit(key, default) do
    :barkpark
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
