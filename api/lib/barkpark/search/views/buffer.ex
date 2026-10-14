defmodule Barkpark.Search.Views.Buffer do
  @moduledoc """
  The in-memory side of `Barkpark.Search.Views`: two ETS tables and the timer
  that flushes them.

    * `:barkpark_view_counts` maps `{dataset_id, doc_id, day}` to the views
      not yet written. `Views.flush/0` takes them.
    * `:barkpark_view_seen` holds `{day, dataset_id, doc_id, visitor_key}`
      for dedupe, and `{:salt, day}` with that day's random salt, with the
      day as a Gregorian day number. Entries of earlier days are deleted on
      each flush.

  Both tables are public, so a request process counts without a message to
  this server. Past `:max_seen` dedupe entries a view counts without dedupe,
  and past `:max_pending` buffered keys a new key is dropped and logged, so
  a flood of distinct ids cannot grow memory without bound.

  The timer runs every `:flush_interval_ms` (5000 by default; `nil` turns it
  off, as the test config does) and once more when the server stops.
  """

  use GenServer

  require Logger

  @counts :barkpark_view_counts
  @seen :barkpark_view_seen

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@counts, [:named_table, :public, :set, write_concurrency: true])

    :ets.new(@seen, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])

    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    safe_flush()
    schedule()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    safe_flush()
    :ok
  end

  defp safe_flush do
    Barkpark.Search.Views.flush()
  rescue
    e -> Logger.warning("views flush crashed: #{Exception.message(e)}")
  end

  defp schedule do
    case config(:flush_interval_ms, 5_000) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :flush, ms)
      _ -> :ok
    end
  end

  @doc """
  The dedupe key for `visitor` on `day`: the first 16 bytes of SHA-256 over
  the day's salt and the visitor material.
  """
  @spec visitor_key(Date.t(), binary()) :: binary()
  def visitor_key(day, visitor) when is_binary(visitor) do
    binary_part(:crypto.hash(:sha256, [salt(day_number(day)), 0, visitor]), 0, 16)
  end

  # Dedupe and salt keys carry the day as a Gregorian day number, so ETS
  # match patterns and comparisons work on a plain integer.
  defp day_number(day), do: Date.to_gregorian_days(day)

  defp salt(day) do
    case :ets.lookup(@seen, {:salt, day}) do
      [{_, salt}] ->
        salt

      [] ->
        :ets.insert_new(@seen, {{:salt, day}, :crypto.strong_rand_bytes(32)})
        [{_, salt}] = :ets.lookup(@seen, {:salt, day})
        salt
    end
  end

  @doc """
  Counts one view unless `visitor_key` already viewed this document today.
  Returns true when the view counted. A nil key always counts.
  """
  @spec add(String.t(), String.t(), Date.t(), binary() | nil) :: boolean()
  def add(dataset_id, doc_id, day, visitor_key) do
    if first_view?(dataset_id, doc_id, day, visitor_key) do
      add_count(dataset_id, doc_id, day, 1)
      true
    else
      false
    end
  end

  defp first_view?(_dataset_id, _doc_id, _day, nil), do: true

  defp first_view?(dataset_id, doc_id, day, key) do
    if :ets.info(@seen, :size) >= config(:max_seen, 1_000_000),
      do: true,
      else: :ets.insert_new(@seen, {{day_number(day), dataset_id, doc_id, key}})
  end

  @doc "Adds `n` buffered views of a document on `day`."
  @spec add_count(String.t(), String.t(), Date.t(), pos_integer()) :: :ok
  def add_count(dataset_id, doc_id, day, n) do
    key = {dataset_id, doc_id, day}

    cond do
      :ets.member(@counts, key) ->
        :ets.update_counter(@counts, key, {2, n}, {key, 0})

      :ets.info(@counts, :size) >= config(:max_pending, 200_000) ->
        Logger.warning("views buffer full; dropped a view of #{doc_id}")

      true ->
        :ets.update_counter(@counts, key, {2, n}, {key, 0})
    end

    :ok
  end

  @doc "Removes and returns every buffered `{{dataset_id, doc_id, day}, n}`."
  @spec take_counts() :: [{{String.t(), String.t(), Date.t()}, pos_integer()}]
  def take_counts do
    @counts
    |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn key ->
      case :ets.take(@counts, key) do
        [{^key, n}] when n > 0 -> [{key, n}]
        _ -> []
      end
    end)
  end

  @doc "Deletes dedupe entries and salts of days before `today`."
  @spec prune_seen(Date.t()) :: :ok
  # Every dedupe entry's day has a salt entry, made by `visitor_key/2` before
  # the entry, so the salts name every day there is to delete.
  def prune_seen(today) do
    @seen
    |> :ets.select([{{{:salt, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.filter(&(&1 < day_number(today)))
    |> Enum.each(fn day ->
      :ets.match_delete(@seen, {{day, :_, :_, :_}})
      :ets.delete(@seen, {:salt, day})
    end)
  end

  @doc false
  # Test helper: empties both tables.
  def reset do
    :ets.delete_all_objects(@counts)
    :ets.delete_all_objects(@seen)
    :ok
  end

  defp config(key, default) do
    :barkpark
    |> Application.get_env(Barkpark.Search.Views, [])
    |> Keyword.get(key, default)
  end
end
