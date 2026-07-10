defmodule Barkpark.Plugins.Sheets.Supervisor do
  @moduledoc """
  Failure domain for the Sheets collaborative-session subsystem.

  Owns the per-sheet `SessionRegistry` (unique keys), the `SessionSupervisor`
  (a `DynamicSupervisor` the lazily-started, `restart: :temporary` sessions run
  under), and the `Session.ReplayRing` (the named ETS replay table backing
  exactly-once `/ops`). Grouping these under one intermediate supervisor keeps a
  crash in the Sheets registry/ring contained to this subtree — it can no longer
  count against the top budget shared with Repo/Oban/Endpoint.

  CORE and plugin-independent (fresh-install invariant): these processes always
  start; only the HTTP ops route is plugin wiring. Needs `Repo` and
  `Phoenix.PubSub` up first — both are started before this supervisor in
  `Barkpark.Application`.
  """
  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: Barkpark.Plugins.Sheets.SessionRegistry},
      {DynamicSupervisor,
       name: Barkpark.Plugins.Sheets.SessionSupervisor, strategy: :one_for_one},
      Barkpark.Plugins.Sheets.Session.ReplayRing
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
