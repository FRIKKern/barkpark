defmodule Barkpark.ChatHosts.RemoteDispatch do
  @moduledoc "Build-1 RemoteDispatch implementation backed by registered-host leases."

  @behaviour Barkpark.StudioChat.Runtime.RemoteDispatch

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.AskingLease
  alias Barkpark.StudioChat.Runtime.Command

  # An answer names the run that asked it, so it never reaches a newer run
  # (`AskingLease`, task-754fd6f9a890e75e).
  @impl true
  def dispatch(host, %Command{} = command, opts),
    do: ChatHosts.lease_and_enqueue(host, AskingLease.stamp(host, command), opts)
end
