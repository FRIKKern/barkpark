defmodule Barkpark.ChatHosts.RemoteDispatch do
  @moduledoc "Build-1 RemoteDispatch implementation backed by registered-host leases."

  @behaviour Barkpark.StudioChat.Runtime.RemoteDispatch

  alias Barkpark.ChatHosts
  alias Barkpark.StudioChat.Runtime.Command

  @impl true
  def dispatch(host, %Command{} = command, opts),
    do: ChatHosts.lease_and_enqueue(host, command, opts)
end
