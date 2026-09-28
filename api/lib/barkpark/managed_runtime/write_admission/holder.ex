defmodule Barkpark.ManagedRuntime.WriteAdmission.Holder do
  @moduledoc """
  The process that owns an HTTP-requested hold (C083, trusted hold endpoint).

  The coordinator binds a hold to the process that began it and moves the
  instance to `recovery_required` if that process dies, so a request process
  cannot own one. This serving-tree child does instead: it begins the hold
  through `Operation.hold/2`, keeps the ticket, and hands the caller an opaque
  capability bound to the operation, the server boot identity and the
  admission generation. Status and reopen take that capability back.

  One hold at a time. A repeated request for the same operation reconciles to
  the same capability; a different operation while held is refused. Reopen
  advances the generation, so the old capability refuses afterwards. If this
  process dies the coordinator keeps the instance blocked for explicit
  recovery, never reopening on its own.
  """

  use GenServer

  alias Barkpark.ManagedRuntime.WriteAdmission
  alias Barkpark.ManagedRuntime.WriteAdmission.{Door, Operation}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Begin (or reconcile) the hold for `operation`; returns `{:ok, view}`."
  def hold(server \\ __MODULE__, operation), do: call(server, {:hold, operation})

  @doc "The current view of the hold `capability` names."
  def status(server \\ __MODULE__, capability), do: call(server, {:status, capability})

  @doc "Abort the hold `capability` names: reopen admission, resume queues."
  def reopen(server \\ __MODULE__, capability), do: call(server, {:reopen, capability})

  @doc "The instance view: phase, generation, boot, pending roots, current operation."
  def instance(server \\ __MODULE__), do: call(server, :instance)

  @doc "Explicit recovery from `recovery_required`; see `WriteAdmission.recover/3`."
  def recover(server \\ __MODULE__, generation, pending),
    do: call(server, {:recover, generation, pending})

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(_opts), do: {:ok, %{hold: nil}}

  @impl true
  def handle_call({:hold, operation}, _from, state) when is_binary(operation) do
    case state.hold do
      %{operation: ^operation} = hold ->
        {:reply, {:ok, view(hold)}, state}

      %{} ->
        {:reply, {:error, :admission_closed}, state}

      nil ->
        case Operation.hold(operation) do
          {:ok, _phase, {boot, generation, _} = ticket} ->
            hold = %{
              operation: operation,
              ticket: ticket,
              capability: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
              boot: boot,
              generation: generation
            }

            {:reply, {:ok, view(hold)}, %{state | hold: hold}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:hold, _}, _from, state), do: {:reply, {:error, :invalid_operation}, state}

  def handle_call({:status, capability}, _from, state) do
    case state.hold do
      %{capability: ^capability} = hold -> {:reply, {:ok, view(hold)}, state}
      _ -> {:reply, {:error, :invalid_hold}, state}
    end
  end

  def handle_call({:reopen, capability}, _from, state) do
    case state.hold do
      %{capability: ^capability} = hold ->
        case Operation.reopen(hold.ticket) do
          :ok ->
            {:reply, {:ok, %{phase: :open, generation: current().generation, boot: hold.boot}},
             %{state | hold: nil}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :invalid_hold}, state}
    end
  end

  def handle_call(:instance, _from, state) do
    case current() do
      %{phase: phase} = status when phase in [:unconfigured, :unavailable] ->
        {:reply, {:error, phase}, state}

      status ->
        {:reply,
         {:ok,
          %{
            phase: status.phase,
            generation: status.generation,
            boot: status.boot,
            pending: status.pending,
            operation: status.operation,
            held: if(state.hold, do: state.hold.operation, else: nil)
          }}, state}
    end
  end

  def handle_call({:recover, generation, pending}, _from, state) do
    case Operation.recover(generation, pending) do
      :ok ->
        status = current()

        {:reply, {:ok, %{phase: status.phase, generation: status.generation, boot: status.boot}},
         %{state | hold: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp view(hold) do
    %{
      capability: hold.capability,
      operation: hold.operation,
      phase: current().phase,
      generation: hold.generation,
      boot: hold.boot
    }
  end

  defp current do
    case Door.server() do
      nil -> %{phase: :unconfigured, generation: nil}
      server -> WriteAdmission.status(server)
    end
  catch
    :exit, _ -> %{phase: :unavailable, generation: nil}
  end
end
