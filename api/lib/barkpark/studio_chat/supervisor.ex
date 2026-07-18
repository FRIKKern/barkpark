defmodule Barkpark.StudioChat.Supervisor do
  @moduledoc """
  Failure domain for the Studio Claude-chat runtime subsystem.

  Owns the single-writer `SessionRegistry`, the `RecorderRegistry`, the
  `RuntimeSupervisor` (`DynamicSupervisor` the server-owned Recorders start
  under), the `Notifier` (per-session debounce ledger for needs-you mails), and
  the `AgentStateSweeper` (herd-layer staleness sweep, charter D42h — its
  synchronous init sweep runs here, BEFORE the Endpoint starts, so it beats the
  first request). Grouping them under one intermediate supervisor contains a
  crash in any of these to this subtree, so it can no longer count against the
  top restart budget shared with Repo/Oban/Endpoint.

  Needs `Phoenix.PubSub` up first (Recorders rebroadcast frames on it) — started
  before this supervisor in `Barkpark.Application`.
  """
  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: Barkpark.StudioChat.SessionRegistry},
      {Registry, keys: :unique, name: Barkpark.StudioChat.RecorderRegistry},
      {DynamicSupervisor,
       name: Barkpark.StudioChat.RuntimeSupervisor, strategy: :one_for_one},
      Barkpark.StudioChat.Notifier,
      Barkpark.StudioChat.AgentStateSweeper
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
