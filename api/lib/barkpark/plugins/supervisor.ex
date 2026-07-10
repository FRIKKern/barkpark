defmodule Barkpark.Plugins.Supervisor do
  @moduledoc """
  Blast-radius wall around the VOLATILE plugin-contributed worker tier.

  `Barkpark.Plugins.Registry.collect_workers/1` folds every plugin's child
  specs (Pulse.Metrics, Quiz.Bridge, Github.Auth/DrainWorker, OnixEdit, and any
  future/third-party worker) into the tree. Those workers are the most fallible
  children in the app — they validate external config, call out to third-party
  services, and run code the host does not own. Started FLAT under
  `Barkpark.Supervisor` they shared its OTP-default 3-restarts-in-5s budget with
  `Barkpark.Repo`, `Oban`, and `BarkparkWeb.Endpoint`, so a single crash-looping
  plugin — or a burst of plugin workers each crashing once inside the same 5s
  during a Postgres blip — could breach that shared intensity and terminate the
  WHOLE tree, i.e. a contained plugin fault escalating to a total outage.

  This supervisor gives the plugin tier its OWN restart intensity. A plugin
  crash now escalates only to here; `Barkpark.Supervisor` sees at most one child
  (this supervisor) restart, never the churn of the plugins themselves. The
  budget is deliberately wider than the default (5/10s) because this tier
  legitimately churns and a plausible boot-time burst must be absorbed WITHOUT
  escalating to the critical-infra siblings.

  Fresh-install invariant: with no plugins enabled, `plugin_children` is `[]`
  and this supervisor idles with zero children — no behavioural change.
  """
  use Supervisor

  @doc """
  Start the plugin worker tier. `plugin_children` is the (possibly empty) list
  of child specs returned by `Barkpark.Plugins.Registry.collect_workers/1`.
  """
  @spec start_link([Supervisor.child_spec() | {module(), term()} | module()]) ::
          Supervisor.on_start()
  def start_link(plugin_children) when is_list(plugin_children) do
    Supervisor.start_link(__MODULE__, plugin_children, name: __MODULE__)
  end

  @impl true
  def init(plugin_children) do
    Supervisor.init(plugin_children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 10
    )
  end
end
