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

  The constraints `Barkpark.Groq.Pushdown` reads off each `*[...]` filter
  become SQL: `_type`, `_id`, field equalities and array membership as JSON
  containment on `content`, and `references()` against an expression index
  over the `_ref` values in `content`. Everything else runs in memory over the
  loaded documents. An equality on `title` reads the `documents.title`
  column, where the writer keeps it. Containment uses `documents_content_path_idx`
  (`20260702130000_add_documents_content_gin_index.exs`); the `_ref` index is
  `20261013180000_add_documents_groq_pushdown_indexes.exs`.

  ## Scope and visibility

  Every read applies the same guards as `Content.Query`: dataset,
  workspace/project (fail-closed `Scope.scope_to_workspace/3`), row ownership,
  grants, a preview token's document list, and, for a caller without a token,
  only types whose schema is public. Documents are rendered through
  `Content.Envelope.render/3`, so field visibility redaction applies, and are
  then shaped as Sanity documents: `_id`, `_type`, `_rev`, `_createdAt`,
  `_updatedAt`, `title` and the content fields at the top level.

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
  than `:max_documents_loaded` documents (default 25 000). A `count(*[...])`
  keeps no documents: SQL counts it, or `scan_count/4` reads it in chunks, so
  these limits do not apply to it. Keys live in the application env
  `config :barkpark, Barkpark.Groq`.
  """

  @behaviour Barkpark.Groq.Source

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId, Envelope, Schema, Scope}
  alias Barkpark.Content.WriteScope
  alias Barkpark.Groq.{Evaluator, LimitError, Pushdown}
  alias Barkpark.Repo

  @max_rounds 8
  @scan_chunk 500
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
    Process.put(:groq_src_missing, %{ids: MapSet.new(), keys: MapSet.new(), counts: MapSet.new()})

    result = Evaluator.evaluate(tree, Keyword.put(eval_opts, :source, {__MODULE__, state}))
    missing = Process.get(:groq_src_missing)

    cond do
      mode == :direct ->
        result

      MapSet.size(missing.ids) == 0 and MapSet.size(missing.keys) == 0 and
          MapSet.size(missing.counts) == 0 ->
        result

      true ->
        load_counts(state, MapSet.to_list(missing.counts))
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

  # A count is answered in SQL only when it equals the number of documents
  # the evaluator would load: the filter is exact (`Pushdown.exact/2`), it
  # names its types, and every field path it tests is one this caller can
  # read on each of those types. SQL reads the stored fields, so a filter on
  # a field that rendering hides from this caller would count documents the
  # evaluator cannot match.
  @impl true
  def count(state, constraints) do
    cond do
      constraints.types == nil or "paper" in constraints.types ->
        :error

      not Enum.all?(constraints.types, &reads_filter_paths?(&1, constraints, state)) ->
        :error

      true ->
        key = cache_key(constraints)

        case Process.get({:groq_src_count, key}) do
          nil ->
            case Process.get(:groq_src_mode) do
              :direct ->
                load_counts(state, [key])
                {:ok, Process.get({:groq_src_count, key})}

              _ ->
                record_missing(:counts, key)
                {:ok, 0}
            end

          n ->
            {:ok, n}
        end
    end
  end

  # A count whose filter SQL cannot match exactly reads the rows SQL narrows
  # to in chunks of `@scan_chunk` and keeps only the running total, so it is
  # not held to the per-fetch or per-query document limits; the query's
  # timeout still bounds it. A scan whose filter recorded something to load
  # this round counted without it, so its result is not kept.
  @impl true
  def scan_count(state, constraints, cache, keep?) do
    key = cache_key(constraints)

    case cache && Process.get({:groq_src_scan, key, cache}) do
      n when is_integer(n) ->
        {:ok, n}

      _ ->
        missing = Process.get(:groq_src_missing)
        n = scan(state, key, keep?)

        if cache != nil and Process.get(:groq_src_missing) == missing,
          do: Process.put({:groq_src_scan, key, cache}, n)

        {:ok, n}
    end
  end

  # True when rendering a document of `type` for this caller keeps every
  # field the filter's equalities and checks read. When the type hides no
  # field from the caller, nothing more is asked. Otherwise each path is
  # judged by `Envelope.field_readable?/3`, which walks every segment, so a
  # filter on another field of the same type still counts in SQL.
  defp reads_filter_paths?(type, constraints, state) do
    case filter_paths(constraints) do
      [] ->
        true

      paths ->
        schema = schema_for(type, state)

        Envelope.renders_all_fields?(schema, state.caller_context) or
          Enum.all?(paths, &path_readable?(schema, &1, state.caller_context))
    end
  end

  defp filter_paths(constraints) do
    eq = Enum.map(constraints.eq, fn {path, _value} -> path end)

    checks =
      Enum.map(constraints.checks, fn
        {:length, path, _op, _n} -> path
        {:defined, path, _index} -> path
      end)

    Enum.uniq(eq ++ checks)
  end

  # `field_readable?/3` takes a dotted name, so a segment holding a dot
  # cannot be judged and is treated as unreadable.
  defp path_readable?(schema, path, caller_context) do
    Enum.all?(path, &(is_binary(&1) and not String.contains?(&1, "."))) and
      Envelope.field_readable?(schema, Enum.join(path, "."), caller_context)
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
      c.any |> Enum.map(fn probes -> probes |> Enum.uniq() |> Enum.sort() end) |> Enum.sort(),
      c.checks |> Enum.uniq() |> Enum.sort()
    }
  end

  # ── Loading ──────────────────────────────────────────────────────────────

  # All counts of a round in one statement: a UNION ALL of one `count(*)` per
  # constraint set. A count reads no document, so it is not held to the
  # per-fetch limits.
  defp load_counts(_state, []), do: :ok

  defp load_counts(state, keys) do
    keys = Enum.with_index(keys)

    [first | rest] =
      Enum.map(keys, fn {{types, ids, eq, _any, checks}, i} ->
        state
        |> counted_rows()
        |> maybe_where_types(types)
        |> where(^exact_condition(ids, eq, checks, state.perspective))
        |> select([d], %{i: type(^i, :integer), n: count(d.id)})
      end)

    counts =
      rest
      |> Enum.reduce(first, fn q, acc -> union_all(acc, ^q) end)
      |> Repo.all()
      |> Map.new(&{&1.i, &1.n})

    Enum.each(keys, fn {{types, _ids, _eq, _any, _checks} = key, i} ->
      Process.put({:groq_src_count, key}, Map.get(counts, i, 0))
      Enum.each(types || [], &touch_type/1)
    end)
  end

  # The rows the evaluator would see. In the drafts perspective a published
  # row whose draft is visible to this caller is replaced by that draft, so
  # it is not counted.
  defp counted_rows(%{perspective: :drafts} = state) do
    twins =
      state
      |> base_query()
      |> where(
        [t],
        t.type == parent_as(:doc).type and
          t.doc_id == fragment("'drafts.' || ?", parent_as(:doc).doc_id)
      )
      |> select([t], 1)

    state
    |> base_query(from(d in Document, as: :doc))
    |> where([d], like(d.doc_id, ^(@drafts_prefix <> "%")) or not exists(twins))
  end

  defp counted_rows(state), do: base_query(state)

  # `a.b == v` exactly: containment narrows through the GIN index, and the
  # value at the path must equal `v` (containment alone also matches an array
  # holding `v`).
  defp exact_condition(ids, eq, checks, perspective) do
    condition = if ids, do: ids_condition(ids, perspective), else: dynamic(true)

    condition =
      Enum.reduce(checks, condition, fn c, acc -> dynamic(^acc and ^check_condition(c)) end)

    Enum.reduce(eq, condition, fn {path, value}, acc ->
      dynamic(
        [d],
        ^acc and ^eq_condition(path, value) and
          fragment(
            "? #> ? = CAST(? AS jsonb)",
            d.content,
            type(^path, {:array, :string}),
            type(^Jason.encode!(value), :string)
          )
      )
    end)
  end

  # `counted_rows/1` leaves out a published row whose draft replaces it, so
  # each chunk renders on its own. Rows are read in `id` order, each chunk
  # after the last id of the one before.
  defp scan(state, {types, _ids, _eq, _any, _checks} = key, keep?) do
    query =
      state
      |> counted_rows()
      |> maybe_where_types(types)
      |> where(^key_condition(key, state.perspective))
      |> order_by([d], asc: d.id)
      |> limit(@scan_chunk)

    Enum.each(types || [], &touch_type/1)
    scan_chunks(state, query, nil, keep?, 0)
  end

  defp scan_chunks(state, query, after_id, keep?, total) do
    rows =
      if after_id,
        do: query |> where([d], d.id > ^after_id) |> Repo.all(),
        else: Repo.all(query)

    docs = render(rows, state)
    Enum.each(docs, &touch_type(&1["_type"]))
    total = total + Enum.count(docs, keep?)

    if length(rows) < @scan_chunk,
      do: total,
      else: scan_chunks(state, query, List.last(rows).id, keep?, total)
  end

  defp load_key(state, key), do: load_keys(state, [key])

  # Keys that scan the same types are read in one query: their conditions are
  # OR-ed and every key is answered with the union, a superset the evaluator
  # filters per key. A subquery inside a projection therefore costs one read
  # per round, however many parent documents it runs for.
  defp load_keys(state, keys) do
    keys
    |> Enum.group_by(fn {types, _ids, _eq, _any, _checks} -> types end)
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
      if Enum.all?(keys, fn {_types, ids, _eq, _any, _checks} -> ids != nil end) do
        # Reads by id are bounded by the ids the query named.
        Repo.all(matching)
      else
        matching |> admit!(state) |> then(&Repo.all(from(d in Document, where: d.id in ^&1)))
      end

    rows = if twins_needed?(state, keys), do: with_twins(rows, state, types), else: rows

    docs = rows |> render(state) |> sort_by_id()
    count_loaded!(state, length(docs))
    Enum.each(docs, &cache_doc/1)

    # A read by id depends on those documents; any other read depends on every
    # document of the types it scanned, so it is tagged by type.
    if Enum.all?(keys, fn {_types, ids, _eq, _any, _checks} -> ids != nil end),
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

  # In the drafts perspective a draft replaces its published twin, and the
  # filter applies to the draft. A content condition in SQL sees each row on
  # its own, so it can load a published row whose draft no longer matches.
  # Loading the twin of every matched row lets the overlay pick the draft and
  # the evaluator reject it.
  defp twins_needed?(%{perspective: :drafts}, keys),
    do:
      Enum.any?(keys, fn {_types, _ids, eq, any, checks} ->
        eq != [] or any != [] or checks != []
      end)

  defp twins_needed?(_state, _keys), do: false

  defp with_twins(rows, state, types) do
    have = MapSet.new(rows, & &1.doc_id)

    wanted =
      rows
      |> Enum.flat_map(fn row ->
        published = DraftId.published_id(row.doc_id)
        [published, DraftId.draft_id(published)]
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(have, &1))

    case wanted do
      [] ->
        rows

      _ ->
        twins =
          state
          |> base_query()
          |> maybe_where_types(types)
          |> where([d], d.doc_id in ^wanted)
          |> Repo.all()

        rows ++ twins
    end
  end

  defp unconstrained?({_types, nil, [], [], []}), do: true
  defp unconstrained?(_key), do: false

  defp key_condition({_types, ids, eq, any, checks}, perspective) do
    condition = if ids, do: ids_condition(ids, perspective), else: dynamic(true)

    condition =
      Enum.reduce(checks, condition, fn c, acc -> dynamic(^acc and ^check_condition(c)) end)

    condition =
      Enum.reduce(eq, condition, fn {path, value}, acc ->
        dynamic([d], ^acc and ^eq_condition(path, value))
      end)

    Enum.reduce(any, condition, fn probes, acc ->
      dynamic([d], ^acc and ^probes_condition(probes, perspective))
    end)
  end

  # A row matches one of the probes. A containment map uses the GIN index on
  # `content`, `{:refs, ids}` the GIN index on the `_ref` values and
  # `{:ids, ids}` the `doc_id` index. An empty list matches nothing.
  defp probes_condition(probes, perspective) do
    {maps, refs, ids} =
      Enum.reduce(probes, {[], [], []}, fn
        {:refs, r}, {m, rs, is} -> {m, rs ++ r, is}
        {:ids, i}, {m, rs, is} -> {m, rs, is ++ i}
        map, {m, rs, is} -> {[map | m], rs, is}
      end)

    conditions =
      Enum.reject(
        [
          maps != [] && contains_any(Enum.reverse(maps)),
          refs != [] && references_any(Enum.uniq(refs)),
          ids != [] && ids_condition(Enum.uniq(ids), perspective)
        ],
        &(&1 == false)
      )

    Enum.reduce(conditions, dynamic(false), fn c, acc -> dynamic([d], ^acc or ^c) end)
  end

  defp contains_any(maps) do
    json = Enum.map(maps, &Jason.encode!/1)

    dynamic(
      [d],
      fragment("? @> ANY(CAST(? AS jsonb[]))", d.content, type(^json, {:array, :string}))
    )
  end

  # The expression is the one `documents_content_refs_idx` is built on, word
  # for word; Postgres uses the index only for that exact expression. It
  # collects the `_ref` of every object at any depth, which is a superset of
  # what `references()` matches (it also descends into an object that has a
  # `_ref`), so the evaluator's own check decides.
  defp references_any(ids) do
    dynamic(
      [d],
      fragment(
        "jsonb_path_query_array(?, 'strict $.** \\? (exists(@._ref))._ref') \\?| ?",
        d.content,
        type(^ids, {:array, :string})
      )
    )
  end

  # `count(path) op n`. The CASE yields null for anything but an array, as
  # GROQ's count() does, and keeps `jsonb_array_length` from raising on one.
  defp check_condition({:length, path, "<", n}) do
    dynamic(
      [d],
      fragment(
        "CASE WHEN jsonb_typeof(? #> ?) = 'array' THEN jsonb_array_length(? #> ?) END < ?",
        d.content,
        type(^path, {:array, :string}),
        d.content,
        type(^path, {:array, :string}),
        ^n
      )
    )
  end

  defp check_condition({:length, path, "<=", n}) do
    dynamic(
      [d],
      fragment(
        "CASE WHEN jsonb_typeof(? #> ?) = 'array' THEN jsonb_array_length(? #> ?) END <= ?",
        d.content,
        type(^path, {:array, :string}),
        d.content,
        type(^path, {:array, :string}),
        ^n
      )
    )
  end

  defp check_condition({:length, path, ">", n}) do
    dynamic(
      [d],
      fragment(
        "CASE WHEN jsonb_typeof(? #> ?) = 'array' THEN jsonb_array_length(? #> ?) END > ?",
        d.content,
        type(^path, {:array, :string}),
        d.content,
        type(^path, {:array, :string}),
        ^n
      )
    )
  end

  defp check_condition({:length, path, ">=", n}) do
    dynamic(
      [d],
      fragment(
        "CASE WHEN jsonb_typeof(? #> ?) = 'array' THEN jsonb_array_length(? #> ?) END >= ?",
        d.content,
        type(^path, {:array, :string}),
        d.content,
        type(^path, {:array, :string}),
        ^n
      )
    )
  end

  defp check_condition({:length, path, "==", n}) do
    dynamic(
      [d],
      fragment(
        "CASE WHEN jsonb_typeof(? #> ?) = 'array' THEN jsonb_array_length(? #> ?) END = ?",
        d.content,
        type(^path, {:array, :string}),
        d.content,
        type(^path, {:array, :string}),
        ^n
      )
    )
  end

  # `defined(path)`: present and not JSON null. `defined(path[i])` also needs
  # an array: Postgres reads `-> 0` of a scalar as the scalar itself, where
  # GROQ gives null.
  defp check_condition({:defined, path, nil}) do
    dynamic(
      [d],
      fragment("jsonb_typeof(? #> ?) <> 'null'", d.content, type(^path, {:array, :string}))
    )
  end

  defp check_condition({:defined, path, i}) do
    dynamic(
      [d],
      fragment(
        "(jsonb_typeof(? #> ?) = 'array' AND jsonb_typeof((? #> ?) -> CAST(? AS integer)) <> 'null')",
        d.content,
        type(^path, {:array, :string}),
        d.content,
        type(^path, {:array, :string}),
        ^i
      )
    )
  end

  # `title` lives in the `documents.title` column. `Envelope.render/3` emits
  # the column, or `content.title` when the column is blank, so a row matches
  # when either holds the value. The evaluator re-applies the filter to the
  # rendered document, which drops a row whose column wins with another value.
  defp eq_condition(["title"], value) do
    dynamic(
      [d],
      d.title == ^value or
        fragment("? @> ?", d.content, type(^Pushdown.nest(["title"], value), :map))
    )
  end

  defp eq_condition(path, value) do
    dynamic([d], fragment("? @> ?", d.content, type(^Pushdown.nest(path, value), :map)))
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

  defp base_query(state, source \\ Document) do
    opts = state.opts

    source
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
    |> Enum.map(fn {_row, doc} -> to_sanity(doc) end)
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

  # Barkpark's envelope adds `_draft` and `_publishedId`; a Sanity document has
  # neither. `title` is a user field: the writer moves it out of `content` into
  # the `documents.title` column, and `Envelope.render/3` puts it back, so it
  # stays exactly as the envelope emits it. A document written without a title
  # renders `title: nil`; it is dropped, as a Sanity document has no such key,
  # and GROQ reads a missing key and a null the same way.
  defp to_sanity(doc) do
    doc = Map.drop(doc, ["_draft", "_publishedId"])

    if is_nil(doc["title"]), do: Map.delete(doc, "title"), else: doc
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
