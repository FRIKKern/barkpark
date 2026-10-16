defmodule Barkpark.Search.SearchRefresh do
  @moduledoc """
  Recomputes the search slots and the public vector of a large type after a
  schema write, outside the write (task-9d83c3e0c3b8fabf, migration
  20261016130000).

  The trigger `schema_definitions_search_refresh` decides what a schema write
  changes. A scope of at most `barkpark.search_refresh_inline_max` documents
  (default 1,000) is recomputed in the write. A larger one is recorded as a
  row of `search_refresh_pending`, and `drain/1` (run by
  `Barkpark.Search.Workers.SearchRefresh`) recomputes it in batches, each its
  own statement, and then deletes the row.

  A row with `gate` set comes from a change that made a field restricted.
  The row is deleted only after its scope is done, including a second pass
  over the documents written around the schema write. Until it is deleted,
  `gates/0` names its scope and `DocumentsRetriever`
  leaves the scope's documents out of every text search by a caller that is
  not an admin, so a stale public vector cannot match a word the new schema
  hides.
  """

  import Ecto.Query, only: [dynamic: 2]

  alias Barkpark.Repo
  alias Barkpark.Search.Workers.SearchRefresh, as: Worker

  @batch 500

  @type scope :: %{
          type: String.t(),
          dataset: String.t(),
          dataset_id: String.t() | nil,
          wide: boolean()
        }

  @doc """
  The scopes whose documents a non-admin text search must leave out: the
  pending refreshes that follow a change that made a field restricted.
  """
  @spec gates() :: [scope()]
  def gates do
    %{rows: rows} =
      Repo.query!(
        "SELECT type, scope_dataset, scope_dataset_id, wide FROM search_refresh_pending WHERE gate"
      )

    Enum.map(rows, fn [type, dataset, dataset_id, wide] ->
      %{
        type: type,
        dataset: dataset,
        dataset_id: dataset_id && Ecto.UUID.load!(dataset_id),
        wide: wide
      }
    end)
  end

  @doc """
  A query condition that is false for every document in one of `scopes`. The
  document binding is the first one of the query. `nil` when there are none.
  """
  @spec exclude(Ecto.Query.dynamic_expr() | nil, [scope()]) :: Ecto.Query.dynamic_expr() | nil
  def exclude(acc \\ nil, scopes)

  def exclude(acc, []), do: acc

  def exclude(acc, [%{type: type, dataset: dataset, dataset_id: dataset_id, wide: wide} | rest]) do
    in_scope =
      case {dataset_id, wide} do
        {nil, _} -> dynamic([d], d.dataset == ^dataset)
        {id, false} -> dynamic([d], d.dataset_id == ^id)
        {id, true} -> dynamic([d], d.dataset_id == ^id or d.dataset == ^dataset)
      end

    clause = dynamic([d], not (d.type == ^type and ^in_scope))
    exclude(if(acc, do: dynamic([d], ^acc and ^clause), else: clause), rest)
  end

  @doc """
  Queue the refresh worker when a refresh is pending. A schema write calls it
  after its row is written; the worker's cron entry runs it every minute too,
  so a write by any other path is picked up.
  """
  @spec kick() :: :ok
  def kick do
    if pending?(), do: Oban.insert(Worker.new(%{}))
    :ok
  end

  @spec pending?() :: boolean()
  def pending? do
    %{rows: [[any?]]} = Repo.query!("SELECT EXISTS (SELECT 1 FROM search_refresh_pending)")
    any?
  end

  @doc """
  Recompute every pending scope, `:batch` documents per statement (default
  500), and delete each pending row once its scope is done. A row that a newer
  schema write changed while its scope ran (`gen` moved on) is run again.
  Returns the number of documents written.
  """
  @spec drain(keyword()) :: non_neg_integer()
  def drain(opts \\ []) do
    batch = Keyword.get(opts, :batch, @batch)
    drain_loop(batch, 0, 0)
  end

  # A schema write per batch could keep one scope pending for ever; the loop
  # stops after 20 passes and the next run picks the rest up.
  defp drain_loop(_batch, written, 20), do: written

  defp drain_loop(batch, written, pass) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, type, scope_dataset, scope_dataset_id, wide, slots, public, gen, " <>
          "requested_at - interval '5 minutes' FROM search_refresh_pending ORDER BY id"
      )

    case rows do
      [] ->
        written

      rows ->
        n =
          Enum.reduce(rows, 0, fn [id, type, dataset, dataset_id, wide, slots, public, gen, since],
                                  acc ->
            params = [type, dataset, dataset_id, wide, slots, public]
            n = refresh_scope(params, batch, nil, nil, 0)
            # The documents written around the schema write, once more: see
            # the moduledoc of migration 20261016130000.
            n = refresh_scope(params, batch, since, nil, n)

            Repo.query!(
              "DELETE FROM search_refresh_pending WHERE id = $1 AND gen = $2",
              [id, gen]
            )

            acc + n
          end)

        drain_loop(batch, written + n, pass + 1)
    end
  end

  defp refresh_scope(params, batch, since, after_id, written) do
    %{rows: [[last_id, n]]} =
      Repo.query!(
        "SELECT last_id, written FROM bp_search_refresh_batch($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        params ++ [after_id, batch, since],
        timeout: :infinity
      )

    if last_id,
      do: refresh_scope(params, batch, since, last_id, written + n),
      else: written + n
  end
end
