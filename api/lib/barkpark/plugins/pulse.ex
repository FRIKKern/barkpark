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

  ## Abuse caps (plugin-owned policy)

  The surface is anonymous and CORS-open by design — safety is CAPS, not
  identity. Every cap is billed at the plugin's own call sites through the
  core generic `Barkpark.RateLimiter` (never a plug on the `:public_api`
  pipeline, which would collaterally throttle Bulldocs/Sheets and every other
  public plugin route). Same law as `PublicCors`: mechanism in core, policy
  in the plugin. See `BarkparkWeb.PulseController`.

  | Surface | Cap | Over-cap response |
  |---|---|---|
  | POST `/events` | per-IP token bucket — sustained `rate_per_min`, burst 3 | `429` + `Retry-After: ceil(60/rate_per_min)` |
  | POST `/events` | per-channel UTC-day ceiling — `daily_cap` | `429` + `Retry-After: 3600` |
  | POST `/events` | strict schema + encoded-byte ceiling `max_bytes` | `400 invalid_event` |
  | GET `/recent`, GET `/stats` | per-IP read bucket — 30 burst, 10/sec refill | `429` + `Retry-After: 1` |

  The read bucket is deliberately GENEROUS so a NAT'd office sharing one
  egress IP survives normal polling, while a single-IP read flood (DB
  read-amplification, otherwise unmetered) still hits backpressure. Write and
  read buckets are DISTINCT keys — a client's reads and writes never share a
  budget. Per-IP socket-connect and per-IP cursor caps are a deferred
  residual (charter Decision 5): joins fail closed on unknown channels and
  cursor pushes are already throttled per-socket.

  ## Client backoff contract

  A well-behaved client treats `429` as flow control, not failure:

    * On `429`, read `Retry-After` (seconds) and wait AT LEAST that long
      before retrying — the server tells you exactly when it will accept you.
    * Then back off exponentially on repeated `429`s (e.g. double the wait
      each time) with jitter, capped at **60s** — never a tight retry loop.
    * `400 invalid_event` is the client's bug (bad field/shape/oversize
      payload); do NOT retry it, fix the payload.
    * A dropped realtime socket falls back to polling `GET /recent?since=<id>`
      at a human cadence — the read bucket assumes seconds, not milliseconds,
      between polls.

  ## Trust boundary: X-Forwarded-For is believed only from a trusted front

  Per-IP buckets key on `Barkpark.RateLimiter.client_ip/1`, which believes the
  `x-forwarded-for` chain only when the immediate peer is trusted (loopback, or
  an address in `BARKPARK_TRUSTED_PROXIES`) and then takes the RIGHTMOST hop
  that is not itself a known proxy. Caddy appends the address it actually saw,
  so a client-supplied prefix is discarded and a client reaching the box
  directly cannot rotate its apparent IP to sidestep the per-IP caps — the
  earlier first-hop read could be, and this doc said so.

  The per-channel `daily_cap` remains the source-independent backstop: global
  to the channel, indifferent to source IP, bounding total damage to a vanity
  counter and a 24h ephemeral feed even from a genuine botnet of distinct IPs
  that no per-IP cap can catch.
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
  # plugin-link canonicaliser (Paths.plugin_link_href/2) rewrites
  # `/studio/<x>` links assuming `<x>` is a dataset — which mangled
  # `/studio/pulse` into a bogus `/d/pulse/studio`.
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
