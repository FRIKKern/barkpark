defmodule Barkpark.Search.Views do
  @moduledoc """
  Document view counts and the popularity read on top of them
  (task-5feac4e826cff9a5). Guide: `docs/search/VIEWS.md`.

  ## Write path

  `record/3` takes a dataset id and document ids from
  `POST /w/:ws/p/:proj/v1/data/views/:dataset`. It counts each view in ETS
  (`Barkpark.Search.Views.Buffer`) and returns. `flush/0` runs every
  `:flush_interval_ms` (5 s by default) and adds the counts to
  `document_view_days` in one upsert per dataset, after dropping ids that are
  not published documents of that dataset. A view therefore never writes the
  document, and a burst of views on one book costs one row update per flush.

  ## Dedupe and privacy

  A visitor counts once per document per UTC day. The visitor key is a
  SHA-256 over a random salt and either the caller's `visitor` value (only
  from a token caller, such as a site's server forwarding its own session
  id) or the client IP and user agent. The salt is created in memory for the
  day and never written anywhere, so the key cannot be recomputed after a
  restart or after the day ends. The key itself lives only in ETS and is
  dropped when the day changes. No IP address, user agent or visitor key
  reaches the database. A restart forgets the day's keys, so a visitor can
  count twice on the day of a restart.

  ## Read path

  `rollup/1` runs from `Barkpark.Search.Workers.ViewsRollup` every 10 minutes.
  It rewrites `document_popularity` from the last 30 days of
  `document_view_days`: `views_7d`, `views_30d` and `score`, the sum of each
  day's views halved for every 7 days of age. Documents with no view in 30
  days leave the table. It also deletes day rows older than
  `retention_days/0`.

  GROQ reads the three numbers as `_views7d`, `_views30d` and `_popularity`
  (`Barkpark.Groq.DocumentSource`), the query API sorts by them
  (`order=popularity:desc`), and document search adds `score` to relevance
  with `boost=popularity`. All three read `document_popularity` by
  `(dataset_id, doc_id)`.
  """

  import Ecto.Query

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Search.Views.Buffer

  @retention_days 90
  @half_life_days 7
  @max_ids_per_request 50
  @max_id_bytes 255

  # GROQ field name -> `document_popularity` column.
  @fields %{"_views7d" => :views_7d, "_views30d" => :views_30d, "_popularity" => :score}

  @doc "Days of `document_view_days` the rollup keeps."
  def retention_days, do: config(:retention_days, @retention_days)

  @doc "The most ids one request may record."
  def max_ids_per_request, do: @max_ids_per_request

  @doc "GROQ field names mapped to their `document_popularity` column."
  def fields, do: @fields

  @doc "The GROQ field names, as strings."
  def field_names, do: Map.keys(@fields)

  @doc """
  Records one view of each id in `ids` for the dataset `dataset_id`.

  `visitor` is the material the dedupe key is derived from; `nil` turns
  dedupe off for this call. Ids are trimmed, `drafts.` is stripped, and
  anything empty or longer than 255 bytes is refused. Returns
  `{:ok, %{accepted: n, duplicates: d}}` or `{:error, reason}` when no id is
  valid.
  """
  @spec record(Ecto.UUID.t(), [String.t()], binary() | nil, Date.t()) ::
          {:ok, %{accepted: non_neg_integer(), duplicates: non_neg_integer()}}
          | {:error, :no_ids | :too_many_ids}
  def record(dataset_id, ids, visitor, day \\ Date.utc_today())

  def record(_dataset_id, ids, _visitor, _day) when length(ids) > @max_ids_per_request,
    do: {:error, :too_many_ids}

  def record(dataset_id, ids, visitor, day) when is_binary(dataset_id) and is_list(ids) do
    case ids |> Enum.map(&normalize_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        {:error, :no_ids}

      valid ->
        key = visitor && Buffer.visitor_key(day, visitor)

        {accepted, duplicates} =
          Enum.reduce(valid, {0, 0}, fn id, {a, d} ->
            if Buffer.add(dataset_id, id, day, key), do: {a + 1, d}, else: {a, d + 1}
          end)

        {:ok, %{accepted: accepted, duplicates: duplicates}}
    end
  end

  defp normalize_id(id) when is_binary(id) do
    id = id |> String.trim() |> String.replace_prefix("drafts.", "")

    if id == "" or byte_size(id) > @max_id_bytes or not String.valid?(id), do: nil, else: id
  end

  defp normalize_id(_id), do: nil

  @doc """
  Writes the buffered counts to `document_view_days`. Ids that are not a
  published document of their dataset are dropped. Returns the number of
  views written. A failed write puts the counts back for the next flush.
  """
  @spec flush() :: non_neg_integer()
  def flush do
    Buffer.prune_seen(Date.utc_today())

    Buffer.take_counts()
    |> Enum.group_by(fn {{dataset_id, _id, _day}, _n} -> dataset_id end)
    |> Enum.reduce(0, fn {dataset_id, entries}, total ->
      total + flush_dataset(dataset_id, entries)
    end)
  end

  defp flush_dataset(dataset_id, entries) do
    ids = entries |> Enum.map(fn {{_ds, id, _day}, _n} -> id end) |> Enum.uniq()

    types =
      from(d in "documents",
        where: d.dataset_id == type(^dataset_id, :binary_id) and d.doc_id in ^ids,
        select: {d.doc_id, d.type}
      )
      |> Repo.all()
      |> Map.new()

    rows =
      for {{_ds, id, day}, n} <- entries, type = Map.get(types, id), not is_nil(type) do
        %{dataset_id: Ecto.UUID.dump!(dataset_id), doc_id: id, day: day, type: type, views: n}
      end

    upsert_days(rows)
    Enum.reduce(rows, 0, &(&1.views + &2))
  rescue
    e ->
      Logger.warning("views flush failed for dataset #{dataset_id}: #{Exception.message(e)}")
      Enum.each(entries, fn {{ds, id, day}, n} -> Buffer.add_count(ds, id, day, n) end)
      0
  end

  defp upsert_days([]), do: :ok

  defp upsert_days(rows) do
    query =
      from(v in "document_view_days",
        update: [set: [views: fragment("? + EXCLUDED.views", v.views)]]
      )

    Repo.insert_all("document_view_days", rows,
      on_conflict: query,
      conflict_target: [:dataset_id, :doc_id, :day]
    )

    :ok
  end

  @doc """
  Rewrites `document_popularity` from the last 30 days of
  `document_view_days` and deletes day rows past `retention_days/0`. `today`
  defaults to the UTC date. Returns `%{documents: n, pruned: n}`.
  """
  @spec rollup(keyword()) :: %{documents: non_neg_integer(), pruned: non_neg_integer()}
  def rollup(opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    now = DateTime.utc_now()

    {:ok, result} =
      Repo.transaction(fn ->
        %{num_rows: documents} =
          Repo.query!(
            """
            INSERT INTO document_popularity
              (dataset_id, doc_id, type, views_7d, views_30d, score, updated_at)
            SELECT dataset_id, doc_id, max(type),
                   coalesce(sum(views) FILTER (WHERE day > $1::date - 7), 0),
                   sum(views),
                   sum(views * power(0.5, ($1::date - day) / $2::float)),
                   $3
            FROM document_view_days
            WHERE day > $1::date - 30 AND day <= $1::date
            GROUP BY dataset_id, doc_id
            ON CONFLICT (dataset_id, doc_id) DO UPDATE SET
              type = EXCLUDED.type,
              views_7d = EXCLUDED.views_7d,
              views_30d = EXCLUDED.views_30d,
              score = EXCLUDED.score,
              updated_at = EXCLUDED.updated_at
            """,
            [today, @half_life_days * 1.0, now]
          )

        Repo.query!("DELETE FROM document_popularity WHERE updated_at < $1", [now])

        %{num_rows: pruned} =
          Repo.query!("DELETE FROM document_view_days WHERE day <= $1::date - $2::int", [
            today,
            retention_days()
          ])

        %{documents: documents, pruned: pruned}
      end)

    result
  end

  @doc """
  The popularity numbers for `doc_ids` (published ids) of the dataset
  `dataset_id`, as `%{doc_id => %{"_views7d" => n, "_views30d" => n,
  "_popularity" => s}}`. Ids with no row are absent.
  """
  @spec lookup(Ecto.UUID.t(), [String.t()]) :: %{String.t() => map()}
  def lookup(_dataset_id, []), do: %{}

  def lookup(dataset_id, doc_ids) do
    from(p in "document_popularity",
      where: p.dataset_id == type(^dataset_id, :binary_id) and p.doc_id in ^doc_ids,
      select: {p.doc_id, p.views_7d, p.views_30d, p.score}
    )
    |> Repo.all()
    |> Map.new(fn {id, v7, v30, score} ->
      {id, %{"_views7d" => v7, "_views30d" => v30, "_popularity" => to_float(score)}}
    end)
  end

  @doc "The value a document with no row reads: zero views, score 0."
  def zero, do: %{"_views7d" => 0, "_views30d" => 0, "_popularity" => 0.0}

  defp to_float(score) when is_float(score), do: score
  defp to_float(score) when is_integer(score), do: score * 1.0
  defp to_float(_), do: 0.0

  @doc """
  An Ecto `dynamic` for one `document_popularity` column of the `documents`
  row bound first in the query, 0 when the document has no row. With
  `published_ids?` true the row's `doc_id` is used as stored; otherwise a
  `drafts.` prefix is stripped first, so a draft reads its published
  document's counts. One index lookup on the primary key per row.
  """
  @spec sql_value(:views_7d | :views_30d | :score, boolean()) :: Ecto.Query.dynamic_expr()
  def sql_value(:views_7d, true),
    do:
      dynamic(
        [d],
        fragment(
          "COALESCE((SELECT p.views_7d FROM document_popularity p WHERE p.dataset_id = ? AND p.doc_id = ?), 0)",
          d.dataset_id,
          d.doc_id
        )
      )

  def sql_value(:views_30d, true),
    do:
      dynamic(
        [d],
        fragment(
          "COALESCE((SELECT p.views_30d FROM document_popularity p WHERE p.dataset_id = ? AND p.doc_id = ?), 0)",
          d.dataset_id,
          d.doc_id
        )
      )

  def sql_value(:score, true),
    do:
      dynamic(
        [d],
        fragment(
          "COALESCE((SELECT p.score FROM document_popularity p WHERE p.dataset_id = ? AND p.doc_id = ?), 0)",
          d.dataset_id,
          d.doc_id
        )
      )

  def sql_value(:views_7d, false),
    do:
      dynamic(
        [d],
        fragment(
          "COALESCE((SELECT p.views_7d FROM document_popularity p WHERE p.dataset_id = ? AND p.doc_id = regexp_replace(?, '^drafts\\.', '')), 0)",
          d.dataset_id,
          d.doc_id
        )
      )

  def sql_value(:views_30d, false),
    do:
      dynamic(
        [d],
        fragment(
          "COALESCE((SELECT p.views_30d FROM document_popularity p WHERE p.dataset_id = ? AND p.doc_id = regexp_replace(?, '^drafts\\.', '')), 0)",
          d.dataset_id,
          d.doc_id
        )
      )

  def sql_value(:score, false),
    do:
      dynamic(
        [d],
        fragment(
          "COALESCE((SELECT p.score FROM document_popularity p WHERE p.dataset_id = ? AND p.doc_id = regexp_replace(?, '^drafts\\.', '')), 0)",
          d.dataset_id,
          d.doc_id
        )
      )

  @doc """
  Left-joins `document_popularity` as the named binding `:bp_views` onto the
  `documents` row bound first in `query`, once. A sort then reads
  `joined_value/1`: Postgres hash-joins the two tables instead of one index
  lookup per document (over 18,020 products: 36 ms against 190 ms for
  `sql_value/2` in the ORDER BY).
  """
  @spec join_popularity(Ecto.Queryable.t(), boolean()) :: Ecto.Query.t()
  def join_popularity(query, published_ids?) do
    if has_named_binding?(query, :bp_views) do
      query
    else
      on =
        if published_ids?,
          do: dynamic([d, bp_views: p], p.dataset_id == d.dataset_id and p.doc_id == d.doc_id),
          else:
            dynamic(
              [d, bp_views: p],
              p.dataset_id == d.dataset_id and
                p.doc_id == fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id)
            )

      join(query, :left, [d], p in "document_popularity", as: :bp_views, on: ^on)
    end
  end

  @doc "One `document_popularity` column through `join_popularity/2`, 0 without a row."
  @spec joined_value(:views_7d | :views_30d | :score) :: Ecto.Query.dynamic_expr()
  def joined_value(column), do: dynamic([bp_views: p], coalesce(field(p, ^column), 0))

  @doc """
  An Ecto `dynamic` that is true when the document's `column` compares with
  `n` by `op` (`<`, `<=`, `>`, `>=`, `==`), reading 0 for a document with no
  row. It is a semi-join on `document_popularity` rather than a lookup per
  document: when 0 fails the comparison only documents with a row can match
  (`IN`), otherwise a document matches unless its row fails (`NOT IN`).
  `published_ids?` as in `sql_value/2`.
  """
  @spec sql_condition(:views_7d | :views_30d | :score, String.t(), number(), boolean()) ::
          Ecto.Query.dynamic_expr()
  def sql_condition(column, op, n, published_ids?) do
    if compare(0, op, n),
      do: not_in_failing(column, op, n, published_ids?),
      else: in_passing(column, op, n, published_ids?)
  end

  defp compare(a, "<", b), do: a < b
  defp compare(a, "<=", b), do: a <= b
  defp compare(a, ">", b), do: a > b
  defp compare(a, ">=", b), do: a >= b
  defp compare(a, "==", b), do: a == b

  # One clause per column, operator and id form, because a fragment's SQL must
  # be a literal. `NOT (x op n)` is the failing side; the columns are NOT NULL.
  for {column, sql_column} <- [views_7d: "views_7d", views_30d: "views_30d", score: "score"],
      {op, sql_op} <- [{"<", "<"}, {"<=", "<="}, {">", ">"}, {">=", ">="}, {"==", "="}],
      {published?, id_sql} <- [{true, "?"}, {false, "regexp_replace(?, '^drafts\\.', '')"}] do
    @in_sql "(?, #{id_sql}) IN (SELECT p.dataset_id, p.doc_id FROM document_popularity p " <>
              "WHERE p.#{sql_column} #{sql_op} CAST(? AS double precision))"
    @not_in_sql "(?, #{id_sql}) NOT IN (SELECT p.dataset_id, p.doc_id FROM document_popularity p " <>
                  "WHERE NOT (p.#{sql_column} #{sql_op} CAST(? AS double precision)))"

    defp in_passing(unquote(column), unquote(op), n, unquote(published?)),
      do: dynamic([d], fragment(@in_sql, d.dataset_id, d.doc_id, ^n))

    defp not_in_failing(unquote(column), unquote(op), n, unquote(published?)),
      do: dynamic([d], fragment(@not_in_sql, d.dataset_id, d.doc_id, ^n))
  end

  @doc """
  True when `tree`, a parsed GROQ query, names one of `field_names/0`. The
  document source attaches the numbers only then, so a query that does not
  ask for them costs no extra read.
  """
  @spec referenced?(term()) :: boolean()
  def referenced?(tree), do: mentions?(tree, field_names())

  defp mentions?(term, names) when is_binary(term), do: term in names
  defp mentions?(term, names) when is_tuple(term), do: term |> Tuple.to_list() |> mentions?(names)
  defp mentions?(term, names) when is_list(term), do: Enum.any?(term, &mentions?(&1, names))

  defp mentions?(term, names) when is_map(term) and not is_struct(term),
    do: Enum.any?(term, fn {k, v} -> mentions?(k, names) or mentions?(v, names) end)

  defp mentions?(_term, _names), do: false

  defp config(key, default) do
    :barkpark |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
