defmodule Barkpark.StudioChat.Runtime.RemoteSecrets do
  @moduledoc false

  use GenServer

  @server __MODULE__.Server

  def put(value) when is_map(value) do
    id = Ecto.UUID.generate()
    :ok = call({:put, id, value})
    id
  end

  def fetch(id) when is_binary(id), do: call({:fetch, id})
  def fetch(_id), do: nil

  def delete(id) when is_binary(id), do: call({:delete, id})
  def delete(_id), do: :ok

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:put, id, value}, _from, state),
    do: {:reply, :ok, Map.put(state, id, value)}

  def handle_call({:fetch, id}, _from, state),
    do: {:reply, Map.get(state, id), state}

  def handle_call({:delete, id}, _from, state),
    do: {:reply, :ok, Map.delete(state, id)}

  defp call(message) do
    ensure_server()
    GenServer.call(@server, message)
  end

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
