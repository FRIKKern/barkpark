defmodule Barkpark.ManagedRuntime.WriteAdmission.Operation do
  @moduledoc """
  The ordered hold for a managed instance (C083 slice 3): pause every Oban
  queue, then close admission; on abort, reopen admission, then resume queues.

  Pausing first is what makes background writers refusable: a paused queue
  dequeues nothing, jobs already running were admitted at their start by
  `ObanAdmission` and are drained by the coordinator, and `Sync.Worker` reaches
  the database only through `Content.apply_mutations`, which is a door. This
  module is the seam a later trusted endpoint calls; it advertises nothing and
  is refused outright when write admission is not enabled.
  """

  alias Barkpark.ManagedRuntime.WriteAdmission
  alias Barkpark.ManagedRuntime.WriteAdmission.Door

  @doc """
  Pause queues and begin the hold for `operation`. Returns
  `{:ok, :closing | :held, hold}`; the caller observes `held?/1` until the
  drain completes. Refuses with `{:error, reason}` and leaves queues running
  when admission is disabled, unconfigured or already closed.
  """
  def hold(operation, opts \\ []) when is_binary(operation) do
    oban = Keyword.get(opts, :oban, Oban)

    with :ok <- enabled(),
         {:ok, server} <- server(),
         :ok <- pause(oban) do
      generation = WriteAdmission.status(server).generation

      case WriteAdmission.begin_hold(server, operation, generation) do
        {:ok, phase, hold} ->
          {:ok, phase, hold}

        {:error, reason} ->
          # Nothing is held: give the queues back before reporting.
          _ = resume(oban)
          {:error, reason}
      end
    end
  end

  @doc "True once every admitted writer, jobs included, has settled."
  def held?(hold) do
    with {:ok, server} <- server(), do: WriteAdmission.held?(server, hold)
  end

  @doc "Abort a held operation: reopen admission first, then resume the queues."
  def reopen(hold, opts \\ []) do
    oban = Keyword.get(opts, :oban, Oban)

    with {:ok, server} <- server(),
         :ok <- WriteAdmission.reopen(server, hold) do
      resume(oban)
    end
  end

  @doc "Explicit recovery after a failed or interrupted hold: reopen admission, then resume the queues."
  def recover(generation, pending, opts \\ []) do
    oban = Keyword.get(opts, :oban, Oban)

    with :ok <- enabled(),
         {:ok, server} <- server(),
         :ok <- WriteAdmission.recover(server, generation, pending) do
      resume(oban)
    end
  end

  defp enabled, do: if(Door.enabled?(), do: :ok, else: {:error, :write_admission_disabled})

  defp server do
    case Door.server() do
      nil -> {:error, :unconfigured}
      name -> {:ok, name}
    end
  end

  defp pause(oban) do
    Oban.pause_all_queues(oban)
  catch
    :exit, _ -> {:error, :oban_unavailable}
  end

  defp resume(oban) do
    Oban.resume_all_queues(oban)
  catch
    :exit, _ -> {:error, :oban_unavailable}
  end
end
