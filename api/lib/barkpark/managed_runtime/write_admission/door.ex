defmodule Barkpark.ManagedRuntime.WriteAdmission.Door do
  @moduledoc """
  Door-level write admission for content and media owners (C083).

  A passthrough unless `config :barkpark, :write_admission` is enabled, so
  ordinary and shared servers change nothing. When enabled, every wrapped write
  checks out from the instance coordinator in the calling process, runs, and
  settles after its effects. Children spawned inside the write (plugin hooks,
  supervised tasks) inherit the admission through `$callers`; the settlement
  waits a bounded time for them and otherwise leaves the admission pending,
  which is honest: the coordinator will not report a clean drain.

  A raise, exit or throw settles as `:failed`, which leaves the instance in
  recovery if an operation was closing. A returned `{:error, _}` is a controlled
  outcome and settles normally. A refusal surfaces as
  `{:error, {:write_admission, reason}}`: `:admission_closed` during a hold,
  `:unavailable` or `:unconfigured` when admission is enabled but no
  coordinator is reachable. Enabled without a coordinator fails closed.
  """

  alias Barkpark.ManagedRuntime.WriteAdmission
  require Logger

  @children_wait_ms 5_000
  @poll_ms 20

  @doc "True when this instance admits writes through the coordinator."
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc false
  def config, do: Application.get_env(:barkpark, :write_admission, [])

  @doc "The coordinator name for this instance, or nil when unconfigured."
  def server do
    case Keyword.fetch(config(), :instance_id) do
      {:ok, id} when is_binary(id) -> {:global, {WriteAdmission, id}}
      _ -> nil
    end
  end

  @doc "Run a write under admission; refuse with `{:error, {:write_admission, reason}}`."
  def admit(fun) when is_function(fun, 0) do
    if enabled?(), do: admitted(fun), else: fun.()
  end

  @doc """
  Run a write if admission is open; return `skipped` instead of refusing.

  For read-side repairs such as an HTML cache refresh, where a held instance
  must serve the derived result without persisting it.
  """
  def admit_or_skip(fun, skipped) when is_function(fun, 0) do
    if enabled?() do
      case admitted(fun) do
        {:error, {:write_admission, _}} -> skipped
        other -> other
      end
    else
      fun.()
    end
  end

  defp admitted(fun) do
    case checkout() do
      {:ok, ticket} ->
        try do
          fun.()
        rescue
          exception ->
            settle(ticket, :failed)
            reraise exception, __STACKTRACE__
        catch
          kind, value ->
            settle(ticket, :failed)
            :erlang.raise(kind, value, __STACKTRACE__)
        else
          result ->
            settle(ticket, :settled)
            result
        end

      {:error, reason} ->
        {:error, {:write_admission, reason}}
    end
  end

  defp checkout do
    case server() do
      nil ->
        {:error, :unconfigured}

      name ->
        try do
          WriteAdmission.checkout(name)
        catch
          :exit, _ -> {:error, :unavailable}
        end
    end
  end

  defp settle(ticket, outcome, waited \\ 0) do
    result =
      try do
        WriteAdmission.checkin(server(), ticket, outcome)
      catch
        :exit, _ -> {:error, :unavailable}
      end

    case result do
      :ok ->
        :ok

      {:error, :children_pending} when waited < @children_wait_ms ->
        Process.sleep(@poll_ms)
        settle(ticket, outcome, waited + @poll_ms)

      {:error, reason} ->
        Logger.warning(
          "write admission left unsettled: #{inspect(reason)}; the instance cannot report a clean drain until it is reconciled"
        )

        {:error, reason}
    end
  end
end
