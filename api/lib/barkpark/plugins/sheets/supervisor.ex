defmodule Barkpark.Plugins.Sheets.Supervisor do
  @moduledoc """
  Failure domain for the Sheets collaborative-session subsystem.

  Owns the per-sheet `SessionRegistry` (unique keys), the `SessionSupervisor`
  (a `DynamicSupervisor` the lazily-started, `restart: :temporary` sessions run
  under), and the `Session.ReplayRing` (the named ETS replay table backing
  exactly-once `/ops`). Grouping these under one intermediate supervisor keeps a
  crash in the Sheets registry/ring contained to this subtree — it can no longer
  count against the top budget shared with Repo/Oban/Endpoint.

  This supervisor is also the ETS HEIR of the ring's `:sheets_ops_replay`
  table: `init/1` runs IN this process, so `self()` below is the pid the ring
  names in `:ets.new/2`. A crash of the ring alone therefore hands the table
  here instead of destroying it, and the restarted ring adopts it — see the
  "Ownership" section of `Barkpark.Plugins.Sheets.Session.ReplayRing`, which
  states the two remedies rejected in favour of this one. The transfer arrives
  as a `{:"ETS-TRANSFER", ...}` message `:supervisor` has no clause for: it logs
  one "unexpected message" error report and carries on, and that report is a
  true record of a ring crash, not a fault of its own.

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
      # `self()` IS this supervisor: `Supervisor.init/2` runs in the supervisor
      # process, and the name is registered before `init/1` is called. Passing
      # the pid explicitly (rather than letting the ring look the name up) keeps
      # the heir correct for a restarted subtree, whose pid is new.
      {Barkpark.Plugins.Sheets.Session.ReplayRing, heir: self()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
