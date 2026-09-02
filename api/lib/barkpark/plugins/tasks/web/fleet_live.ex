defmodule Barkpark.Plugins.Tasks.Web.FleetLive do
  @moduledoc """
  The Studio **Fleet desk tile** — a thin, read-only roster of the Personal Dev
  Fleet's listeners, mounted in Studio at `/admin/fleet` (the `:ops` bucket,
  admin-gated). It is the browser sibling of `bp fleet roster`: a compact
  `worker · status · last-seen` table over the live `type:"listener"` documents,
  nothing more. This is a TILE, not the full Fleet Card — it observes, it never
  provisions or mutates.

  ## The read (the ONE explicit global opt-in)

  The roster is read through `Barkpark.Tasks.Fleet.roster/2` with the dataset
  passed EXPLICITLY (`@dataset "production"`) and `global: true` — the named,
  greppable cross-tenant opt-in, and this tile is its ONLY caller. The flat
  `GET /v1/fleet/roster` endpoint no longer shares that shape: the 2026-09-01
  ruling on task-4e2986e8609670d7 scoped the HTTP read to `scope_opts(conn)`,
  leaving this opt-in as the one surface that still sees every workspace. It is
  `:ops`-gated (admin) today and is exactly what an OPERATOR tier should absorb
  when task-c7e2b87f1bbca815 lands — the ruling reserves the global view for
  that tier, not for an `admin` bit. A socket-scoped read (`LiveScope` /
  `scope_opts(socket)`) is still FORBIDDEN here: it resolves a different
  workspace source than the writer and fail-closes to an EMPTY roster
  INVISIBLY (PDF-D19). Server-side staleness is already baked into each row's
  `status` (`Fleet.roster` derives `offline` at read time), so this LiveView
  renders the server's verdict and never re-computes "is this stale" — the one
  staleness formula lives in `Fleet` (`@canonical fleet-presence-staleness`).

  ## Poll, not subscribe

  A slow 5s `:refresh` re-read keeps the tile honest — no PubSub subscription
  (the pulse/github-ops dashboard precedent). Heartbeats are zero-row writes
  (PDF-D17) that intentionally emit NO broadcast, so there is nothing to
  subscribe to; a poll is the only correct read. The disconnected (dead) mount
  paints a DB-free loading skeleton and issues ZERO roster reads — the projected
  roster only loads once, on connect (the board_live/#2402 connected?-gate
  precedent); admin-gated, so no crawler ever consumes the dead render.

  ## Status pills (PDF-D23 vocabulary, complete)

  Every row wears exactly one pill: the four self-declared/derived live states
  `idle · working · blocked · offline`, PLUS `provisioning` — a cloud-written
  state (Wave C) that is LIVE now and gets its own distinct pill. `provisioning`
  is deliberately NEVER styled as online/reachable: a box coming up is not yet
  listening. Any unrecognized status falls back to the neutral `idle` styling
  rather than crashing the render.

  Mounted via `Barkpark.Plugins.Tasks.register_routes/1`'s
  `{:live, "/fleet", …, auth: :ops}` under the router's
  `plugin_routes(scope: :ops)` block, so the `:ops` on_mount admin gate always
  guards it. The whole surface — this LiveView, its desk link and its top-menu
  tab — disappears when the Tasks plugin is off (the fresh-install invariant):
  the route only resolves a live handler when `tasks` is whitelisted, and the
  desk/menu entries are Tasks-plugin callbacks the enablement highway skips for
  a disabled plugin.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Tasks.Fleet
  alias BarkparkWeb.Studio.TokensGen

  @refresh_ms 5_000
  @dataset "production"

  # PDF-D23 vocabulary, complete. `offline` is derived at read time by
  # `Fleet.roster`; `provisioning` is cloud-written (Wave C, live now). The dot
  # + track-tint colors are the fleet-status DATA tones emitted from
  # design/tokens.json (color.fleetStatus) into the generated, literal-exempt
  # `BarkparkWeb.Studio.TokensGen` — CSP-safe inline styles fed from the token
  # system, never a hand-copied hex (mirrors presence_state.ex's
  # `TokensGen.presence_palette/0`). Resolved at compile time, like @colors there.
  # Map is status-string => hex; the pill label is the status itself.
  @fleet_colors TokensGen.fleet_status()

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected, do: Process.send_after(self(), :refresh, @refresh_ms)

    # Guard the read behind connected?/1: the disconnected render is discarded
    # the instant the socket connects and mount re-runs, so reading the roster
    # there is pure waste (2× per open). Paint an empty skeleton on the dead
    # render; load the real roster ONCE, on connect (board_live/ops_live idiom).
    roster = if connected, do: Fleet.roster(@dataset, global: true), else: []

    {:ok,
     socket
     |> assign(:loading, not connected)
     |> assign(:roster, roster)}
  end

  # Slow periodic re-read — the tile's only heartbeat (no PubSub; beats emit no
  # broadcast, so a poll is the only correct read — PDF-D17).
  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :roster, Fleet.roster(@dataset, global: true))}
  end

  # A stray message (there is no subscription, but be defensive) never crashes
  # the socket.
  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{loading: true} = assigns) do
    ~H"""
    <main class="container" style="max-width: 52rem;" data-role="fleet-loading">
      <h1>📡 Fleet</h1>
      <p style="display:flex; align-items:center; gap:0.6rem; opacity:0.7;">
        <span
          aria-hidden="true"
          style="width:8px; height:8px; border-radius:999px; background:var(--primary); display:inline-block;"
        >
        </span>
        Loading the fleet roster…
      </p>
    </main>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <main class="container" style="max-width: 52rem;" data-role="fleet-tile">
      <h1>📡 Fleet</h1>
      <p>
        <small style="opacity:0.7;">
          Read-only roster of the listeners attached to this home base — who is
          listening, doing what, since when. Live over <code>type:listener</code>
          documents, refreshed every 5&nbsp;s. This is a view; it never provisions.
        </small>
      </p>

      <div :if={@roster == []} data-role="fleet-empty" style="margin:1.6rem 0;">
        <p>
          <em>No listeners yet.</em>
          Start one with the <code>fleet-listener</code> skill (or
          <code>bp fleet beat &lt;worker&gt;</code>) and it appears here on its first heartbeat.
        </p>
      </div>

      <div :if={@roster != []} style="overflow-x:auto; margin:1.4rem 0;">
        <table
          style="width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums;"
          data-role="fleet-roster"
        >
          <thead>
            <tr style="text-align:left; opacity:0.6; font-size:0.85rem;">
              <th style="padding:0.4rem 0.7rem;">worker</th>
              <th style="padding:0.4rem 0.7rem;">status</th>
              <th style="padding:0.4rem 0.7rem;">last seen</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @roster}
              data-role="fleet-row"
              data-worker={row["worker"]}
              data-status={row["status"]}
              style="border-top:1px solid var(--border);"
            >
              <td style="padding:0.45rem 0.7rem;">
                <strong><%= row["worker"] || "—" %></strong>
                <span :if={row["task"]} style="opacity:0.6;">· <%= row["task"] %></span>
              </td>
              <td style="padding:0.45rem 0.7rem;">
                <% {label, color} = pill(row["status"]) %>
                <span
                  data-role="fleet-pill"
                  data-status={row["status"]}
                  style={pill_style(color)}
                >
                  <span
                    aria-hidden="true"
                    style={"width:7px;height:7px;border-radius:999px;display:inline-block;background:#{color};"}
                  >
                  </span>
                  <%= label %>
                </span>
              </td>
              <td style="padding:0.45rem 0.7rem;" data-role="fleet-last-seen">
                <%= relative_age(row["last_seen"], @now) %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </main>
    """
  end

  # ── Pure helpers (public so they're unit-testable without a full mount) ──────

  @doc """
  The pill `{label, color}` for a roster status. Covers the complete PDF-D23
  vocabulary — `idle · working · blocked · offline · provisioning`; any
  unrecognized status falls back to the neutral `idle` styling so a future/
  unexpected status renders instead of crashing the row.
  """
  @spec pill(String.t() | nil) :: {String.t(), String.t()}
  def pill(status) when is_binary(status) do
    case Map.fetch(@fleet_colors, status) do
      {:ok, color} -> {status, color}
      :error -> idle_pill()
    end
  end

  def pill(_), do: idle_pill()

  defp idle_pill, do: {"idle", Map.fetch!(@fleet_colors, "idle")}

  @doc """
  A compact relative age (`"just now"`, `"12s"`, `"5m"`, `"2h"`, `"3d"`) from an
  ISO8601 `last_seen` string to `now`. A missing or unparsable timestamp reads
  `"—"` (never a crash, never a fabricated age).
  """
  @spec relative_age(String.t() | nil, DateTime.t()) :: String.t()
  def relative_age(last_seen, %DateTime{} = now) when is_binary(last_seen) do
    case DateTime.from_iso8601(last_seen) do
      {:ok, seen, _offset} -> humanize(max(DateTime.diff(now, seen, :second), 0))
      _ -> "—"
    end
  end

  def relative_age(_last_seen, _now), do: "—"

  defp humanize(s) when s < 5, do: "just now"
  defp humanize(s) when s < 60, do: "#{s}s"
  defp humanize(s) when s < 3_600, do: "#{div(s, 60)}m"
  defp humanize(s) when s < 86_400, do: "#{div(s, 3_600)}h"
  defp humanize(s), do: "#{div(s, 86_400)}d"

  defp pill_style(color) do
    "display:inline-flex;align-items:center;gap:0.4rem;padding:0.1rem 0.55rem;" <>
      "border-radius:999px;font-size:0.82rem;line-height:1.5;" <>
      "color:#{color};border:1px solid #{color};" <>
      "background:color-mix(in srgb, #{color} 12%, transparent);"
  end
end
