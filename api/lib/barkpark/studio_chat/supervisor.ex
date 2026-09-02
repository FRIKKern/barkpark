defmodule Barkpark.StudioChat.Supervisor do
  @moduledoc """
  Failure domain for the Studio Claude-chat runtime subsystem.

  Owns the single-writer `SessionRegistry`, the `RecorderRegistry`, the
  `RuntimeSupervisor` (`DynamicSupervisor` the server-owned Recorders start
  under), the `AgentStateSweeper` (herd-layer staleness sweep, charter D42h — its
  synchronous init sweep runs here, BEFORE the Endpoint starts, so it beats the
  first request), the `BlockedSweeper` (herd-layer walk-away safety, charter
  D57h–D59h — fires one debounced webhook per session blocked past its
  workspace threshold, boot sweep + 60s re-arm beside `AgentStateSweeper`), and
  the `FleetHub` (the herd fleet wire, charter D44h/D45h —
  ONE subscription to the activity topic re-projected onto the fleet stream).
  Grouping them under one intermediate supervisor contains a
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
      {DynamicSupervisor, name: Barkpark.StudioChat.RuntimeSupervisor, strategy: :one_for_one},
      Barkpark.StudioChat.AgentStateSweeper,
      Barkpark.StudioChat.BlockedSweeper,
      Barkpark.StudioChat.FleetHub
    ]

    # WIDER than the OTP default 3/5s, which is the SAME budget
    # `Barkpark.Supervisor` runs — with identical budgets the crash-loop this
    # tier exists to contain exhausts both walls in the same window and
    # escalates to the top, taking Repo, Oban and the Endpoint with it. The
    # concrete path: `AgentStateSweeper`/`BlockedSweeper` wrap work in
    # `safe_sweep`'s `rescue`, which does NOT catch a `GenServer.call` :exit out
    # of a saturated Repo pool (config/runtime.exs records a measured
    # pool-exhaustion incident), so four crashes inside five seconds is reachable.
    # Matches `Barkpark.Plugins.Supervisor` and `Indx.Supervisor`.
    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 10
    )
  end
end
