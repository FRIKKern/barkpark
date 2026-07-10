defmodule Barkpark.Plugins.Indx.Supervisor do
  @moduledoc """
  Blast-radius wall around the Indx retriever-seam subsystem.

  Indx is NOT a registered plugin, so its processes are declared statically in
  the tree rather than contributed via `collect_workers/1`. The three of them —
  `Auth` (mints tokens; the natural place an external-config or credential fault
  surfaces at init), `Monitor` (per-scope outcome counters), and `Recovery`
  (re-seats the live-dataset pointer on boot) — are exactly the kind of fallible
  subsystem the query layer already plans to degrade around: `engine=indx` is
  designed to fall back to Postgres when Indx is down. But started FLAT under
  `Barkpark.Supervisor` a crash-LOOPING Indx process would breach the shared
  3/5s restart budget and take Repo/Oban/Endpoint down at the supervision layer
  BEFORE that graceful fallback ever ran.

  Grouping them here contains any Indx crash-loop to this subtree with its own
  intensity (5/10s), so an Indx fault degrades (query layer falls back) instead
  of escalating to a whole-app shutdown.

  Boot-order preserved: children start in list order — `Auth` before `Recovery`
  (Recovery's boot login calls `Auth.token/0`), and this whole supervisor starts
  (all three up) before the top tree moves on to `Oban`, whose `:indx` queue
  jobs also call `Auth.token/0`.
  """
  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      Barkpark.Plugins.Indx.Auth,
      Barkpark.Plugins.Indx.Monitor,
      Barkpark.Plugins.Indx.Recovery
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 10
    )
  end
end
