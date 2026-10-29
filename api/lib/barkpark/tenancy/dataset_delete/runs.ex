defmodule Barkpark.Tenancy.DatasetDelete.Runs do
  @moduledoc """
  Runs `Tenancy.DatasetDelete.delete/2` off the request (task-10608b4831a0e9b8).

  ```
  DELETE ─► delete/5 ─┬─ no run: claim {project, slug}, start a task, wait ≤ wait_ms
                      ├─ a run is live: wait ≤ wait_ms
                      └─ a finished run nobody read: its result, once
               result ─► the controller answers it; still running ─► :running (202)
  ```

  A delete of thousands of documents outlives any request budget, so the
  request waits a few seconds and then answers `:running`; the caller repeats
  the DELETE until it gets the result. The task runs the one transaction, so
  an interrupted run (node restart, killed task) rolls back and leaves the
  dataset whole. The next DELETE starts it again.

  Node-local ETS, one row per `{project_id, slug}`:
  `{key, {:running, pid} | {:done, result}, dataset_id, at}`. A finished row
  is dropped when it is read, when the name now holds another dataset, or an
  hour after it finished.
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
  `opts[:on_deleted]` runs with the receipt in the task, after the commit.
  """
  @spec delete(binary(), String.t(), Dataset.t() | nil, keyword(), non_neg_integer()) ::
          term() | :running
  def delete(project_id, slug, dataset, opts, wait_ms) do
    key = {project_id, slug}
    current = dataset && dataset.id

    case :ets.lookup(@table, key) do
      [{^key, {:done, result}, id, _at} = row] when current in [nil, id] ->
        if take(row), do: result, else: delete(project_id, slug, dataset, opts, wait_ms)

      [{^key, {:running, pid}, _id, _at} = row] ->
        cond do
          Process.alive?(pid) -> wait(key, now() + wait_ms)
          take(row) -> restart(key, dataset, opts, wait_ms)
          true -> delete(project_id, slug, dataset, opts, wait_ms)
        end

      [row] ->
        if take(row),
          do: restart(key, dataset, opts, wait_ms),
          else: delete(project_id, slug, dataset, opts, wait_ms)

      [] ->
        restart(key, dataset, opts, wait_ms)
    end
  end

  defp restart(_key, nil, _opts, _wait_ms), do: {:error, :not_found}

  defp restart(key, dataset, opts, wait_ms) do
    sweep()
    start(key, dataset, opts)
    wait(key, now() + wait_ms)
  end

  defp start(key, dataset, opts) do
    {:ok, pid} =
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        receive do
          :go -> run(key, dataset, opts)
        after
          @go_ms -> :ok
        end
      end)

    if :ets.insert_new(@table, {key, {:running, pid}, dataset.id, now()}),
      do: send(pid, :go),
      else: Process.exit(pid, :kill)
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
