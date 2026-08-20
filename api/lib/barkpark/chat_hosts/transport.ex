defmodule Barkpark.ChatHosts.Transport do
  @moduledoc false

  use GenServer

  @server __MODULE__.Server

  def enqueue(host_id, lease_id, command), do: call({:enqueue, host_id, lease_id, command})
  def commands(host_id), do: call({:commands, host_id})

  def complete(lease_id), do: call({:complete, lease_id})
  def revoke(host_id), do: call({:revoke, host_id})

  @impl true
  def init(_), do: {:ok, %{commands: %{}}}

  @impl true
  def handle_call({:enqueue, host_id, lease_id, command}, _from, state) do
    commands = Map.put(state.commands, lease_id, {host_id, command})
    {:reply, :ok, %{state | commands: commands}}
  end

  def handle_call({:commands, host_id}, _from, state) do
    commands =
      for {lease_id, {^host_id, command}} <- state.commands,
          do: {lease_id, command}

    {:reply, commands, state}
  end

  def handle_call({:complete, lease_id}, _from, state) do
    {:reply, :ok, %{state | commands: Map.delete(state.commands, lease_id)}}
  end

  def handle_call({:revoke, host_id}, _from, state) do
    commands =
      Map.reject(state.commands, fn {_lease_id, {command_host_id, _command}} ->
        command_host_id == host_id
      end)

    {:reply, :ok, %{state | commands: commands}}
  end

  defp call(message) do
    ensure_server()
    GenServer.call(@server, message)
  end

  # The unlinked lazy owner survives the request process that first needs it.
  # A future application-child registration can replace this without changing
  # the transport contract.
  defp ensure_server do
    case Process.whereis(@server) do
      nil ->
        case GenServer.start(__MODULE__, %{}, name: @server) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
