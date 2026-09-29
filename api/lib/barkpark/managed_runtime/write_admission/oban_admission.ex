defmodule Barkpark.ManagedRuntime.WriteAdmission.ObanAdmission do
  @moduledoc """
  Admits every Oban job as a writer of the managed instance (C083 slice 3).

  Oban has no middleware, and 25 workers write through different paths, so
  admission rides the same telemetry seam the job-pool router uses: on
  `[:oban, :job, :start]` the job process checks out from the coordinator, on
  `:stop` it settles, on `:exception` it settles as `:failed`. The ticket lives
  in the job process's dictionary; a job that spawns children still covers them
  through `$callers`.

  A telemetry handler cannot stop a job, so this is not the refusal: the
  refusal is `WriteAdmission.Operation`, which pauses every queue BEFORE the
  hold begins, so no job is dequeued while admission is closing or held, and
  the drain then waits for the jobs already admitted here. A job that still
  reaches `:start` while closed is logged at error level and runs unadmitted;
  that log line is the evidence the ordering was violated.

  Attached only when write admission is enabled; a no-op otherwise.
  """

  alias Barkpark.ManagedRuntime.WriteAdmission
  alias Barkpark.ManagedRuntime.WriteAdmission.Door
  require Logger

  @handler_id "barkpark-write-admission-oban"
  @ticket_key :barkpark_write_admission_job_ticket

  @doc "Attach the job handlers (idempotent). Safe to call when admission is disabled."
  def attach do
    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:oban, :job, :start], _measurements, meta, _config) do
    if Door.enabled?() do
      case checkout() do
        {:ok, ticket} ->
          Process.put(@ticket_key, ticket)

        {:error, reason} ->
          Logger.error(
            "write admission refused an Oban job that was still dequeued: #{inspect(reason)} " <>
              "worker=#{inspect(meta[:worker])} queue=#{inspect(meta[:queue])}; " <>
              "queues must be paused before a hold begins (WriteAdmission.Operation)"
          )
      end
    end

    :ok
  end

  def handle_event([:oban, :job, :stop], _measurements, _meta, _config), do: settle(:settled)
  def handle_event([:oban, :job, :exception], _measurements, _meta, _config), do: settle(:failed)

  defp checkout do
    case Door.server() do
      nil -> {:error, :unconfigured}
      name -> try_call(fn -> WriteAdmission.checkout(name) end)
    end
  end

  defp settle(outcome) do
    case Process.delete(@ticket_key) do
      nil ->
        :ok

      ticket ->
        case try_call(fn -> WriteAdmission.checkin(Door.server(), ticket, outcome) end) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("write admission left an Oban job unsettled: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp try_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
