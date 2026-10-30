defmodule Barkpark.Tenancy.DatasetDelete.Runs do
  @moduledoc """
  Runs `Tenancy.DatasetDelete.delete/2` off the request (task-10608b4831a0e9b8).

  ```
  DELETE ─► delete/5 ─┬─ no run: start one (≤ max_runs per node, else busy), wait ≤ wait_ms
                      ├─ a run is live: wait ≤ wait_ms
                      └─ a finished run nobody read: its result, once
               result ─► the controller answers it; still running ─► :running (202)
  ```

  A delete of thousands of documents outlives any request budget, so the
  request waits a few seconds and then answers `:running`; the caller repeats
  the DELETE until it gets the result. The task runs the one transaction, so
  an interrupted run (node restart, killed task) rolls back and leaves the
  dataset whole. Each run holds one pool connection, so at most `max_runs/0`
  run at once on a node and the rest answer `{:error, :busy}`.

  Node-local ETS, one row per `{project_id, slug}`:
  `{key, {:running, pid} | {:done, result}, dataset_id, at}`. A run is bound to
  the dataset it started on. A poll names that dataset (`opts[:dataset_id]`)
  and gets that run's result, never a delete of another dataset. A DELETE that
  names no dataset and finds an unread result for a dataset the name no longer
  holds answers `{:error, {:recreated, result}}` and drops it; the next DELETE
  deletes the new dataset. A dead run restarts only on its own dataset. A
  finished row is dropped when it is read, or an hour after it finished.
  """
  use GenServer

  require Logger

  alias Barkpark.Tenancy.{Dataset, DatasetDelete}

  @table __MODULE__
  @poll_ms 50
  @keep_ms :timer.hours(1)
  @go_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, nil}
  end

  @doc """
  The delete's result, or `:running` when it is still going after `wait_ms`.
  `dataset` is what the project's slug names now, `nil` once it is gone.
  `opts[:dataset_id]` is the dataset a poll asks about (the 202 names it).
  `opts[:on_deleted]` runs with the receipt in the task, after the commit.
  """
  @spec delete(binary(), String.t(), Dataset.t() | nil, keyword(), non_neg_integer()) ::
          term() | :running
  def delete(project_id, slug, dataset, opts, wait_ms) do
    {polled, opts} = Keyword.pop(opts, :dataset_id)
    key = {project_id, slug}
    current = dataset && dataset.id

    case :ets.lookup(@table, key) do
      [{^key, {:done, result}, id, _at} = row] ->
        cond do
          polled not in [nil, id] ->
            fresh(key, dataset, polled, opts, wait_ms)

          not take(row) ->
            delete(project_id, slug, dataset, [dataset_id: polled] ++ opts, wait_ms)

          polled == id or current in [nil, id] ->
            result

          true ->
            {:error, {:recreated, result}}
        end

      [{^key, {:running, pid}, id, _at} = row] ->
        cond do
          polled not in [nil, id] ->
            {:error, :not_found}

          Process.alive?(pid) ->
            wait(key, now() + wait_ms)

          not take(row) ->
            delete(project_id, slug, dataset, [dataset_id: polled] ++ opts, wait_ms)

          current == id ->
            start(key, dataset, opts, wait_ms)

          true ->
            {:error, {:delete_failed, :interrupted}}
        end

      [] ->
        fresh(key, dataset, polled, opts, wait_ms)
    end
  end

  defp fresh(_key, nil, _polled, _opts, _wait_ms), do: {:error, :not_found}

  defp fresh(key, %Dataset{id: id} = dataset, polled, opts, wait_ms) when polled in [nil, id],
    do: start(key, dataset, opts, wait_ms)

  defp fresh(_key, _dataset, _polled, _opts, _wait_ms), do: {:error, :not_found}

  defp start(key, dataset, opts, wait_ms) do
    case GenServer.call(__MODULE__, {:start, key, dataset, opts}) do
      :ok -> wait(key, now() + wait_ms)
      {:error, :busy} = busy -> busy
    end
  end

  @impl true
  def handle_call({:start, key, dataset, opts}, {caller, _tag}, state) do
    sweep()

    cond do
      live?(key) ->
        {:reply, :ok, state}

      live_runs() >= max_runs() ->
        {:reply, {:error, :busy}, state}

      true ->
        {:ok, pid} =
          Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
            Process.put(:"$callers", [caller])

            receive do
              :go -> run(key, dataset, opts)
            after
              @go_ms -> :ok
            end
          end)

        :ets.insert(@table, {key, {:running, pid}, dataset.id, now()})
        send(pid, :go)
        {:reply, :ok, state}
    end
  end

  @doc "How many deletes may run at once on this node (`:dataset_delete_max_runs`)."
  def max_runs, do: Application.get_env(:barkpark, :dataset_delete_max_runs, 2)

  defp live?(key) do
    case :ets.lookup(@table, key) do
      [{^key, {:running, pid}, _id, _at}] -> Process.alive?(pid)
      _ -> false
    end
  end

  defp live_runs do
    @table
    |> :ets.select([{{:_, {:running, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.count(&Process.alive?/1)
  end

  defp run(key, dataset, opts) do
    {on_deleted, opts} = Keyword.pop(opts, :on_deleted, fn _ -> :ok end)

    result =
      try do
        DatasetDelete.delete(dataset, opts)
      rescue
        e ->
          Logger.error(
            "dataset delete #{dataset.id} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          {:error, {:delete_failed, :database}}
      end

    with {:ok, receipt} <- result do
      try do
        on_deleted.(receipt)
      rescue
        e -> Logger.error("dataset delete #{dataset.id} on_deleted: #{Exception.message(e)}")
      end
    end

    :ets.insert(@table, {key, {:done, result}, dataset.id, now()})
  end

  defp wait(key, deadline) do
    case :ets.lookup(@table, key) do
      [{^key, {:done, result}, _id, _at} = row] ->
        if take(row), do: result, else: :running

      [{^key, {:running, pid}, _id, _at} = row] ->
        cond do
          Process.alive?(pid) == false and take(row) ->
            {:error, {:delete_failed, :interrupted}}

          Process.alive?(pid) == false ->
            wait(key, deadline)

          now() >= deadline ->
            :running

          true ->
            Process.sleep(@poll_ms)
            wait(key, deadline)
        end

      [] ->
        :running
    end
  end

  # Removes exactly this row, and says whether it was still there: a run that
  # finished between the read and the liveness check has replaced it.
  defp take(row), do: :ets.select_delete(@table, [{row, [], [true]}]) == 1

  defp sweep do
    stale = now() - @keep_ms
    :ets.select_delete(@table, [{{:_, {:done, :_}, :_, :"$1"}, [{:<, :"$1", stale}], [true]}])
  end

  defp now, do: System.monotonic_time(:millisecond)
end
