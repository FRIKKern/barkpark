defmodule Barkpark.Plugins.Pulse do
  @moduledoc """
  Pulse — thin plugin wiring for the public anonymous event-channel
  machinery in `Barkpark.Pulse` (the Shared Storm substrate; design paper
  `shared-storm`, epic `shared-storm-epic`).

  What this module contributes (the tasks.ex/tickets.ex precedent — core
  owns the machinery, the plugin owns the mounting):

    * `register_routes/1` — the three-endpoint public surface on the
      `:public_api` bucket (anonymous + `PublicCors`, mounted under
      `/v1/plugins`): POST events, GET recent, GET stats, plus the
      `{:options, …}` preflight routes browsers require for cross-origin
      POSTs (the router only matches declared verbs — without these the
      preflight 404s and every browser write fails).
    * `oban_crontab/0` — the hourly `Barkpark.Pulse.SweepWorker` TTL sweep
      (events are ephemeral; the counter row is durable).
    * `register_schemas/1` — `[]`, deliberately. Pulse events are tiny
      high-volume ephemeral ROWS, not documents: the Content substrate's
      draft logic, lifecycle hooks, and webhook fan-out are pure overhead
      per strike, and TTL-deleting documents would spam mutation events.

  Channels come from `config :barkpark, :pulse_channels` (env
  `BARKPARK_PULSE_CHANNELS` in prod) — nothing is open by default; with no
  channels configured every route 404s. Plugin off = zero routes; the
  tables sit dark.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/pulse/plugin.json"

  # Installed but OFF by default — surfaced under the "Plugins" node only when
  # an admin enables it for the workspace.
  @impl Barkpark.Plugin
  def default_enabled?, do: false

  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:post, "/pulse/:channel/events", BarkparkWeb.PulseController, :create, auth: :public_api},
      {:get, "/pulse/:channel/recent", BarkparkWeb.PulseController, :recent, auth: :public_api},
      {:get, "/pulse/:channel/stats", BarkparkWeb.PulseController, :stats, auth: :public_api},
      # Browser preflights for the cross-origin POST (and belt-and-braces on
      # the GETs — some clients preflight custom-header GETs too). PublicCors
      # halts these with 204 before the controller action runs.
      {:options, "/pulse/:channel/events", BarkparkWeb.PulseController, :preflight,
       auth: :public_api},
      {:options, "/pulse/:channel/recent", BarkparkWeb.PulseController, :preflight,
       auth: :public_api},
      {:options, "/pulse/:channel/stats", BarkparkWeb.PulseController, :preflight,
       auth: :public_api},
      # Read-only ops-console dashboard: the channel counters live in plain
      # tables outside the document model, so the schema-driven desk can't show
      # them — this :ops LiveView does, mounted at /admin/pulse (linked from the
      # Structure desk). :ops (not /studio) so the desk-link scoper leaves the
      # /admin path intact — see desk_items/1.
      {:live, "/pulse", Barkpark.Plugins.Pulse.Web.DashboardLive, :index, auth: :ops}
    ]
  end

  # Surface the dashboard in the Structure desk. The link points at the
  # OPS-console path `/admin/pulse` (not `/studio/...`): the host's
  # `scoped_plugin_href` rewrites `/studio/<x>` links assuming `<x>` is a
  # dataset — which mangled `/studio/pulse` into a bogus `/d/pulse/studio`.
  # An `/admin/...` path is left untouched on both flat and scoped surfaces,
  # the same proven shape onixedit's desk consoles use.
  @impl Barkpark.Plugin
  def desk_items(_dataset) do
    [%{type: :link, label: "Lightning Storm", path: "/admin/pulse", icon: "zap"}]
  end

  # The live cost sampler (scheduler utilization, message rates) — supervised
  # only when the plugin is on; with it off the hot-path bumps are no-ops.
  @impl Barkpark.Plugin
  def register_workers(_sup), do: [Barkpark.Pulse.Metrics]

  @impl Barkpark.Plugin
  def oban_crontab do
    # Hourly, off the hour-mark rush.
    [{"17 * * * *", Barkpark.Pulse.SweepWorker}]
  end
end
