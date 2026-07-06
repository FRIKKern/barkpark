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

  Mounted at `/studio/pulse` via the plugin's `register_routes/1` (`:admin`
  bucket) and linked from the Structure desk via `desk_items/1`. Purely
  observational — no writes, no controls.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Pulse

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      for name <- channel_names(), do: BarkparkWeb.Endpoint.subscribe("pulse:" <> name)
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, :rows, load_rows())}
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
    {:noreply, assign(socket, :rows, load_rows())}
  end

  defp channel_names, do: Pulse.channels() |> Map.keys() |> Enum.sort()

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

      <div :if={@rows == []} data-role="pulse-empty">
        <p><em>No Pulse channels configured on this instance.</em></p>
      </div>

      <div :for={row <- @rows} data-role="pulse-channel" data-channel={row.name}
           style="border: 1px solid var(--muted-border-color, #ccc); border-radius: 8px; padding: 1.2rem 1.4rem; margin: 1rem 0;">
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
