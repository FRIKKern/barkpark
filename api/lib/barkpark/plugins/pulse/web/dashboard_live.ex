defmodule Barkpark.Plugins.Pulse.Web.DashboardLive do
  @moduledoc """
  Read-only Studio dashboard for the Pulse channels (Shared Storm).

  The counter and events live in plain Postgres tables outside the document
  model, so Studio's schema-driven desk can't render them on its own. This
  admin LiveView surfaces them: for every configured channel it shows the
  durable total-ever counter (the "strikes ever" number), plus today and the
  last hour, and it ticks LIVE — it subscribes to each channel's broadcast
  topic, so a strike anywhere bumps the number here in real time, with a slow
  periodic refresh for the windowed stats and the TTL sweep.

  Mounted at `/admin/pulse` via the plugin's `register_routes/1` (`:ops`
  bucket) and linked from the Structure desk via `desk_items/1`. Purely
  observational — no writes, no controls.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Pulse
  alias Barkpark.Pulse.Metrics

  @refresh_ms 5_000
  @vitals_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    # The disconnected (dead) render is discarded by the client the instant the
    # LiveView socket connects, so running the three DB projections there is
    # pure waste — 3 discarded queries per open (2× per page load). Gate the
    # loaders behind `connected?/1` and paint a loading skeleton on the dead
    # render; the real data arrives on connect. (#2402 connected?-mount scar.)
    socket =
      if connected?(socket) do
        for name <- channel_names(), do: BarkparkWeb.Endpoint.subscribe("pulse:" <> name)
        Process.send_after(self(), :refresh, @refresh_ms)
        Process.send_after(self(), :vitals, @vitals_ms)

        socket
        |> assign(:loading, false)
        |> assign(:rows, load_rows())
        |> assign(:vitals, load_vitals())
        |> assign(:storage, safe_storage())
      else
        socket
        |> assign(:loading, true)
        |> assign(:rows, [])
        |> assign(:vitals, placeholder_vitals())
        |> assign(:storage, %{events_bytes: 0, counters_bytes: 0, event_rows: 0})
      end

    {:ok, socket}
  end

  # a strike broadcast on any channel topic — bump that channel's total live
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "strike", topic: "pulse:" <> name, payload: p},
        socket
      ) do
    total = Map.get(p, :total)

    rows =
      Enum.map(socket.assigns.rows, fn row ->
        if row.name == name and is_integer(total),
          do: %{row | total: total, today: row.today + 1, last_hour: row.last_hour + 1},
          else: row
      end)

    {:noreply, assign(socket, :rows, rows)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  # periodic re-read: keeps today/last_hour honest across the clock + TTL sweep
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, socket |> assign(:rows, load_rows()) |> assign(:storage, safe_storage())}
  end

  # the fast tick: CPU / rates / presence — no DB touch, so it can breathe at 2s
  def handle_info(:vitals, socket) do
    Process.send_after(self(), :vitals, @vitals_ms)
    {:noreply, assign(socket, :vitals, load_vitals())}
  end

  defp channel_names, do: Pulse.channels() |> Map.keys() |> Enum.sort()

  # Zeroed vitals for the disconnected render. The cost section is hidden while
  # loading, so these are never painted — they only keep the assign shape stable
  # so a stray template reference can't KeyError.
  defp placeholder_vitals do
    %{
      cpu_util: 0.0,
      mem_mb: 0.0,
      run_queue: 0,
      cursor_per_s: 0.0,
      strikes_per_min: 0.0,
      online: 0,
      fanout_per_s: 0.0,
      cost_so_far: 0.0
    }
  end

  defp load_vitals do
    snap = Metrics.snapshot()

    online =
      Enum.reduce(channel_names(), 0, fn name, acc ->
        acc + map_size(BarkparkWeb.Presence.list("pulse:" <> name))
      end)

    # broadcast fan-out: every relayed frame goes to (subscribers - 1) sockets
    fanout = (snap.cursor_per_s + snap.strikes_per_min / 60) * max(0, online - 1)

    Map.merge(snap, %{
      online: online,
      fanout_per_s: fanout,
      cost_so_far: Map.get(snap, :cost_eur_total, 0.0)
    })
  end

  defp safe_storage do
    Pulse.storage()
  rescue
    _ -> %{events_bytes: 0, counters_bytes: 0, event_rows: 0}
  end

  # the tangible number: this node's CPU share × the box's monthly price.
  # Honest framing — an ESTIMATE of the storm's share of a fixed-price server.
  defp host_eur_month do
    case Application.get_env(:barkpark, :pulse_host_eur_month, 4.51) do
      n when is_number(n) ->
        n * 1.0

      s when is_binary(s) ->
        with {f, _} <- Float.parse(s) do
          f
        else
          _ -> 4.51
        end
    end
  end

  defp eur(cpu_util), do: :erlang.float_to_binary(cpu_util * host_eur_month(), decimals: 4)
  defp pct(u), do: :erlang.float_to_binary(u * 100, decimals: 1)
  defp f1(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)
  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 2)
  defp f6(x), do: :erlang.float_to_binary(x * 1.0, decimals: 6)

  # thousands separators, no extra dep: 1317 -> "1,317"
  defp commas(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp commas(_), do: "0"

  defp load_rows do
    Enum.map(channel_names(), fn name ->
      s = Pulse.stats(name)
      %{name: name, total: s.total, today: s.today, last_hour: s.last_hour}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="container" style="max-width: 60rem;">
      <h1>⚡ Lightning Storm</h1>
      <p>
        <small>
          Live counters for every Pulse channel. Totals are durable (kept forever);
          the feed behind them is swept after 24&nbsp;h. Updates stream in real time.
        </small>
      </p>

      <div :if={@loading} data-role="pulse-loading" data-test-id="pulse-loading"
           style="border: 1px solid var(--border); border-radius: 8px; padding: 1.2rem 1.4rem; margin: 1rem 0; opacity: 0.6;">
        <p><em>Loading live counters…</em></p>
      </div>

      <section :if={not @loading} data-role="pulse-cost"
               style="border: 1px solid var(--border); border-radius: 8px; padding: 1.2rem 1.4rem; margin: 1rem 0;">
        <div style="display:flex; align-items:baseline; justify-content:space-between; gap:1rem; flex-wrap:wrap;">
          <strong>what the storm costs right now</strong>
          <span style="text-align:right; font-variant-numeric: tabular-nums;">
            <span data-role="cost-eur" style="font-size:1.6rem; font-weight:700;">≈ €<%= eur(@vitals.cpu_util) %>/mo</span><br/>
            <small data-role="cost-sofar" style="opacity:0.7;">€<%= f6(@vitals.cost_so_far) %> so far</small>
          </span>
        </div>
        <div style="display:flex; gap:1.6rem; margin-top:0.5rem; flex-wrap:wrap; opacity:0.8; font-variant-numeric: tabular-nums;">
          <span>cpu <strong data-role="cost-cpu"><%= pct(@vitals.cpu_util) %>%</strong></span>
          <span>mem <strong><%= f1(@vitals.mem_mb) %> MB</strong></span>
          <span>run queue <strong><%= @vitals.run_queue %></strong></span>
          <span>online <strong data-role="cost-online"><%= @vitals.online %></strong></span>
          <span>cursor msgs <strong data-role="cost-cursor"><%= f1(@vitals.cursor_per_s) %>/s</strong></span>
          <span>strikes <strong><%= f1(@vitals.strikes_per_min) %>/min</strong></span>
          <span>fan-out <strong><%= f1(@vitals.fanout_per_s) %> msg/s</strong></span>
          <span>storage <strong data-role="cost-storage"><%= mb(@storage.events_bytes + @storage.counters_bytes) %> MB</strong>
            (<%= @storage.event_rows %> rows)</span>
        </div>
        <p style="margin:0.6rem 0 0; opacity:0.55;">
          <small>
            The euro figure is this node's live BEAM CPU share of a fixed
            €<%= f1(host_eur_month()) %>/mo server — it rises when people join and
            play, and falls back to ~zero when the storm is idle. Message rates
            and presence are measured, not modelled; storage is real
            <code>pg_total_relation_size</code> (events are swept after 24 h,
            the counter rows live forever).
          </small>
        </p>
      </section>

      <div :if={not @loading and @rows == []} data-role="pulse-empty">
        <p><em>No Pulse channels configured on this instance.</em></p>
      </div>

      <div :for={row <- @rows} data-role="pulse-channel" data-channel={row.name}
           style="border: 1px solid var(--border); border-radius: 8px; padding: 1.2rem 1.4rem; margin: 1rem 0;">
        <div style="display:flex; align-items:baseline; justify-content:space-between; gap:1rem; flex-wrap:wrap;">
          <strong style="font-size:1.1rem;"><%= row.name %></strong>
          <span data-role="pulse-total" style="font-size:2.4rem; font-weight:700; font-variant-numeric: tabular-nums;">
            <%= commas(row.total) %>
          </span>
        </div>
        <div style="display:flex; gap:2rem; margin-top:0.4rem; opacity:0.75; font-variant-numeric: tabular-nums;">
          <span>strikes ever</span>
          <span>today: <strong data-role="pulse-today"><%= row.today %></strong></span>
          <span>last hour: <strong data-role="pulse-hour"><%= row.last_hour %></strong></span>
        </div>
      </div>
    </main>
    """
  end
end
