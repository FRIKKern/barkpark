defmodule Barkpark.Groq.DocumentSource do
  @moduledoc """
  The `Barkpark.Groq.Source` over a dataset's documents in Postgres, and the
  query runner that batches its reads.

  ## Batching

  `run/3` evaluates the query in rounds. In a round the source answers only
  from its per-query cache; every `*[...]` and every `->` it cannot answer is
  recorded and answered with an empty value. After the round the source loads
  all recorded documents in one query per distinct `*[...]` constraint set and
  one query for all missing `->` ids, then evaluates again. When a round
  records nothing, its result is final. A query therefore costs one SQL read
  per level of `->` nesting, not one per document. After `@max_rounds` rounds
  the source switches to loading on demand so a pathological query still
  finishes.

  The outermost `*[...]` filter's `_type`, `_id` and simple equality
  constraints become SQL (`Barkpark.Groq.Pushdown`); everything else runs in
  memory over the loaded documents.

  ## Scope and visibility

  Every read applies the same guards as `Content.Query`: dataset,
  workspace/project (fail-closed `Scope.scope_to_workspace/3`), row ownership,
  grants, a preview token's document list, and, for a caller without a token,
  only types whose schema is public. Documents are rendered through
  `Content.Envelope.render/3`, so field visibility redaction applies, and are
  then shaped as Sanity documents: `_id`, `_type`, `_rev`, `_createdAt`,
  `_updatedAt` and the content fields at the top level.

  ## Perspectives

    * `published` — rows whose id does not start with `drafts.`.
    * `drafts` — a draft replaces its published twin; `_id` is the published
      id and `_originalId` the stored id, as in Sanity's drafts perspective.
    * `raw` — every row with its stored id.

  ## Limits

  `Barkpark.Groq.LimitError` is raised when one `*[...]` would load more than
  `:max_documents_per_fetch` documents (default 10 000) or more than
  `:max_bytes_per_fetch` of stored content (default 32 MiB, measured with
  `pg_column_size` before anything is loaded), or the query as a whole more
  than `:max_documents_loaded` documents (default 25 000). Keys live in the
  application env `config :barkpark, Barkpark.Groq`.
  """

  @behaviour Barkpark.Groq.Source

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId, Envelope, Schema, Scope}
  alias Barkpark.Content.WriteScope
  alias Barkpark.Groq.{Evaluator, LimitError, Pushdown}
  alias Barkpark.Repo

  @max_rounds 8
  @drafts_prefix "drafts."

  @type perspective :: :published | :drafts | :raw

  @doc """
  Builds the source state. `opts` are `BarkparkWeb.ScopeHelpers.scope_opts/1`
  keywords; `perspective` is `:published`, `:drafts` or `:raw`.
  """
  @spec new(String.t(), perspective(), keyword()) :: map()
  def new(dataset, perspective, opts) do
    %{
      dataset: dataset,
      perspective: perspective,
      opts: opts,
      caller_context: Keyword.get(opts, :caller_context),
      max_per_fetch: config(:max_documents_per_fetch, 10_000),
      max_bytes_per_fetch: config(:max_bytes_per_fetch, 33_554_432),
      max_loaded: config(:max_documents_loaded, 25_000)
    }
  end

  @doc """
  Evaluates `tree` against the dataset in batched rounds. Returns the
  evaluator's `{:ok, value}` or `{:error, message}` plus what the result read:
  the types it scanned and the ids it looked up, for sync tags.
  """
  @spec run(tuple(), map(), keyword()) ::
          {{:ok, term()} | {:error, String.t()},
           %{ids: MapSet.t(), types: MapSet.t(), id_types: %{String.t() => String.t()}}}
  def run(tree, state, eval_opts) do
    Process.put(:groq_src_loaded, 0)
    Process.put(:groq_src_touched, %{ids: MapSet.new(), types: MapSet.new(), id_types: %{}})
    result = run_rounds(tree, state, eval_opts, 1)
    {result, Process.get(:groq_src_touched)}
  end

  defp run_rounds(tree, state, eval_opts, round) do
    mode = if round > @max_rounds, do: :direct, else: :collect
    Process.put(:groq_src_mode, mode)
    Process.put(:groq_src_missing, %{ids: MapSet.new(), keys: MapSet.new()})

    result = Evaluator.evaluate(tree, Keyword.put(eval_opts, :source, {__MODULE__, state}))
    missing = Process.get(:groq_src_missing)

    cond do
      mode == :direct ->
        result

      MapSet.size(missing.ids) == 0 and MapSet.size(missing.keys) == 0 ->
        result

      true ->
        load_keys(state, MapSet.to_list(missing.keys))
        load_ids(state, MapSet.to_list(missing.ids))
        run_rounds(tree, state, eval_opts, round + 1)
    end
  end

  # ── Source callbacks ─────────────────────────────────────────────────────

  @impl true
  def fetch(state, constraints) do
    key = cache_key(constraints)

    case Process.get({:groq_src_key, key}) do
      nil ->
        case Process.get(:groq_src_mode) do
          :direct ->
            load_key(state, key)
            Process.get({:groq_src_key, key})

          _ ->
            record_missing(:keys, key)
            []
        end

      docs ->
        docs
    end
  end

  @impl true
  def get(state, id) do
    case Process.get({:groq_src_doc, id}) do
      :none ->
        nil

      nil ->
        case Process.get(:groq_src_mode) do
          :direct ->
            load_ids(state, [id])
            get_cached(id)

          _ ->
            record_missing(:ids, id)
            nil
        end

      doc ->
        touch(doc)
        doc
    end
  end

  defp get_cached(id) do
    case Process.get({:groq_src_doc, id}) do
      %{} = doc ->
        touch(doc)
        doc

      _ ->
        nil
    end
  end

  defp record_missing(kind, value) do
    missing = Process.get(:groq_src_missing)
    Process.put(:groq_src_missing, Map.update!(missing, kind, &MapSet.put(&1, value)))
  end

  # A document read by id: tagged by its id unless its whole type is tagged.
  defp touch(%{"_id" => id, "_type" => type}) do
    touched = Process.get(:groq_src_touched)
    published = DraftId.published_id(id)

    Process.put(:groq_src_touched, %{
      touched
      | ids: MapSet.put(touched.ids, published),
        id_types: Map.put(touched.id_types, published, type)
    })
  end

  defp touch(_), do: :ok

  # A constraint set as a stable cache key: sorted lists, no duplicates.
  defp cache_key(c) do
    {
      c.types && c.types |> Enum.uniq() |> Enum.sort(),
      c.ids && c.ids |> Enum.uniq() |> Enum.sort(),
      c.eq |> Enum.uniq() |> Enum.sort(),
      c.any |> Enum.map(fn probes -> probes |> Enum.uniq() |> Enum.sort() end) |> Enum.sort()
    }
  end

  # ── Loading ──────────────────────────────────────────────────────────────

  defp load_key(state, key), do: load_keys(state, [key])

  # Keys that scan the same types are read in one query: their conditions are
  # OR-ed and every key is answered with the union, a superset the evaluator
  # filters per key. A subquery inside a projection therefore costs one read
  # per round, however many parent documents it runs for.
  defp load_keys(state, keys) do
    keys
    |> Enum.group_by(fn {types, _ids, _eq, _any} -> types end)
    |> Enum.each(fn {types, group} -> load_group(state, types, group) end)
  end

  defp load_group(state, types, keys) do
    condition =
      if Enum.any?(keys, &unconstrained?/1) do
        dynamic(true)
      else
        Enum.reduce(keys, dynamic(false), fn key, acc ->
          dynamic([d], ^acc or ^key_condition(key, state.perspective))
        end)
      end

    matching =
      state
      |> base_query()
      |> maybe_where_types(types)
      |> where(^condition)

    rows =
      if Enum.all?(keys, fn {_types, ids, _eq, _any} -> ids != nil end) do
        # Reads by id are bounded by the ids the query named.
        Repo.all(matching)
      else
        matching |> admit!(state) |> then(&Repo.all(from(d in Document, where: d.id in ^&1)))
      end

    docs = rows |> render(state) |> sort_by_id()
    count_loaded!(state, length(docs))
    Enum.each(docs, &cache_doc/1)

    # A read by id depends on those documents; any other read depends on every
    # document of the types it scanned, so it is tagged by type.
    if Enum.all?(keys, fn {_types, ids, _eq, _any} -> ids != nil end),
      do: Enum.each(docs, &touch/1),
      else: Enum.each(docs, &touch_type(&1["_type"]))

    if types, do: Enum.each(types, &touch_type/1)

    Enum.each(keys, &Process.put({:groq_src_key, &1}, docs))
  end

  # Sizes the read before loading it: row ids and stored content sizes only.
  # Loading first and counting after would hold the whole oversized set in the
  # evaluating process, which the heap limit then kills with a vaguer message.
  defp admit!(query, state) do
    sized =
      query
      |> select([d], {d.id, fragment("pg_column_size(?)", d.content)})
      |> limit(^(state.max_per_fetch + 1))
      |> Repo.all()

    bytes = Enum.reduce(sized, 0, fn {_id, size}, acc -> acc + (size || 0) end)

    cond do
      length(sized) > state.max_per_fetch ->
        raise LimitError,
          message:
            "one *[...] in this query matches more than #{state.max_per_fetch} documents. " <>
              "Narrow it with a _type filter or an equality on a field."

      bytes > state.max_bytes_per_fetch ->
        raise LimitError,
          message:
            "one *[...] in this query matches #{length(sized)} documents holding #{div(bytes, 1_048_576)} MiB " <>
              "of stored content; the limit is #{div(state.max_bytes_per_fetch, 1_048_576)} MiB. " <>
              "Narrow it with a _type filter or an equality on a field."

      true ->
        Enum.map(sized, &elem(&1, 0))
    end
  end

  defp unconstrained?({_types, nil, [], []}), do: true
  defp unconstrained?(_key), do: false

  defp key_condition({_types, ids, eq, any}, perspective) do
    condition = if ids, do: ids_condition(ids, perspective), else: dynamic(true)

    condition =
      Enum.reduce(eq, condition, fn {path, value}, acc ->
        dynamic(
          [d],
          ^acc and fragment("? @> ?", d.content, type(^Pushdown.nest(path, value), :map))
        )
      end)

    Enum.reduce(any, condition, fn probes, acc ->
      json = Enum.map(probes, &Jason.encode!/1)

      dynamic(
        [d],
        ^acc and
          fragment("? @> ANY(CAST(? AS jsonb[]))", d.content, type(^json, {:array, :string}))
      )
    end)
  end

  defp ids_condition(ids, :drafts) do
    all = Enum.flat_map(ids, fn id -> [id, DraftId.draft_id(id)] end)
    dynamic([d], d.doc_id in ^all)
  end

  defp ids_condition(ids, _perspective), do: dynamic([d], d.doc_id in ^ids)

  defp load_ids(_state, []), do: :ok

  defp load_ids(state, ids) do
    lookup_ids =
      case state.perspective do
        :drafts -> Enum.flat_map(ids, fn id -> [id, DraftId.draft_id(id)] end)
        _ -> ids
      end

    docs =
      state
      |> base_query()
      |> where([d], d.doc_id in ^Enum.uniq(lookup_ids))
      |> Repo.all()
      |> render(state)

    count_loaded!(state, length(docs))
    Enum.each(docs, &cache_doc/1)

    # Remember misses, so a dangling reference is not looked up again.
    Enum.each(ids, fn id ->
      if Process.get({:groq_src_doc, id}) == nil, do: Process.put({:groq_src_doc, id}, :none)
    end)
  end

  defp cache_doc(%{"_id" => id} = doc), do: Process.put({:groq_src_doc, id}, doc)

  defp touch_type(type) do
    touched = Process.get(:groq_src_touched)
    Process.put(:groq_src_touched, %{touched | types: MapSet.put(touched.types, type)})
  end

  defp count_loaded!(state, n) do
    total = Process.get(:groq_src_loaded, 0) + n
    Process.put(:groq_src_loaded, total)

    if total > state.max_loaded do
      raise LimitError,
        message: "this query reads more than #{state.max_loaded} documents. Narrow its filters."
    end
  end

  defp sort_by_id(docs), do: Enum.sort_by(docs, & &1["_id"])

  # ── SQL ──────────────────────────────────────────────────────────────────

  defp base_query(state) do
    opts = state.opts

    Document
    |> WriteScope.scope_to_dataset(state.dataset, opts)
    |> Scope.scope_to_workspace(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    # Typeless read: `scope_to_owner/2` is applied unconditionally, as
    # `Content.Query.get_documents_by_ids/3` does. Rows of types that are not
    # owner-scoped carry a NULL owner_id and always pass.
    |> Scope.scope_to_owner(state.caller_context)
    |> Scope.maybe_scope_to_grants(opts)
    |> maybe_only_doc_ids(Keyword.get(opts, :only_doc_ids))
    |> restrict_to_visible_types(state)
    |> apply_perspective(state.perspective)
  end

  defp restrict_to_visible_types(query, state) do
    if Schema.bypasses_visibility_gate?(state.caller_context) do
      query
    else
      public =
        Schema.public_type_names(
          state.dataset,
          Keyword.take(state.opts, [:workspace_id, :project_id])
        )

      where(query, [d], d.type in ^public)
    end
  end

  defp maybe_only_doc_ids(query, [_ | _] = ids) do
    where(
      query,
      [d],
      fragment(
        "regexp_replace(?, '^drafts\\.', '') = ANY(?)",
        d.doc_id,
        type(^ids, {:array, :string})
      )
    )
  end

  defp maybe_only_doc_ids(query, _), do: query

  defp apply_perspective(query, :published) do
    where(query, [d], not like(d.doc_id, ^(@drafts_prefix <> "%")))
  end

  defp apply_perspective(query, _perspective), do: query

  defp maybe_where_types(query, nil), do: query
  defp maybe_where_types(query, types), do: where(query, [d], d.type in ^types)

  # ── Rendering ────────────────────────────────────────────────────────────

  defp render(rows, state) do
    rendered = Envelope.render_many_by_type(rows, &schema_for(&1, state), state.caller_context)

    rows
    |> Enum.zip(rendered)
    |> Enum.map(fn {row, doc} -> to_sanity(row, doc) end)
    |> apply_overlay(state.perspective)
  end

  defp schema_for(type, state) do
    case Process.get({:groq_src_schema, type}) do
      {:cached, schema} ->
        schema

      nil ->
        schema =
          case Schema.get_schema_for_redaction(type, state.dataset, state.opts) do
            {:ok, schema} -> schema
            :error -> nil
          end

        Process.put({:groq_src_schema, type}, {:cached, schema})
        schema
    end
  end

  # Barkpark's envelope adds `_draft`, `_publishedId` and a `title` promoted
  # from the column; a Sanity document has none of them.
  defp to_sanity(row, doc) do
    doc = Map.drop(doc, ["_draft", "_publishedId"])

    if is_map(row.content) and Map.has_key?(row.content, "title"),
      do: doc,
      else: Map.delete(doc, "title")
  end

  defp apply_overlay(docs, :drafts) do
    docs
    |> Enum.group_by(fn d -> {d["_type"], DraftId.published_id(d["_id"])} end)
    |> Enum.map(fn {{_type, published_id}, twins} ->
      chosen = Enum.find(twins, &Content.draft?(&1["_id"])) || hd(twins)

      chosen
      |> Map.put("_originalId", chosen["_id"])
      |> Map.put("_id", published_id)
    end)
  end

  defp apply_overlay(docs, _perspective), do: docs

  defp config(key, default) do
    :barkpark
    |> Application.get_env(Barkpark.Groq, [])
    |> Keyword.get(key, default)
  end
end
